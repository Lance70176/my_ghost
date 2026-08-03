import Foundation

/// Watches the ordering MyGhost Web writes and reports it, so a reorder done
/// in the browser lands in the app's sidebar too.
///
/// The two sides sync through files rather than talking to each other: the app
/// publishes its order in `screen_sessions.json` (which the web server already
/// reads), and the browser publishes its order in `web_tabs.json`, which this
/// watches. Once the app adopts a browser order, both agree and the browser
/// drops its override — so the ordering converges instead of ping-ponging.
final class WebOrderSync {
    /// Called on the main queue with the session names, browser order first.
    var onOrderChanged: (([String]) -> Void)?

    /// Called on the main queue with session name → group name ("" = leave the
    /// group it is in).
    var onGroupsChanged: (([String: String]) -> Void)?

    private let fileURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var lastApplied: [String] = []
    private var lastGroups: [String: String] = [:]

    init() {
        fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGhost/web_tabs.json")
    }

    deinit { stop() }

    func start() {
        guard source == nil else { return }
        // Nothing to watch until the browser has saved something; retry later
        // rather than failing permanently.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.start()
            }
            return
        }
        descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Editors (and our own writer) replace the file, so re-arm on
                // the new inode instead of watching a deleted one.
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.start() }
                return
            }
            self.readAndReport()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        self.source = source
        source.resume()
        readAndReport()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func readAndReport() {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let groups = json["groups"] as? [String: String], groups != lastGroups {
            lastGroups = groups
            DispatchQueue.main.async { [weak self] in
                self?.onGroupsChanged?(groups)
            }
        }
        if let order = json["order"] as? [String], !order.isEmpty, order != lastApplied {
            lastApplied = order
            DispatchQueue.main.async { [weak self] in
                self?.onOrderChanged?(order)
            }
        }
    }
}
