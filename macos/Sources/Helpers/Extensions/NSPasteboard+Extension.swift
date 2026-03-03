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

    /// Save image data from the pasteboard to a temporary file and return the escaped path.
    /// Returns nil if no image data is available.
    private func saveImageToTemp() -> String? {
        // Check for image data (TIFF, PNG)
        guard let image = readObjects(forClasses: [NSImage.self]) as? [NSImage],
              let first = image.first,
              let tiffData = first.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:])
        else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "paste_\(timestamp).png"
        let destURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures")
            .appendingPathComponent(filename)

        // Ensure ~/Pictures exists
        try? FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            try pngData.write(to: destURL)
            return Ghostty.Shell.escape(destURL.path)
        } catch {
            return nil
        }
    }

    /// Check if a file URL is accessible; if not and it's an image, copy it to ~/Pictures.
    private func accessiblePath(for url: URL) -> String {
        if FileManager.default.isReadableFile(atPath: url.path) {
            return Ghostty.Shell.escape(url.path)
        }

        // File not accessible — try to copy it to ~/Pictures
        let filename = url.lastPathComponent
        let destURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures")
            .appendingPathComponent(filename)

        try? FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let _ = try? FileManager.default.copyItem(at: url, to: destURL) {
            return Ghostty.Shell.escape(destURL.path)
        }

        // Couldn't copy either, return original escaped path
        return Ghostty.Shell.escape(url.path)
    }

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    ///   If the file is in a restricted temp directory, copies it to ~/Pictures first.
    /// - Tries to get image data from the pasteboard, saves it as PNG to ~/Pictures, and returns the escaped path.
    /// - Tries to get any string from the pasteboard.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            return urls
                .map { $0.isFileURL ? accessiblePath(for: $0) : $0.absoluteString }
                .joined(separator: " ")
        }

        // Check for image data (e.g. copied screenshot, Cmd+Shift+Ctrl+4)
        if let imagePath = saveImageToTemp() {
            return imagePath
        }

        return self.string(forType: .string)
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
