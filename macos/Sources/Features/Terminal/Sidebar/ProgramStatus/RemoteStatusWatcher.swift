import Foundation

/// One long-lived ssh to a remote host that reports its remote tabs'
/// program status (OSC 7501).
///
/// The same ssh first stores the relay script as ~/.myghost/myghost-psp.pl on
/// the host (from stdin), then runs it in `--watch` mode: it attaches the
/// relay to the host's `myghostr_*` panes and prints a snapshot of the panes
/// that have a status whenever that changes. Everything runs under
/// `/bin/sh -c`, so the remote login shell (fish, …) doesn't matter.
///
/// All state lives on the monitor's queue; `onSnapshot` is called there with
/// each snapshot's lines, or nil once the connection is gone.
final class RemoteStatusWatcher {
    let key: String
    let host: ProgramStatusMonitor.RemoteHost
    private let queue: DispatchQueue
    private let onSnapshot: ([String]?) -> Void

    private var process: Process?
    private var stopped = false
    private var failures = 0
    private var startedAt = Date()
    private var buffer = Data()
    private var pending: [String] = []

    private static let remoteCommand =
        "/bin/sh -c 'mkdir -p ~/.myghost && cat > ~/.myghost/myghost-psp.pl.new"
        + " && mv -f ~/.myghost/myghost-psp.pl.new ~/.myghost/myghost-psp.pl"
        + " && exec perl ~/.myghost/myghost-psp.pl --watch myghostr_'"

    init(key: String, host: ProgramStatusMonitor.RemoteHost, queue: DispatchQueue,
         onSnapshot: @escaping ([String]?) -> Void) {
        self.key = key
        self.host = host
        self.queue = queue
        self.onSnapshot = onSnapshot
    }

    /// Call on the queue.
    func start() {
        launch()
    }

    /// Call on the queue.
    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "ConnectTimeout=10",
        ] + host.options + [host.target, "--", Self.remoteCommand]
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.ended(proc) }
        }

        buffer = Data()
        pending = []
        startedAt = Date()
        do {
            try p.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            scheduleRelaunch()
            return
        }
        process = p
        let script = Data((ProgramStatusRelay.script + "\n").utf8)
        DispatchQueue.global(qos: .utility).async {
            stdin.fileHandleForWriting.write(script)
            try? stdin.fileHandleForWriting.close()
        }
    }

    private func consume(_ data: Data) {
        guard !stopped else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            switch line {
            case "--end--":
                failures = 0
                onSnapshot(pending)
                pending = []
            case "--hb--":
                failures = 0
            default:
                if line.hasPrefix("--error--") { continue }
                pending.append(line)
            }
        }
    }

    private func ended(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        onSnapshot(nil)
        guard !stopped else { return }
        // A watcher that dies right away (no perl, no tmux, auth failure)
        // backs off and finally gives up; one that ran a while just
        // reconnects (network drop, sleep).
        if Date().timeIntervalSince(startedAt) < 30 { failures += 1 } else { failures = 0 }
        scheduleRelaunch()
    }

    private func scheduleRelaunch() {
        guard !stopped, failures < 6 else { return }
        let delay = min(300.0, 10.0 * pow(2.0, Double(failures)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }
}
