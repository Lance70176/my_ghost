import Foundation

/// Manages GNU screen sessions for terminal session persistence across app restarts.
/// Each terminal tab runs inside a screen session so that when the app quits, the shell
/// processes survive and can be reattached on next launch.
class ScreenSessionManager {
    static let shared = ScreenSessionManager()

    /// Whether `/usr/bin/screen` exists on the system.
    let isAvailable: Bool

    private let screenPath = "/usr/bin/screen"
    private let fileManager = FileManager.default

    /// Directory for MyGhost support files.
    private var supportDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MyGhost")
    }

    /// Path to the custom screenrc file.
    private var screenrcPath: URL {
        supportDirectory.appendingPathComponent("screenrc")
    }

    /// Path to the persisted session state JSON.
    private var stateFilePath: URL {
        supportDirectory.appendingPathComponent("screen_sessions.json")
    }

    private init() {
        isAvailable = FileManager.default.fileExists(atPath: "/usr/bin/screen")
    }

    // MARK: - Screenrc

    /// Ensure the support directory and minimal screenrc exist.
    func ensureScreenrc() {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }

        // Always overwrite to keep screenrc in sync with app version
        let rc = [
            "startup_message off",
            "escape ^Zz",
            "vbell off",
            "defscrollback 10000",
            "hardstatus off",
            "caption never",
        ].joined(separator: "\n")
        try? rc.data(using: .utf8)?.write(to: screenrcPath)
    }

    // MARK: - Session Naming

    /// Generate a screen session name for a given tab UUID.
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

    /// Path to a launcher script that `cd`s then `exec`s the user shell.
    private var launcherScriptPath: URL {
        supportDirectory.appendingPathComponent("launch.sh")
    }

    /// Write a launcher script: `cd "$1" && exec <shell>`
    private func ensureLauncherScript() {
        let script = """
        #!/bin/sh
        cd "$1" 2>/dev/null
        exec \(userShell)
        """
        let path = launcherScriptPath
        try? script.data(using: .utf8)?.write(to: path)
        // Make executable
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    /// Return the shell command to create a new screen session.
    /// When `workingDirectory` is provided, uses a launcher script
    /// so the shell starts in the correct directory.
    func createCommand(sessionName: String, workingDirectory: String? = nil) -> String {
        ensureScreenrc()
        let escapedRcPath = screenrcPath.path.replacingOccurrences(of: " ", with: "\\ ")
        if let wd = workingDirectory {
            ensureLauncherScript()
            let escapedLauncher = launcherScriptPath.path.replacingOccurrences(of: " ", with: "\\ ")
            let escapedWd = wd.replacingOccurrences(of: " ", with: "\\ ")
            return "\(screenPath) -c \(escapedRcPath) -S \(sessionName) \(escapedLauncher) \(escapedWd)"
        }
        return "\(screenPath) -c \(escapedRcPath) -S \(sessionName) \(userShell)"
    }

    /// Return the shell command to reattach to an existing screen session.
    /// Uses `-d -r` to force detach then reattach.
    func reattachCommand(sessionName: String) -> String {
        ensureScreenrc()
        let escapedRcPath = screenrcPath.path.replacingOccurrences(of: " ", with: "\\ ")
        return "\(screenPath) -c \(escapedRcPath) -d -r \(sessionName)"
    }

    // MARK: - Session Lifecycle

    /// Kill a screen session by name.
    func killSession(name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: screenPath)
        process.arguments = ["-S", name, "-X", "quit"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// List all alive screen sessions that start with `myghost_`.
    func listAliveSessions() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: screenPath)
        process.arguments = ["-ls"]
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

        // Parse screen -ls output. Each line looks like:
        //   12345.myghost_uuid  (Detached)
        var sessions: [String] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Extract the session name (after the PID dot)
            guard let dotIndex = trimmed.firstIndex(of: ".") else { continue }
            let afterDot = trimmed[trimmed.index(after: dotIndex)...]
            // Take the session name up to the next whitespace or tab
            let name = String(afterDot.prefix(while: { !$0.isWhitespace }))
            if name.hasPrefix("myghost_") {
                sessions.append(name)
            }
        }
        return sessions
    }

    // MARK: - Working Directory Detection

    /// Get the current working directory of the shell running inside a screen session.
    /// Walks the process tree: screen → login → fish, then uses `lsof` to get cwd.
    func getSessionWorkingDirectory(sessionName: String) -> String? {
        // Find the screen process PID from session name
        let lsOutput = runScreenLs()
        guard let screenPid = parseScreenPid(from: lsOutput, sessionName: sessionName) else { return nil }

        // Walk down the process tree to find the innermost shell
        guard let shellPid = findInnermostChild(of: screenPid) else { return nil }

        // Get cwd via lsof
        return getCwd(of: shellPid)
    }

    private func runScreenLs() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: screenPath)
        process.arguments = ["-ls"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func parseScreenPid(from output: String, sessionName: String) -> pid_t? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(sessionName) {
                // Format: "12345.myghost_uuid  (Attached)"
                if let dotIndex = trimmed.firstIndex(of: ".") {
                    let pidStr = String(trimmed[trimmed.startIndex..<dotIndex])
                    if let pid = Int32(pidStr) { return pid }
                }
            }
        }
        return nil
    }

    private func findInnermostChild(of pid: pid_t) -> pid_t? {
        // Use pgrep to find child, then recurse
        var current = pid
        for _ in 0..<5 { // max depth to avoid infinite loop
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
