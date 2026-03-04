import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Initialize a pasteboard type from a MIME type string
    init?(mimeType: String) {
        // Explicit mappings for common MIME types
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        // Try to get UTType from MIME type
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier
            self.init(mimeType)
            return
        }

        // Use the UTType's identifier
        self.init(utType.identifier)
    }
}

extension NSPasteboard {
    /// The pasteboard to used for Ghostty selection.
    static var ghosttySelection: NSPasteboard = {
        NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    }()

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    /// - Tries to get any string from the pasteboard.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            return urls
                .map { url -> String in
                    guard url.isFileURL else { return url.absoluteString }
                    // Ephemeral screenshot files in NSIRD_* directories are cleaned up
                    // quickly by macOS. Copy them to a stable location so that child
                    // processes (especially those running inside tmux) can still read them.
                    let path = url.path
                    if path.contains("/TemporaryItems/NSIRD_") {
                        if let stable = Self.copyToStableTemp(url) {
                            return Ghostty.Shell.escape(stable)
                        }
                    }
                    return Ghostty.Shell.escape(path)
                }
                .joined(separator: " ")
        }

        return self.string(forType: .string)
    }

    /// Copy a file to /tmp/myghost_paste/ so it survives NSIRD cleanup.
    private static func copyToStableTemp(_ url: URL) -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("myghost_paste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        // Remove previous copy if it exists
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        default:
            return nil
        }
    }
}
