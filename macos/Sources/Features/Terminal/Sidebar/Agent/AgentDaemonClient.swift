import Foundation
import Darwin
import SwiftUI

/// One permission request held by ghost-agentd (`agentd/` in this repo),
/// waiting for someone to answer it here, on Telegram or on the phone page.
struct AgentPending: Decodable, Identifiable, Equatable {
    let id: String
    let project: String
    let sessionId: String
    let tmuxSession: String
    let tabTitle: String
    let toolName: String
    let summary: String
    let reason: String
    let level: Int
    let levelName: String
    let state: String
    let alwaysPattern: String?
    let canAlways: Bool
    let remaining: Int
    /// Taken into a discussion: never times out until someone decides.
    let discussing: Bool?
    /// "permission" (a conversation waits on it) or "choice" (an assistant's
    /// question with options).
    let kind: String?
    let options: [AgentChoiceOption]?
    let cardId: String?

    var isChoice: Bool { kind == "choice" }

    var isConfirming: Bool { state == "confirming" }
    var isDiscussing: Bool { discussing ?? false }

    /// `remaining` ticks down on every poll; it alone isn't a change worth
    /// re-rendering the cards for.
    static func == (a: AgentPending, b: AgentPending) -> Bool {
        a.id == b.id && a.state == b.state && a.discussing == b.discussing
    }
    var isHighRisk: Bool { level >= 3 }
}

struct AgentChoiceOption: Decodable, Equatable, Hashable {
    let label: String
    /// "allow" / "deny" when picking it decides the card under discussion.
    let action: String?
}

/// One line of an assistant conversation (chat.jsonl).
struct AgentChatItem: Decodable, Identifiable, Equatable {
    let seq: Int
    let ts: Double
    /// user | assistant | tool | notice | choice | discuss
    let role: String
    let text: String
    let source: String
    let tool: String
    let choiceId: String
    let options: [AgentChoiceOption]
    let cardId: String
    let chosen: String

    var id: Int { seq }
}

struct AgentAssistantStatus: Decodable, Equatable {
    let project: String
    let resident: Bool
    let running: Bool
    let busy: Bool
    let contextPct: Int?
    let wakesToday: Int
    let compacting: Bool
    let model: String
}

struct AgentChatChunk: Decodable {
    let items: [AgentChatItem]
    let partial: String
    let status: AgentAssistantStatus
}

/// A Claude Code conversation the daemon has heard from through its hooks.
struct AgentSession: Decodable, Equatable {
    let sessionId: String
    let project: String
    let tmuxSession: String
    let tabTitle: String
    /// running | waiting | done | ended
    let status: String
}

/// One project registered with ghost-agentd, as the assistant list shows it.
struct AgentProject: Decodable, Identifiable, Equatable {
    let name: String
    let resident: Bool
    let tgReady: Bool
    let pending: Int
    let sessions: Int
    let waiting: Int
    let running: Int
    let lastActivity: Double
    /// Claude Code conversations (its agent list) under the project.
    let jobs: Int?
    let jobsWorking: Int?
    let jobsWaiting: Int?

    var id: String { name }
    /// Requests outside every project.
    var isDefault: Bool { name == "_default" }
    var displayName: String { isDefault ? L("Other conversations") : name }
}

/// One of a project's Claude Code conversations, as Claude Code's own agent
/// list has it (~/.claude/jobs/<id>/state.json).
struct AgentWorker: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let state: String
    let stateLabel: String
    let detail: String
    let intent: String
    let sessionId: String
    let cwd: String
    let branch: String
    let updatedAt: String

    var isWorking: Bool { state == "working" }
    var needsYou: Bool { ["blocked", "awaiting_input", "needs_input", "waiting"].contains(state) }
    var failed: Bool { ["failed", "error"].contains(state) }
    var isDone: Bool { ["done", "idle"].contains(state) }

    var localizedState: String {
        if isWorking { return L("Working") }
        if needsYou { return L("Needs you") }
        if failed { return L("Failed") }
        if isDone { return L("Done") }
        if state == "stopped" { return L("Stopped") }
        return state
    }

    var dotColor: Color {
        isWorking ? .blue : (needsYou ? .orange : (failed ? .red : (isDone ? .green : .secondary)))
    }
}

private struct AgentWorkers: Decodable { let workers: [AgentWorker] }

/// A line of a Claude Code conversation: user / assistant / tool.
struct AgentWorkerMessage: Decodable, Identifiable, Equatable {
    let i: Int
    let role: String
    let text: String
    var id: Int { i }
}

struct AgentWorkerLog: Decodable {
    let worker: AgentWorker
    let messages: [AgentWorkerMessage]
}

/// One line of a project's decisions.jsonl.
struct AgentDecisionRecord: Decodable, Identifiable, Equatable {
    let ts: Double
    let id: String
    let project: String
    let sessionId: String?
    let tmuxSession: String?
    let tab: String?
    let tool: String?
    let summary: String
    let level: String
    let reason: String?
    let state: String
    let by: String
    let alwaysAdded: String?
    let discussed: Bool?
    let denyMessage: String?

    var date: Date { Date(timeIntervalSince1970: ts) }
    var allowed: Bool { state == "allowed" }
    /// L0/L1 decisions made by the rules rather than a person.
    var byRule: Bool { by.hasPrefix("rule:") }
}

private struct AgentProjects: Decodable { let projects: [AgentProject] }
private struct AgentAssistantList: Decodable { let assistants: [AgentAssistantStatus] }
private struct AgentDecisions: Decodable { let decisions: [AgentDecisionRecord] }

private struct AgentState: Decodable {
    let version: Int
    let pending: [AgentPending]
    let sessions: [AgentSession]
}

/// Long-polls one host's ghost-agentd for pending decisions, conversation
/// status and its assistants.
///
/// There is one client per host tab: the local Mac's daemon is reached at
/// 127.0.0.1:7788, a remote host's through an SSH port forward to that
/// host's own 127.0.0.1:7788 — so every daemon stays loopback-only, and the
/// assistant follows whichever host is selected in the window.
///
/// While a client keeps polling, its daemon counts MyGhost as a place a
/// decision card can be shown; when the app quits it stops counting it after
/// 90s, and with no Telegram configured either, sessions fall back to asking
/// in the terminal instead of waiting on a card nobody can see.
@MainActor
final class AgentDaemonClient: ObservableObject {
    /// "local", or the ssh target of a remote host (SidebarHostEntry.key).
    let hostKey: String
    let hostName: String
    let target: String?
    let sshOptions: [String]
    var isLocal: Bool { target == nil }

    @Published private(set) var pending: [AgentPending] = []
    /// Status per tmux session name (`myghost_…` / `myghostr_…`).
    @Published private(set) var statusByTmux: [String: String] = [:]
    @Published private(set) var online = false
    @Published private(set) var projects: [AgentProject] = []
    /// Assistant status per project name.
    @Published private(set) var assistants: [String: AgentAssistantStatus] = [:]
    /// Bumped whenever the daemon's state changes, so open history lists know
    /// to reload.
    @Published private(set) var changeCount = 0

    var totalPending: Int { pending.count }

    /// When each pending request times out (absent: never, e.g. discussing).
    private(set) var deadlines: [String: Date] = [:]

    private var base: URL?
    private var tunnel: Process?
    /// Kept open for the tunnel's lifetime; see openTunnel.
    private var tunnelLifeline: Pipe?
    private var version = -1
    private var task: Task<Void, Never>?
    private var lastSuccess = Date()
    private var stopped = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 70
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(hostKey: String, hostName: String, target: String?, sshOptions: [String]) {
        self.hostKey = hostKey
        self.hostName = hostName
        self.target = target
        self.sshOptions = sshOptions
        if target == nil {
            base = URL(string: ProcessInfo.processInfo.environment["GHOST_AGENTD_URL"] ?? "http://127.0.0.1:7788")
        }
    }

    // MARK: Endpoint

    /// The daemon's URL, opening the SSH forward first for a remote host.
    private func endpoint() async -> URL? {
        if stopped { return nil }
        if isLocal { return base }
        if let base, let tunnel, tunnel.isRunning { return base }
        // Several requests can need the forward at once: share one start.
        if let opening { return await opening.value }
        let t = Task { await self.openTunnel() }
        opening = t
        let url = await t.value
        opening = nil
        return url
    }

    private var opening: Task<URL?, Never>?

    private func openTunnel() async -> URL? {
        guard let target, !stopped else { return nil }
        tunnel?.terminate()
        base = nil
        guard let port = Self.freePort() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // The remote side runs `cat` reading our pipe instead of `-N`: when
        // MyGhost exits — even killed — the pipe closes, cat ends and ssh
        // with it. With -N the forward outlived the app as an orphan.
        p.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                       "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
                       "-o", "ServerAliveCountMax=3",
                       "-L", "127.0.0.1:\(port):127.0.0.1:7788"] + sshOptions + [target, "cat"]
        let lifeline = Pipe()
        p.standardInput = lifeline
        tunnelLifeline = lifeline
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        tunnel = p
        let url = URL(string: "http://127.0.0.1:\(port)")!
        // Wait for the forward to come up (the daemon answers /api/health).
        for _ in 0..<40 {
            if !p.isRunning || stopped { return nil }
            if let (_, resp) = try? await session.data(from: url.appendingPathComponent("api/health")),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                base = url
                return url
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        p.terminate()
        return nil
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    private func fetch(_ path: String, _ query: [URLQueryItem] = []) async throws -> (Data, URLResponse) {
        guard let base = await endpoint() else { throw URLError(.cannotConnectToHost) }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return try await session.data(from: comps.url!)
    }

    /// POST with the headers the daemon wants; returns (ok, message).
    func post(_ path: String, _ body: [String: Any]) async -> (Bool, String?) {
        guard let base = await endpoint() else { return (false, L("ghost-agentd is not reachable")) }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Ghost")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session.data(for: req)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            return (ok, obj?["message"] as? String)
        } catch {
            return (false, L("ghost-agentd is not reachable"))
        }
    }

    // MARK: Polling

    func start() {
        guard task == nil, !stopped else { return }
        startLoop()
    }

    /// The host tab was closed: stop polling and drop the forward.
    func shutdown() {
        stopped = true
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        tunnel?.terminate()
        tunnel = nil
    }

    private var refreshTask: Task<Void, Never>?

    /// Restart a loop that hasn't succeeded for a minute (called by the hub).
    func checkHealth() {
        guard !stopped, Date().timeIntervalSince(lastSuccess) > 60 else { return }
        task?.cancel()
        if !isLocal { tunnel?.terminate() }
        startLoop()
    }

    private func startLoop() {
        lastSuccess = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.pollOnce()
                // A host without a daemon is retried slowly.
                if !ok { try? await Task.sleep(nanoseconds: (self.isLocal ? 5 : 15) * 1_000_000_000) }
            }
        }
    }

    private func pollOnce() async -> Bool {
        do {
            let (data, resp) = try await fetch("api/state", [
                URLQueryItem(name: "client", value: "myghost"),
                URLQueryItem(name: "since", value: String(version)),
                URLQueryItem(name: "wait", value: "25"),
            ])
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let state = try Self.decoder.decode(AgentState.self, from: data)
            apply(state)
            lastSuccess = Date()
            return true
        } catch {
            // A poll cancelled on purpose (restart, shutdown) says nothing
            // about the connection; tearing the forward down here broke the
            // replacement that had just opened.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return false }
            if online || !pending.isEmpty || !statusByTmux.isEmpty {
                online = false
                pending = []
                statusByTmux = [:]
                AgentHub.shared.clientChanged()
            }
            version = -1
            if !isLocal { tunnel?.terminate() }
            return false
        }
    }

    private func apply(_ state: AgentState) {
        online = true
        if state.version != version { changeCount += 1 }
        version = state.version
        refreshTask?.cancel()
        refreshTask = Task { await refreshProjects() }
        // (14) Deadlines are absolute, taken when the countdown arrives, so a
        // card mounted later doesn't add an old "remaining" to now.
        let now = Date()
        for p in state.pending where p.remaining >= 0 {
            deadlines[p.id] = now.addingTimeInterval(TimeInterval(p.remaining))
        }
        deadlines = deadlines.filter { id, _ in state.pending.contains { $0.id == id } }
        if state.pending != pending {
            pending = state.pending
            AgentHub.shared.clientChanged()
        }
        var map: [String: String] = [:]
        // The daemon lists newest first; let the newest conversation in a tab win.
        for s in state.sessions.reversed() where !s.tmuxSession.isEmpty && s.status != "ended" {
            map[s.tmuxSession] = s.status
        }
        if map != statusByTmux { statusByTmux = map }
    }

    // MARK: Requests

    func refreshProjects() async {
        guard let (data, _) = try? await fetch("api/projects"),
              let list = try? Self.decoder.decode(AgentProjects.self, from: data) else { return }
        if list.projects != projects { projects = list.projects }
        if let (data, _) = try? await fetch("api/assistants"),
           let a = try? Self.decoder.decode(AgentAssistantList.self, from: data) {
            let map = Dictionary(a.assistants.map { ($0.project, $0) }, uniquingKeysWith: { x, _ in x })
            if map != assistants { assistants = map }
        }
    }

    /// The project's Claude Code conversations, newest first.
    /// nil when the request failed — not the same as "no conversations".
    func workers(project: String) async -> [AgentWorker]? {
        guard let (data, resp) = try? await fetch("api/projects/\(project)/workers"),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? Self.decoder.decode(AgentWorkers.self, from: data) else { return nil }
        return list.workers
    }

    func workerLog(project: String, id: String) async -> AgentWorkerLog? {
        guard let (data, resp) = try? await fetch("api/projects/\(project)/workers/\(id)/log"),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? Self.decoder.decode(AgentWorkerLog.self, from: data)
    }

    /// Type a message into a Claude Code conversation. nil when sent.
    func workerSend(project: String, id: String, text: String) async -> String? {
        let (ok, msg) = await post("api/projects/\(project)/workers/\(id)/send", ["text": text])
        return ok ? nil : (msg ?? L("ghost-agentd refused the request"))
    }

    /// Newest first; nil project means every project.
    /// nil when the request failed — not the same as "no decisions".
    func decisions(project: String?, limit: Int = 300) async -> [AgentDecisionRecord]? {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let project { q.append(URLQueryItem(name: "project", value: project)) }
        guard let (data, resp) = try? await fetch("api/decisions", q),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? Self.decoder.decode(AgentDecisions.self, from: data) else { return nil }
        return list.decisions
    }

    /// Chat items after `since`, long-polling up to `wait` seconds.
    func chat(project: String, since: Int, wait: Int) async -> AgentChatChunk? {
        guard let (data, resp) = try? await fetch("api/assistants/\(project)/chat", [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "wait", value: String(wait)),
        ]), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? Self.decoder.decode(AgentChatChunk.self, from: data)
    }

    @discardableResult
    func sendMessage(project: String, text: String) async -> String? {
        let (ok, msg) = await post("api/assistants/\(project)/messages", ["text": text, "source": "myghost"])
        return ok ? nil : (msg ?? L("ghost-agentd refused the request"))
    }

    func stopAssistant(project: String) async {
        _ = await post("api/assistants/\(project)/stop", [:])
    }

    /// Decide any card by id (e.g. pick a choice option: action "o2").
    @discardableResult
    func decide(id: String, action: String, message: String = "") async -> String? {
        let (ok, msg) = await post("api/decisions/\(id)", ["action": action, "by": "myghost", "message": message])
        return ok ? nil : (msg ?? L("ghost-agentd refused the request"))
    }

    /// action: allow | deny | always | confirm | cancel | discuss. Returns the daemon's
    /// explanation when it refused (already handled, needs confirmation…).
    @discardableResult
    func decide(_ p: AgentPending, action: String, message: String = "") async -> String? {
        await decide(id: p.id, action: action, message: message)
    }
}

/// A pending card together with the host it came from.
struct AgentHostPending: Identifiable, Equatable {
    let client: AgentDaemonClient
    let pending: AgentPending
    var id: String { client.hostKey + "/" + pending.id }

    static func == (a: AgentHostPending, b: AgentHostPending) -> Bool {
        a.id == b.id && a.pending == b.pending
    }
}

/// Every host's ghost-agentd client, kept in step with the host tabs open in
/// MyGhost's windows (the local Mac always has one).
@MainActor
final class AgentHub: ObservableObject {
    static let shared = AgentHub()

    /// Not @Published: clients are created while views are being built (a
    /// sidebar badge asks for its host's), and publishing then is not allowed.
    /// Changes are announced on the next main-queue turn instead.
    private(set) var clients: [String: AgentDaemonClient] = [:]
    /// Pending cards from every host, oldest first.
    @Published private(set) var allPending: [AgentHostPending] = []

    /// Keeps App Nap off while we poll. Napped, a window left hidden or a
    /// screen left locked overnight stopped polling altogether, so the daemon
    /// stopped counting MyGhost as a place to show cards.
    private var activity: NSObjectProtocol?
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Waiting for ghost-agentd permission requests")
        _ = client(key: SidebarHostEntry.localKey, name: L("This Mac"), target: nil, options: [])
        sync()
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AgentHub.shared.tick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var ticks = 0

    private func tick() {
        sync()
        ticks += 1
        if ticks % 6 == 0 {
            for c in clients.values { c.checkHealth() }
        }
    }

    /// Open a client for each host tab, close the ones whose tab is gone.
    func sync() {
        var open: [String: SidebarHostEntry] = [:]
        for window in NSApp.windows {
            guard let controller = window.windowController as? SidebarTerminalController else { continue }
            for host in controller.hostTabs { open[host.key] = host }
        }
        for (key, host) in open where clients[key] == nil {
            _ = client(key: key, name: host.name, target: host.target, options: host.sshOptions)
        }
        for (key, c) in clients where key != SidebarHostEntry.localKey && open[key] == nil {
            c.shutdown()
            clients[key] = nil
            objectWillChange.send()
            clientChanged()
        }
    }

    /// The client for a host, created (and started) on first use.
    func client(key: String, name: String, target: String?, options: [String]) -> AgentDaemonClient {
        if let c = clients[key] { return c }
        let c = AgentDaemonClient(hostKey: key, hostName: name, target: target, sshOptions: options)
        clients[key] = c
        c.start()
        DispatchQueue.main.async { self.objectWillChange.send() }
        return c
    }

    func client(for host: SidebarHostEntry?) -> AgentDaemonClient {
        guard let host else { return local }
        return client(key: host.key, name: host.name, target: host.target, options: host.sshOptions)
    }

    /// The client for the host a tab runs on.
    func client(for tab: SidebarTabEntry) -> AgentDaemonClient {
        let entry = tab.isGroup ? (tab.children.first ?? tab) : tab
        guard let target = entry.remoteTarget else { return local }
        return client(key: target, name: entry.remoteDisplayName ?? target, target: target,
                      options: entry.remoteSSHOptions)
    }

    var local: AgentDaemonClient {
        client(key: SidebarHostEntry.localKey, name: L("This Mac"), target: nil, options: [])
    }

    var totalPending: Int { allPending.count }

    func clientChanged() {
        let next = clients.values
            .flatMap { c in c.pending.map { AgentHostPending(client: c, pending: $0) } }
        if next.map(\.id) != allPending.map(\.id) || next != allPending {
            allPending = next
        }
    }
}

/// The small "waiting for you / running / done" capsule on a sidebar row.
struct AgentStatusBadge: View {
    @ObservedObject var client: AgentDaemonClient
    let sessionName: String?

    init(tab: SidebarTabEntry) {
        client = AgentHub.shared.client(for: tab)
        sessionName = tab.screenSessionName
    }

    var body: some View {
        if let name = sessionName, let status = client.statusByTmux[name] {
            switch status {
            case "waiting":
                badge(L("Needs you"), fg: .orange, bg: Color.orange.opacity(0.18))
                    .help(L("Claude is waiting for your decision or input"))
            case "running":
                badge(L("Running"), fg: .blue, bg: Color.blue.opacity(0.15))
            case "done":
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.green)
                    .help(L("Claude finished this turn"))
            default:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(bg))
            .fixedSize()
    }
}
