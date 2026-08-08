import AppKit
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
          # Mirror the clipboard setup MyGhost applies to the local tmux server
          # (ScreenSessionManager.ensureTmuxConf): without it, drag selections
          # inside the remote tmux never reach the macOS clipboard, and TUI apps
          # with mouse reporting (e.g. Claude Code) swallow drags entirely.
          # The Ms append is guarded so reconnects do not stack duplicates.
          if "$TB" has-session 2>/dev/null; then
            "$TB" show-options -s terminal-overrides 2>/dev/null | grep -q Ms= || "$TB" set -ga terminal-overrides ",xterm-256color:Ms=\\\\E]52;%p1%s;%p2%s\\\\007"
          else
            "$TB" new-session -d -s '"$session"'
            "$TB" set -ga terminal-overrides ",xterm-256color:Ms=\\\\E]52;%p1%s;%p2%s\\\\007"
          fi
          "$TB" set -s set-clipboard on
          "$TB" set -g mouse on
          "$TB" set -g allow-passthrough on
          "$TB" bind -n MouseDrag1Pane copy-mode -M
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

    // MARK: - Clipboard image upload

    /// Copy the clipboard image to the remote host so its path can be pasted
    /// into the terminal. Terminal paste is text-only, and remote programs
    /// (e.g. Claude Code) read the *remote* clipboard on Ctrl+V, so the only
    /// way an image reaches a remote CLI is as a file on that host.
    ///
    /// The upload streams the PNG through ssh (`cat > path`) rather than scp,
    /// so it reuses the exact ssh options the tab connected with. Calls
    /// `completion` on the main queue with the remote path, or nil on failure.
    func uploadClipboardImage(
        target: String,
        options: [String],
        completion: @escaping (String?) -> Void
    ) {
        guard let png = clipboardPNGData() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let fileName = "myghost-paste-\(UUID().uuidString.prefix(8)).png"
        let remotePath = "/tmp/\(fileName)"
        let localURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try png.write(to: localURL)
        } catch {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [fileManager] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + options
                + [target, "--", "cat > \(remotePath)"]
            process.standardInput = FileHandle(forReadingAtPath: localURL.path)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var success = false
            do {
                try process.run()
                process.waitUntilExit()
                success = process.terminationStatus == 0
            } catch {
                success = false
            }
            try? fileManager.removeItem(at: localURL)
            DispatchQueue.main.async { completion(success ? remotePath : nil) }
        }
    }

    /// Directory on the remote host that dropped/pasted files are copied into.
    /// A stable location rather than /tmp, which the system prunes — an agent
    /// reading the file later shouldn't find it gone.
    static let uploadDirectory = "$HOME/myghost-uploads"

    /// Copy local files (or folders) to the remote host so remote programs can
    /// read them, calling `completion` on the main queue with the remote paths
    /// in the same order. Paths that failed to upload are omitted.
    ///
    /// Files stream through `ssh … cat`, folders through `tar`, so both reuse
    /// the exact ssh options the tab connected with. The remote side picks a
    /// non-clashing name and echoes back the path it actually wrote.
    func uploadFiles(
        _ localURLs: [URL],
        target: String,
        options: [String],
        completion: @escaping ([String]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let paths = localURLs.compactMap {
                uploadOne($0, target: target, options: options)
            }
            DispatchQueue.main.async { completion(paths) }
        }
    }

    /// Upload one file or folder, returning the remote path it landed on.
    /// Runs synchronously — call it off the main thread.
    private func uploadOne(_ localURL: URL, target: String, options: [String]) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        let name = localURL.lastPathComponent
        guard !name.isEmpty else { return nil }

        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            + options
            + [target, "--", Self.remoteReceiveCommand(name: name, isDirectory: isDirectory.boolValue)]

        let output = Pipe()
        ssh.standardOutput = output
        ssh.standardError = FileHandle.nullDevice

        // A folder is streamed as a tar of its contents; a file is streamed raw.
        var tar: Process?
        if isDirectory.boolValue {
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = [
                "-cf", "-",
                "-C", localURL.deletingLastPathComponent().path,
                name,
            ]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            ssh.standardInput = pipe
            tar = process
        } else {
            guard let handle = FileHandle(forReadingAtPath: localURL.path) else { return nil }
            ssh.standardInput = handle
        }

        do {
            try ssh.run()
            try tar?.run()
        } catch {
            return nil
        }
        // Read before waiting so a large listing can't fill the pipe buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ssh.waitUntilExit()
        tar?.waitUntilExit()

        guard ssh.terminationStatus == 0,
              let remotePath = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !remotePath.isEmpty
        else { return nil }
        return remotePath
    }

    /// The command run on the remote host to receive one upload.
    ///
    /// The remote login shell may be fish, which can't parse POSIX syntax, so
    /// the script is base64'd and handed to `/bin/sh` — that also keeps the
    /// file name clear of any quoting. stdin stays free for the payload.
    private static func remoteReceiveCommand(name: String, isDirectory: Bool) -> String {
        let receive = isDirectory
            ? #"mkdir -p "$p"; tar -xf - -C "$p" --strip-components 1"#
            : #"cat > "$p""#
        let script = """
        set -e
        d="\(uploadDirectory)"
        mkdir -p "$d"
        n=$MG_NAME
        p="$d/$n"
        i=1
        while [ -e "$p" ]; do p="$d/$i-$n"; i=$((i+1)); done
        \(receive)
        printf '%s\\n' "$p"
        """
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let nameB64 = Data(name.utf8).base64EncodedString()
        return "/bin/sh -c 'MG_NAME=$(printf %s \(nameB64) | base64 -d); "
            + "eval \"$(printf %s \(scriptB64) | base64 -d)\"'"
    }

    /// The clipboard image as PNG data: raw PNG if present, otherwise any
    /// image representation (TIFF, copied file, …) converted via NSImage.
    private func clipboardPNGData() -> Data? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) { return data }
        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Store a tab's placement on the remote tmux session itself, as the user
    /// options `@myghost_title`, `@myghost_group`, and `@myghost_order`.
    ///
    /// Naming, grouping, and ordering all happen on this Mac, but the session
    /// lives on the other host — where MyGhost Web would otherwise have nothing
    /// to show but a session id in tmux's own alphabetical order, with no idea
    /// which tabs belong together. Keeping it on the session means it travels
    /// with it: no extra file to sync, and it survives this app quitting.
    /// Pass nil to clear the name or the group.
    func setRemoteTitle(
        target: String,
        options: [String],
        sessionName: String,
        title: String?,
        group: String? = nil,
        order: Int? = nil
    ) {
        // A remote login shell may be fish, which can't parse POSIX syntax, so
        // run through /bin/sh; text rides along base64'd to keep it clear of
        // quoting entirely.
        func setText(_ option: String, _ value: String?) -> String {
            guard let value, !value.isEmpty else {
                return "\"$T\" set-option -u -t \(sessionName) \(option)"
            }
            let encoded = Data(value.utf8).base64EncodedString()
            return "\"$T\" set-option -t \(sessionName) \(option) "
                + "\"$(printf %s \(encoded) | base64 -d)\""
        }

        var assign = setText("@myghost_title", title)
        assign += "; " + setText("@myghost_group", group)
        if let order {
            assign += "; \"$T\" set-option -t \(sessionName) @myghost_order \(order)"
        }
        // Stamp ownership at the same time: cleanup must be able to tell our
        // leftovers from another Mac's live tabs.
        let owner = Data(Self.ownerID.utf8).base64EncodedString()
        assign += "; \"$T\" set-option -t \(sessionName) @myghost_owner "
            + "\"$(printf %s \(owner) | base64 -d)\""
        let script = "T=$(command -v tmux || echo /opt/homebrew/bin/tmux); \(assign)"

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
                + options
                + [target, "--", "/bin/sh -c '\(script)'"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Identifies this Mac on the sessions it opens elsewhere.
    static let ownerID = ProcessInfo.processInfo.hostName

    /// Kill remote sessions this Mac opened but no longer has a tab for.
    ///
    /// Only sessions stamped with our owner id are considered: a session with
    /// no stamp, or another Mac's, is left alone. Detachment is not evidence of
    /// abandonment — every session detaches while its app is closed.
    func cleanupOrphanedSessions(target: String, options: [String], keeping: Set<String>) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let script = "T=$(command -v tmux || echo /opt/homebrew/bin/tmux); "
                + "\"$T\" list-sessions -F '#{session_name}|#{@myghost_owner}' 2>/dev/null"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + options
                + [target, "--", "/bin/sh -c '\(script)'"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return }

            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let owner = String(parts[1]).trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix("myghostr_"), owner == Self.ownerID,
                      !keeping.contains(name) else { continue }
                killRemoteSession(target: target, options: options, sessionName: name)
            }
        }
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
