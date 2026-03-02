import Foundation

/// Manages tmux sessions for terminal session persistence across app restarts.
/// Each terminal tab runs inside a tmux session so that when the app quits, the shell
/// processes survive and can be reattached on next launch.
class ScreenSessionManager {
    static let shared = ScreenSessionManager()

    /// Whether tmux exists on the system.
    let isAvailable: Bool

    private let tmuxPath: String
    private let fileManager = FileManager.default

    /// Directory for MyGhost support files.
    private var supportDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MyGhost")
    }

    /// Path to the custom tmux config file.
    private var tmuxConfPath: URL {
        supportDirectory.appendingPathComponent("tmux.conf")
    }

    /// Path to the persisted session state JSON.
    private var stateFilePath: URL {
        supportDirectory.appendingPathComponent("screen_sessions.json")
    }

    private init() {
        // Prefer Homebrew tmux, fall back to system
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            tmuxPath = found
            isAvailable = true
        } else {
            tmuxPath = "/opt/homebrew/bin/tmux"
            isAvailable = false
        }
    }

    // MARK: - Tmux Config

    /// Ensure the support directory and minimal tmux.conf exist.
    func ensureTmuxConf() {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }

        // Always overwrite to keep config in sync with app version
        let conf = [
            // No status bar — Ghostty handles tab UI
            "set -g status off",
            // True color support
            "set -g default-terminal 'xterm-256color'",
            "set -sa terminal-features ',xterm-256color:RGB'",
            // Don't intercept any key sequences — let Ghostty handle them
            "set -g prefix None",
            "unbind-key -a",
            // Large scrollback
            "set -g history-limit 10000",
            // No visual bell
            "set -g visual-bell off",
            // Allow passthrough of escape sequences (OSC, etc.)
            "set -g allow-passthrough on",
            // Forward terminal title from shell to Ghostty
            "set -g set-titles on",
            "set -g set-titles-string '#T'",
            // Allow shell/programs to set window/pane title
            "set -g allow-rename on",
            "set -g automatic-rename on",
            // Ensure OSC title sequences are forwarded to the outer terminal
            "set -ga terminal-overrides ',xterm-256color:title'",
            // Disable escape delay for responsive input
            "set -sg escape-time 0",
            // Destroy session when shell exits
            "set -g remain-on-exit off",
        ].joined(separator: "\n")
        try? conf.data(using: .utf8)?.write(to: tmuxConfPath)
    }

    // MARK: - Session Naming

    /// Generate a tmux session name for a given tab UUID.
    func sessionName(for id: UUID) -> String {
        "myghost_\(id.uuidString.lowercased())"
    }

    // MARK: - Commands

    /// Detect the user's configured shell from Ghostty config or system default.
    private var userShell: String {
        // Check Ghostty config file for `command = ...`
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configPaths = [
            appSupport.appendingPathComponent("MyGhost/config").path,
            appSupport.appendingPathComponent("com.mitchellh.ghostty/config").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/ghostty/config").path,
        ]
        for path in configPaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in contents.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("command") && trimmed.contains("=") {
                        let parts = trimmed.split(separator: "=", maxSplits: 1)
                        if parts.count == 2 {
                            let cmd = parts[1].trimmingCharacters(in: .whitespaces)
                            if !cmd.isEmpty && !cmd.hasPrefix("#") {
                                return cmd
                            }
                        }
                    }
                }
            }
        }
        // Fall back to SHELL env var or /bin/zsh
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Escape spaces with backslashes for shell commands.
    private func escapeForShell(_ path: String) -> String {
        path.replacingOccurrences(of: " ", with: "\\ ")
    }

    /// Return the shell command to create a new tmux session.
    /// When `workingDirectory` is provided, tmux starts in that directory via `-c`.
    func createCommand(sessionName: String, workingDirectory: String? = nil) -> String {
        ensureTmuxConf()
        let escapedConf = escapeForShell(tmuxConfPath.path)
        let shell = userShell
        var cmd = "\(tmuxPath) -f \(escapedConf) new-session -s \(sessionName)"
        if let wd = workingDirectory {
            cmd += " -c \(escapeForShell(wd))"
        }
        cmd += " \(escapeForShell(shell))"
        return cmd
    }

    /// Return the shell command to reattach to an existing tmux session.
    func reattachCommand(sessionName: String) -> String {
        ensureTmuxConf()
        let escapedConf = escapeForShell(tmuxConfPath.path)
        return "\(tmuxPath) -f \(escapedConf) attach-session -t \(sessionName)"
    }

    // MARK: - Session Lifecycle

    /// Kill a tmux session by name.
    func killSession(name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["kill-session", "-t", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// List all alive tmux sessions that start with `myghost_`.
    func listAliveSessions() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("myghost_") }
    }

    // MARK: - Working Directory Detection

    /// Get the current working directory of the shell running inside a tmux session.
    /// Uses `tmux display-message` to get the pane PID, then walks the process tree.
    func getSessionWorkingDirectory(sessionName: String) -> String? {
        // Try tmux's built-in pane_current_path first
        let tmuxCwd = getTmuxPaneCwd(sessionName: sessionName)
        if let cwd = tmuxCwd, !cwd.isEmpty {
            return cwd
        }

        // Fallback: get the pane PID and walk the process tree
        guard let panePid = getTmuxPanePid(sessionName: sessionName) else { return nil }
        guard let shellPid = findInnermostChild(of: panePid) else { return nil }
        return getCwd(of: shellPid)
    }

    private func getTmuxPaneCwd(sessionName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["display-message", "-t", sessionName, "-p", "#{pane_current_path}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func getTmuxPanePid(sessionName: String) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["display-message", "-t", sessionName, "-p", "#{pane_pid}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func findInnermostChild(of pid: pid_t) -> pid_t? {
        var current = pid
        for _ in 0..<5 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", "\(current)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return current }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let children = output.components(separatedBy: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            guard let child = children.first else { return current }
            current = child
        }
        return current
    }

    private func getCwd(of pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-d", "cwd", "-p", "\(pid)", "-F", "n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n") && line.count > 1 {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    // MARK: - State Persistence

    struct SessionState: Codable {
        let screenSessionName: String
        let title: String
        let workingDirectory: String?
        let isGroup: Bool
        let groupName: String?
        let children: [SessionState]?
    }

    struct SavedState: Codable {
        let sessions: [SessionState]
        let selectedScreenName: String?
    }

    /// Save the current tab state to disk.
    func saveState(_ state: SavedState) {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateFilePath)
        } catch {
            // Silently fail — state persistence is best-effort
        }
    }

    /// Load saved tab state from disk, or nil if none exists.
    func loadState() -> SavedState? {
        guard fileManager.fileExists(atPath: stateFilePath.path) else { return nil }
        do {
            let data = try Data(contentsOf: stateFilePath)
            return try JSONDecoder().decode(SavedState.self, from: data)
        } catch {
            return nil
        }
    }

    /// Remove the saved state file.
    func clearState() {
        try? fileManager.removeItem(at: stateFilePath)
    }
}
