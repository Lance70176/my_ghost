import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Controls MyGhost Web — the Node server in `web/` that serves the tmux
/// sessions to a browser, so the same tabs are usable from Windows, a phone,
/// or anything else on the network.
///
/// The server is owned by launchd rather than by this app: it must survive the
/// app quitting (that is the whole point — the sessions outlive the app too),
/// and launchd gives it start-at-login and restart-on-crash for free. Enabling
/// writes the LaunchAgent and boots it; disabling boots it out and removes the
/// plist so it doesn't come back at the next login.
@MainActor
final class WebAccessManager: ObservableObject {
    static let shared = WebAccessManager()

    static let label = "com.myghost.web"
    static let defaultPort = 8899

    /// Whether the LaunchAgent is loaded and the server answers.
    @Published private(set) var isRunning = false
    /// Set while enable/disable is in flight so the UI can show progress.
    @Published private(set) var isBusy = false
    /// Why the toggle is unavailable, when it is.
    @Published private(set) var unavailableReason: String?
    /// Reachable URLs, best first (tailnet, then LAN, then loopback).
    @Published private(set) var urls: [WebAccessURL] = []

    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "MyGhostWebPort") }
    }
    /// Skip the token check — for networks where every device is trusted.
    @Published var noAuth: Bool {
        didSet { UserDefaults.standard.set(noAuth, forKey: "MyGhostWebNoAuth") }
    }

    private let fileManager = FileManager.default

    private init() {
        let defaults = UserDefaults.standard
        let savedPort = defaults.integer(forKey: "MyGhostWebPort")
        port = savedPort > 0 ? savedPort : Self.defaultPort
        noAuth = defaults.bool(forKey: "MyGhostWebNoAuth")
    }

    // MARK: - Paths

    private var supportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGhost")
    }

    private var plistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    /// Where `web/` lives. `install-launchd.sh` records the directory it ran
    /// from; an already-installed agent names it too. Falling back to a couple
    /// of conventional spots keeps a hand-copied install working.
    var webDirectory: URL? {
        let pointer = supportDirectory.appendingPathComponent("web_dir")
        if let path = try? String(contentsOf: pointer, encoding: .utf8) {
            let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            if fileManager.fileExists(atPath: url.appendingPathComponent("server.js").path) {
                return url
            }
        }
        if let plist = NSDictionary(contentsOf: plistURL),
           let dir = plist["WorkingDirectory"] as? String {
            let url = URL(fileURLWithPath: dir)
            if fileManager.fileExists(atPath: url.appendingPathComponent("server.js").path) {
                return url
            }
        }
        let candidates = [
            supportDirectory.appendingPathComponent("web"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("myghost-web"),
        ]
        return candidates.first {
            fileManager.fileExists(atPath: $0.appendingPathComponent("server.js").path)
        }
    }

    private func nodeExecutable() -> String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    // MARK: - Status

    func refresh() {
        guard webDirectory != nil else {
            unavailableReason = "MyGhost Web isn't installed on this Mac. "
                + "Run web/install-launchd.sh from the MyGhost source once to set it up."
            isRunning = false
            urls = []
            return
        }
        guard nodeExecutable() != nil else {
            unavailableReason = "Node.js not found. Install it with: brew install node"
            isRunning = false
            urls = []
            return
        }
        unavailableReason = nil

        let loaded = run("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.label)"]) != nil
        isRunning = loaded
        // An agent installed from the shell is the source of truth for how the
        // server is actually running, so the panel matches reality (and the
        // URLs carry a token only when the server wants one).
        if loaded { syncFromInstalledAgent() }
        urls = loaded ? buildURLs() : []
    }

    private func syncFromInstalledAgent() {
        guard let plist = NSDictionary(contentsOf: plistURL),
              let env = plist["EnvironmentVariables"] as? [String: String]
        else { return }
        if let value = env["MYGHOST_WEB_PORT"], let installed = Int(value), installed != port {
            port = installed
        }
        let installedNoAuth = env["MYGHOST_WEB_NO_AUTH"] == "1"
        if installedNoAuth != noAuth { noAuth = installedNoAuth }
    }

    // MARK: - Enable / disable

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            if enabled { writeAgentAndBoot() } else { bootOutAndRemove() }
            // The server needs a moment to bind before its URLs are useful.
            try? await Task.sleep(nanoseconds: 900_000_000)
            isBusy = false
            refresh()
        }
    }

    private func writeAgentAndBoot() {
        guard let webDirectory, let node = nodeExecutable() else { return }
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [node, webDirectory.appendingPathComponent("server.js").path],
            "WorkingDirectory": webDirectory.path,
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "MYGHOST_WEB_PORT": String(port),
                "MYGHOST_WEB_NO_AUTH": noAuth ? "1" : "0",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": webDirectory.appendingPathComponent("web.log").path,
            "StandardErrorPath": webDirectory.appendingPathComponent("web.log").path,
        ]
        try? fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        (plist as NSDictionary).write(to: plistURL, atomically: true)

        // Replace any previous instance so a changed port takes effect.
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.label)"])
        _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func bootOutAndRemove() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.label)"])
        try? fileManager.removeItem(at: plistURL)
    }

    // MARK: - URLs

    private func token() -> String? {
        guard !noAuth else { return nil }
        let file = supportDirectory.appendingPathComponent("web_token")
        return (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildURLs() -> [WebAccessURL] {
        let suffix = token().map { "/?token=\($0)" } ?? ""
        var result: [WebAccessURL] = []
        for address in Self.localAddresses() {
            let kind: WebAccessURL.Kind
            if address.hasPrefix("100.") {
                // Tailscale hands out 100.64.0.0/10 — reachable from anywhere
                // the device is signed in, not just the local network.
                kind = .tailnet
            } else {
                kind = .lan
            }
            result.append(WebAccessURL(
                kind: kind,
                address: address,
                url: "http://\(address):\(port)\(suffix)"))
        }
        result.sort { $0.kind.rank < $1.kind.rank }
        result.append(WebAccessURL(
            kind: .local, address: "127.0.0.1",
            url: "http://127.0.0.1:\(port)\(suffix)"))
        return result
    }

    /// Non-loopback IPv4 addresses of this Mac.
    private static func localAddresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let address = String(cString: host)
            if !address.isEmpty, !addresses.contains(address) { addresses.append(address) }
        }
        return addresses
    }

    // MARK: - Helpers

    /// Run a command, returning stdout, or nil when it exits non-zero.
    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A QR code for `string`, scaled up so it stays crisp.
    static func qrImage(for string: String, size: CGFloat = 180) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

/// One address the web UI can be reached on.
struct WebAccessURL: Identifiable, Hashable {
    enum Kind {
        case tailnet, lan, local

        var rank: Int {
            switch self {
            case .tailnet: return 0
            case .lan: return 1
            case .local: return 2
            }
        }

        var label: String {
            switch self {
            case .tailnet: return "Tailscale"
            case .lan: return "Local network"
            case .local: return "This Mac"
            }
        }

        var detail: String {
            switch self {
            case .tailnet: return "works from anywhere your devices are signed in"
            case .lan: return "same Wi-Fi / LAN only"
            case .local: return "this Mac only"
            }
        }
    }

    let kind: Kind
    let address: String
    let url: String

    var id: String { url }
}
