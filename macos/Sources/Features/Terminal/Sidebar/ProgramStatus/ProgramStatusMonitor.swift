import AppKit
import Foundation
import SwiftUI

/// What a program in a tab says it is doing, through the Program Status
/// Protocol (OSC 7501): the most urgent of the pane's records, as the relay
/// script (ProgramStatusRelay) summarises it into the pane option
/// `@myghost_psp`.
struct ProgramStatus: Equatable {
    enum State: String {
        case idle, working, done, blocked, error

        /// Higher wins when a tab has several panes reporting.
        var rank: Int {
            switch self {
            case .blocked: 5
            case .error: 4
            case .working: 3
            case .done: 2
            case .idle: 1
            }
        }
    }

    /// Identifies one report: the pane plus the relay's running number, so a
    /// "done" the user has seen stays hidden until a newer report arrives.
    let token: String
    let state: State
    /// permission / question / auth, only for `blocked`.
    let kind: String?
    let progress: Int?
    let app: String?
    let title: String?
    let message: String?
    let recordCount: Int

    init?(summary: String, pane: String) {
        var kv: [String: String] = [:]
        for pair in summary.split(separator: ":") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            kv[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        guard let raw = kv["state"], let state = State(rawValue: raw) else { return nil }
        self.token = "\(pane):\(kv["seq"] ?? "")"
        self.state = state
        self.kind = kv["kind"]
        self.progress = kv["progress"].flatMap(Int.init)
        self.app = kv["app"]
        self.title = kv["title"].flatMap(Self.decode)
        self.message = kv["msg"].flatMap(Self.decode)
        self.recordCount = kv["n"].flatMap(Int.init) ?? 1
    }

    /// Base64 (padding optional) to display text, with the invisible
    /// formatting and direction overrides the spec asks us to neutralise.
    private static func decode(_ value: String) -> String? {
        var b64 = value
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var color: Color {
        switch state {
        case .blocked: .orange
        case .working: .blue
        case .error: .red
        case .done: .green
        case .idle: .secondary
        }
    }

    /// Short label for the sidebar capsule and the pane title bar.
    var label: String {
        switch state {
        case .blocked:
            switch kind {
            case "permission": L("Needs permission")
            case "question": L("Has a question")
            case "auth": L("Needs sign-in")
            default: L("Needs you")
            }
        case .working:
            if let progress { "\(L("Running")) \(progress)%" } else { L("Running") }
        case .error: L("Failed")
        case .done: L("Done")
        case .idle: L("Idle")
        }
    }

    /// The program's own words: "cargo · Building · 3 of 9 crates".
    var detail: String {
        [app, title, message].compactMap { $0 }.joined(separator: " · ")
    }

    var tooltip: String {
        let base = detail.isEmpty ? label : "\(label) — \(detail)"
        return recordCount > 1 ? "\(base) (\(L("%d reports", recordCount)))" : base
    }
}

/// Keeps the Program Status Protocol relay attached to every MyGhost tmux
/// pane and publishes each tab's current status.
///
/// tmux discards OSC sequences it doesn't know, so a program's OSC 7501 never
/// reaches the terminal. Instead every `myghost_*` pane gets
/// `pipe-pane -O -o` to a small Perl relay (ProgramStatusRelay.script) that
/// reads the pane's raw output, keeps its records per the spec and writes a
/// summary into the pane option `@myghost_psp`. One `list-panes -a` per poll
/// both reads those summaries and finds panes still missing the relay —
/// new tabs, tabs restored after a relaunch, a restarted tmux server.
///
/// Remote tabs' tmux runs on the other host, so each host with an open tab
/// gets one long-lived ssh (RemoteStatusWatcher) running the same script in
/// `--watch` mode there: it attaches the relay to the `myghostr_*` panes and
/// streams their summaries back.
final class ProgramStatusMonitor: ObservableObject {
    static let shared = ProgramStatusMonitor()

    /// Set to true (`defaults write <bundle id> ProgramStatusRelayDisabled
    /// -bool YES`) to stop attaching the relay.
    static let disabledKey = "ProgramStatusRelayDisabled"

    /// tmux session name → what its program reports, minus finished
    /// reports the user has already looked at. Local and remote sessions
    /// share it: their names never collide (myghost_ vs myghostr_<uuid>).
    @Published private(set) var statuses: [String: ProgramStatus] = [:]

    let queue = DispatchQueue(label: "com.myghost.program-status", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    // Confined to `queue`.
    private var attachAttempts: [String: Int] = [:]
    /// The pane's command when a working/blocked report first showed up:
    /// once the pane is back at a shell that isn't that command, the
    /// program has exited and the report is over (the spec's process-exit
    /// rule, which the relay can't see from the output stream). Keyed by
    /// "<scope>|<pane id>": pane ids repeat across hosts.
    private var commandAtReport: [String: (token: String, command: String)] = [:]
    private var localFound: [String: ProgramStatus] = [:]
    private var remoteFound: [String: [String: ProgramStatus]] = [:]
    private var watchers: [String: RemoteStatusWatcher] = [:]

    // Confined to the main thread.
    private var latest: [String: ProgramStatus] = [:]
    private var seenTokens: [String: String] = [:]

    private static let shells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh",
    ]

    private static let localScope = "local"

    private init() {}

    /// Start polling. Safe to call more than once.
    func start() {
        DispatchQueue.main.async { [self] in
            guard timer == nil,
                  ScreenSessionManager.shared.isAvailable,
                  !UserDefaults.standard.bool(forKey: Self.disabledKey) else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1.5, leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            queue.async { ProgramStatusRelay.install() }
            timer.resume()
        }
    }

    /// The user is looking at this tab's pane: a done/error report has now
    /// been seen and stops showing.
    func markSeen(session: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let status = latest[session], status.state == .done || status.state == .error else { return }
        seenTokens[session] = status.token
        statuses[session] = nil
    }

    // MARK: - Polling

    private func tick() {
        pollLocal()
        ticks += 1
        // Every ~6 s: open a watcher for each remote host with a tab, close
        // the ones whose host tab is gone.
        if ticks % 4 == 1 {
            DispatchQueue.main.async { [self] in
                let hosts = Self.openRemoteHosts()
                queue.async { self.syncWatchers(hosts) }
            }
        }
    }

    private func pollLocal() {
        let tmux = ScreenSessionManager.shared.tmuxExecutable
        let format = ["#{pane_id}", "#{session_name}", "#{pane_pipe}",
                      "#{pane_current_command}", "#{socket_path}", "#{@myghost_psp}"]
            .joined(separator: "\t")
        let lines = (Self.run(tmux, ["list-panes", "-a", "-F", format]) ?? "")
            .split(separator: "\n").map(String.init)

        var live = Set<String>()
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, f[1].hasPrefix("myghost_") else { continue }
            live.insert(f[0])
            if f[2] == "0" { attach(pane: f[0], tmux: tmux, socket: f[4]) }
        }
        attachAttempts = attachAttempts.filter { live.contains($0.key) }
        localFound = ingest(lines, scope: Self.localScope, prefix: "myghost_")
        publish()
    }

    /// Statuses from list-panes style lines ("pane session pipe command
    /// socket summary"), most urgent pane per session.
    private func ingest(_ lines: [String], scope: String, prefix: String) -> [String: ProgramStatus] {
        var found: [String: ProgramStatus] = [:]
        var live = Set<String>()
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { continue }
            let (session, command, summary) = (f[1], f[3], f[5])
            guard session.hasPrefix(prefix) else { continue }
            let pane = "\(scope)|\(f[0])"
            live.insert(pane)
            guard !summary.isEmpty, let status = ProgramStatus(summary: summary, pane: pane) else {
                commandAtReport[pane] = nil
                continue
            }
            if isOver(status, pane: pane, command: command) { continue }
            if let other = found[session], other.state.rank >= status.state.rank { continue }
            found[session] = status
        }
        commandAtReport = commandAtReport.filter { !$0.key.hasPrefix("\(scope)|") || live.contains($0.key) }
        return found
    }

    private func isOver(_ status: ProgramStatus, pane: String, command: String) -> Bool {
        guard status.state == .working || status.state == .blocked else {
            commandAtReport[pane] = nil
            return false
        }
        if commandAtReport[pane]?.token != status.token {
            commandAtReport[pane] = (status.token, command)
        }
        let started = commandAtReport[pane]?.command ?? command
        return Self.shells.contains(command) && command != started
    }

    private func attach(pane: String, tmux: String, socket: String) {
        // A relay that keeps dying (no perl?) is left alone after a few tries.
        let tries = attachAttempts[pane, default: 0]
        guard tries < 3, !socket.isEmpty else { return }
        attachAttempts[pane] = tries + 1
        let q = Self.shellQuote
        let cmd = "exec /usr/bin/perl \(q(ProgramStatusRelay.path)) \(q(tmux)) \(q(socket)) \(q(pane))"
        // tmux runs the command through format and strftime expansion
        // first: unescaped, the pane id "%51" reaches the relay as "51".
        let escaped = cmd
            .replacingOccurrences(of: "#", with: "##")
            .replacingOccurrences(of: "%", with: "%%")
        Self.run(tmux, ["pipe-pane", "-O", "-o", "-t", pane, escaped])
    }

    // MARK: - Remote hosts

    struct RemoteHost: Equatable {
        let target: String
        let options: [String]
    }

    /// Remote hosts with a host tab in any sidebar window, by host key.
    private static func openRemoteHosts() -> [String: RemoteHost] {
        dispatchPrecondition(condition: .onQueue(.main))
        var hosts: [String: RemoteHost] = [:]
        for window in NSApp.windows {
            guard let controller = window.windowController as? SidebarTerminalController else { continue }
            for host in controller.hostTabs {
                guard let target = host.target else { continue }
                hosts[host.key] = RemoteHost(target: target, options: host.sshOptions)
            }
        }
        return hosts
    }

    private func syncWatchers(_ hosts: [String: RemoteHost]) {
        for (key, watcher) in watchers where hosts[key] != watcher.host {
            watcher.stop()
            watchers[key] = nil
            remoteFound[key] = nil
        }
        for (key, host) in hosts where watchers[key] == nil {
            let watcher = RemoteStatusWatcher(key: key, host: host, queue: queue) { [weak self] lines in
                guard let self else { return }
                if let lines {
                    remoteFound[key] = ingest(lines, scope: key, prefix: "myghostr_")
                } else {
                    remoteFound[key] = nil
                }
                publish()
            }
            watchers[key] = watcher
            watcher.start()
        }
        publish()
    }

    private func publish() {
        var found = localFound
        for statuses in remoteFound.values {
            for (session, status) in statuses {
                if let other = found[session], other.state.rank >= status.state.rank { continue }
                found[session] = status
            }
        }
        DispatchQueue.main.async { [self] in
            latest = found
            seenTokens = seenTokens.filter { found[$0.key]?.token == $0.value }
            let visible = found.filter { seenTokens[$0.key] != $0.value.token }
            if visible != statuses { statuses = visible }
        }
    }

    // MARK: - Helpers

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ executable: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Views

/// The sidebar row's capsule for a program status. Stays out of the way of
/// the AI assistant's own Claude badge for the same tab.
struct ProgramStatusBadge: View {
    @ObservedObject private var monitor = ProgramStatusMonitor.shared
    @ObservedObject private var feature = AgentFeature.shared
    let tab: SidebarTabEntry

    var body: some View {
        if let name = tab.screenSessionName,
           let status = monitor.statuses[name], status.state != .idle,
           !agentBadgeShowing(name) {
            Group {
                if status.state == .done {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.green)
                } else {
                    Text(status.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(status.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(status.color.opacity(0.16)))
                        .fixedSize()
                }
            }
            .help(status.tooltip)
        }
    }

    private func agentBadgeShowing(_ name: String) -> Bool {
        guard feature.isEnabled else { return false }
        return AgentHub.shared.client(for: tab).statusByTmux[name] != nil
    }
}

/// The pane title bar's status: a dot, the label and the program's words.
struct ProgramStatusInline: View {
    @ObservedObject private var monitor = ProgramStatusMonitor.shared
    let session: String?

    var body: some View {
        if let session, let status = monitor.statuses[session] {
            HStack(spacing: 4) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text(status.detail.isEmpty ? status.label : "\(status.label) · \(status.detail)")
                    .font(.caption)
                    .foregroundColor(status.state == .idle ? .secondary : status.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(status.tooltip)
        }
    }
}
