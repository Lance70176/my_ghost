import Foundation

/// A remote host that can be connected to via SSH with a persistent remote tmux session.
struct RemoteHost: Codable, Hashable, Identifiable {
    /// Stable identity for manually added hosts (persisted).
    var uuid: UUID = UUID()

    /// Display name shown in the sidebar (defaults to the host/alias).
    var name: String

    /// Hostname, IP address, or ssh config alias.
    var host: String

    /// Optional SSH user. Empty when using an ssh config alias that defines it.
    var user: String = ""

    /// Optional SSH port. nil = default (22 or ssh config value).
    var port: Int? = nil

    /// Optional path to a private key file.
    var identityFile: String = ""

    /// True when this entry was parsed from ~/.ssh/config (not persisted by us).
    var isFromSSHConfig: Bool = false

    var id: String { isFromSSHConfig ? "cfg:\(host)" : "man:\(uuid.uuidString)" }

    /// The ssh destination argument, e.g. "friday-mac-mini" or "friday@100.80.141.35".
    var target: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }

    /// Extra ssh CLI options derived from port/identity file.
    var sshOptions: [String] {
        var opts: [String] = []
        if let port, port > 0, port != 22 {
            opts += ["-p", String(port)]
        }
        if !identityFile.isEmpty {
            opts += ["-i", identityFile]
        }
        return opts
    }
}

/// Manages remote SSH hosts and the ssh+tmux bootstrap used by remote tabs.
///
/// A remote tab runs `ssh <host> tmux new-session -A -s <name>` through a small
/// bootstrap script. The tmux session lives on the remote host, so it survives
/// network drops, app restarts, and local machine sleep. The bootstrap script
/// reconnects automatically whenever ssh exits with code 255 (connection lost);
/// any other exit code means the user exited or detached, and the tab closes.
class RemoteHostManager {
    static let shared = RemoteHostManager()

    private let fileManager = FileManager.default

    private var supportDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MyGhost")
    }

    /// The bootstrap script that keeps the ssh connection alive.
    private var scriptPath: URL {
        supportDirectory.appendingPathComponent("remote_session.sh")
    }

    /// Persisted manually-added hosts.
    private var hostsFilePath: URL {
        supportDirectory.appendingPathComponent("remote_hosts.json")
    }

    private init() {}

    // MARK: - Session Naming

    /// Session names use the "myghostr_" prefix (no underscore after "myghost")
    /// so that a MyGhost instance running ON the remote host never mistakes them
    /// for its own "myghost_" sessions and garbage-collects them.
    func sessionName(for id: UUID) -> String {
        "myghostr_\(id.uuidString.lowercased())"
    }

    // MARK: - Hosts

    /// Concrete Host aliases parsed from ~/.ssh/config (wildcards skipped).
    func sshConfigHosts() -> [RemoteHost] {
        let path = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config").path
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var hosts: [RemoteHost] = []
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = tokens.first, keyword.lowercased() == "host" else { continue }
            for alias in tokens.dropFirst() {
                if alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") { continue }
                hosts.append(RemoteHost(name: alias, host: alias, isFromSSHConfig: true))
            }
        }
        return hosts
    }

    /// Manually added hosts persisted in Application Support.
    func manualHosts() -> [RemoteHost] {
        guard let data = try? Data(contentsOf: hostsFilePath) else { return [] }
        return (try? JSONDecoder().decode([RemoteHost].self, from: data)) ?? []
    }

    func addManualHost(_ host: RemoteHost) {
        var hosts = manualHosts()
        hosts.removeAll { $0.uuid == host.uuid }
        hosts.append(host)
        saveManualHosts(hosts)
    }

    func removeManualHost(_ host: RemoteHost) {
        var hosts = manualHosts()
        hosts.removeAll { $0.uuid == host.uuid }
        saveManualHosts(hosts)
    }

    private func saveManualHosts(_ hosts: [RemoteHost]) {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(hosts)
            try data.write(to: hostsFilePath)
        } catch {
            // Best-effort persistence
        }
    }

    /// All connectable hosts: ssh config aliases first, then manual entries.
    func allHosts() -> [RemoteHost] {
        sshConfigHosts() + manualHosts()
    }

    // MARK: - Bootstrap Script

    /// Ensure the support directory and the ssh bootstrap script exist.
    /// Always overwritten to keep the script in sync with the app version.
    private func ensureBootstrapScript() {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }

        let script = """
        #!/bin/sh
        # MyGhost remote session bootstrap.
        # Usage: remote_session.sh <ssh-target> <tmux-session-name> [extra ssh options...]
        #
        # Runs a persistent tmux session on the remote host and reconnects
        # automatically when the connection drops. ssh exits with 255 only on
        # connection/authentication failure; any other code is the remote
        # command's exit status (user exited the shell or detached tmux).
        target="$1"
        session="$2"
        shift 2
        # Ghostty sets TERM=xterm-ghostty, which most remote hosts don't have in
        # their terminfo database — tmux then fails with "missing or unsuitable
        # terminal". Send the universally available xterm-256color instead.
        TERM=xterm-256color
        export TERM
        # Remote payload, run via `sh -c` so it behaves the same regardless of
        # the remote user's login shell (bash/zsh/fish/...). Looks for tmux in
        # PATH and in common install locations — non-interactive ssh commands
        # often miss Homebrew paths — and falls back to a plain login shell
        # when tmux is unavailable.
        payload='TB=
        for c in tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
          if command -v "$c" >/dev/null 2>&1; then TB=$c; break; fi
        done
        if [ -n "$TB" ]; then
          exec "$TB" new-session -A -s '"$session"'
        else
          echo ""
          echo "[MyGhost] tmux not found on remote host - using a plain shell instead."
          echo "[MyGhost] Auto-reconnect still works, but running programs will not survive a disconnect."
          echo ""
          exec "${SHELL:-/bin/sh}" -l
        fi'
        attempt=0
        while :; do
          if [ "$attempt" -gt 0 ]; then
            printf '\\n\\033[33m[MyGhost] Connection lost. Reconnecting (attempt %s)... Press Ctrl+C to stop.\\033[0m\\n' "$attempt"
            sleep 3 || exit 130
          fi
          attempt=$((attempt + 1))
          /usr/bin/ssh -t \\
            -o ServerAliveInterval=15 \\
            -o ServerAliveCountMax=4 \\
            -o ConnectTimeout=10 \\
            "$@" "$target" -- "sh -c '$payload'"
          status=$?
          [ "$status" -ne 255 ] && exit "$status"
        done
        """
        try? script.data(using: .utf8)?.write(to: scriptPath)
    }

    /// Escape spaces with backslashes for shell commands (same convention as
    /// ScreenSessionManager — Ghostty parses the command string shell-style).
    private func escapeForShell(_ path: String) -> String {
        path.replacingOccurrences(of: " ", with: "\\ ")
    }

    // MARK: - Commands

    /// The surface command that connects to a remote host and attaches the
    /// persistent tmux session. Idempotent: `tmux new-session -A` attaches when
    /// the session exists and creates it otherwise, so the same command serves
    /// both first connect and reattach-after-restart.
    func connectCommand(target: String, options: [String], sessionName: String) -> String {
        ensureBootstrapScript()
        var parts = ["/bin/sh", escapeForShell(scriptPath.path), escapeForShell(target), sessionName]
        parts += options.map { escapeForShell($0) }
        return parts.joined(separator: " ")
    }

    /// Kill a remote tmux session (best-effort, in the background). Used when
    /// the user explicitly closes a remote tab so sessions don't pile up.
    func killRemoteSession(target: String, options: [String], sessionName: String) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
                + options
                + [target, "tmux", "kill-session", "-t", sessionName]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
