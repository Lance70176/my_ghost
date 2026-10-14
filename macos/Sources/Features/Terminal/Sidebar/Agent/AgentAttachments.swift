import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files waiting to go with the next message

/// One attachment in the input area: uploaded to the daemon as soon as it's
/// added, so sending is instant.
struct AgentPendingFile: Identifiable {
    let id = UUID()
    let name: String
    /// Its mark in the text, like Claude Code's "[Image #1]"; empty for one
    /// that failed before it was added to the text.
    var label = ""
    let thumbnail: NSImage?
    var uploaded: AgentChatFile?
    var error: String?

    var uploading: Bool { uploaded == nil && error == nil }
}

/// The attachments of one input — the assistant's, or one conversation's.
/// Kept per host / project / reader like drafts, so leaving and coming back
/// keeps them.
@MainActor
final class AgentAttachmentTray: ObservableObject {
    static let maxBytes = 30 * 1024 * 1024

    @Published private(set) var files: [AgentPendingFile] = []
    let project: String
    /// "assistant", or the id of the conversation they're for.
    let target: String

    /// Set by the input field: put marks at the cursor / take one out.
    var insertLabels: (([String]) -> Void)?
    var eraseLabel: ((String) -> Void)?
    private var counter = 0

    private static var trays: [String: AgentAttachmentTray] = [:]

    static func tray(_ key: String, project: String, target: String) -> AgentAttachmentTray {
        if let t = trays[key] { return t }
        let t = AgentAttachmentTray(project: project, target: target)
        trays[key] = t
        return t
    }

    private init(project: String, target: String) {
        self.project = project
        self.target = target
    }

    var isEmpty: Bool { files.isEmpty }
    /// Something is still uploading, or failed and should be removed first.
    var blocking: Bool { files.contains { $0.uploaded == nil } }
    /// What to send: each stored file with its mark.
    var payload: [[String: String]] {
        files.compactMap { f in f.uploaded.map { ["path": $0.path, "label": f.label] } }
    }

    /// Attach and put their marks at the cursor (paste, drop, the paperclip).
    func attach(_ found: AgentPasteboard.Found, client: AgentDaemonClient) {
        var labels: [String] = []
        for url in found.urls {
            if let l = add(url: url, client: client) { labels.append(l) }
        }
        if let (data, image) = found.image {
            let name = "image-\(Self.stamp.string(from: Date())).png"
            labels.append(start(name: name, image: true, thumbnail: image, client: client) { data })
        }
        insertLabels?(labels)
    }

    private func add(url: URL, client: AgentDaemonClient) -> String? {
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            files.append(AgentPendingFile(name: name, thumbnail: nil, error: L("Folders can't be attached.")))
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else {
            files.append(AgentPendingFile(name: name, thumbnail: nil, error: L("Larger than 30 MB.")))
            return nil
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        let thumb = isImage ? NSImage(contentsOf: url) : NSWorkspace.shared.icon(forFile: url.path)
        return start(name: name, image: isImage, thumbnail: thumb, client: client) { try? Data(contentsOf: url) }
    }

    /// Remove an attachment (its ✕) and its mark from the text.
    func remove(_ id: UUID) {
        guard let f = files.first(where: { $0.id == id }) else { return }
        files.removeAll { $0.id == id }
        if !f.label.isEmpty { eraseLabel?(f.label) }
    }

    /// The text changed: an attachment whose mark was deleted goes too.
    func prune(_ text: String) {
        files.removeAll { !$0.label.isEmpty && !text.contains($0.label) }
        if files.isEmpty { counter = 0 }
    }

    /// Sent: drop them, leaving the text alone.
    func discard(_ ids: [UUID]) {
        files.removeAll { ids.contains($0.id) }
        if files.isEmpty { counter = 0 }
    }

    func clear() {
        files = []
        counter = 0
    }

    /// Put back what was sent when sending failed.
    func restore(_ old: [AgentPendingFile]) {
        files = old + files
        counter = max(counter, old.count + files.count)
    }

    private func start(name: String, image: Bool, thumbnail: NSImage?, client: AgentDaemonClient,
                       read: @escaping @Sendable () -> Data?) -> String {
        counter += 1
        let label = image ? "[Image #\(counter)]" : "[File #\(counter)]"
        let item = AgentPendingFile(name: name, label: label, thumbnail: thumbnail)
        files.append(item)
        let project = project, target = target
        Task {
            let data = await Task.detached(priority: .userInitiated) { read() }.value
            guard let data else {
                update(item.id) { $0.error = L("Couldn't read this file.") }
                return
            }
            let (file, err) = await client.upload(project: project, to: target, name: name, data: data)
            update(item.id) {
                $0.uploaded = file
                $0.error = file == nil ? (err ?? L("ghost-agentd refused the request")) : nil
            }
        }
        return label
    }

    private func update(_ id: UUID, _ change: (inout AgentPendingFile) -> Void) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        change(&files[i])
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

// MARK: - Reading files and images off a pasteboard

enum AgentPasteboard {
    struct Found {
        var urls: [URL] = []
        var image: (Data, NSImage)?
    }

    /// Files, or an image, if that's what the pasteboard holds; nil when it's
    /// text (left to the text view).
    static func attachments(_ pb: NSPasteboard) -> Found? {
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return Found(urls: urls) }
        // A screenshot or a copied image. Copied text that also carries an
        // image (rich text from some apps) stays text.
        guard pb.string(forType: .string) == nil,
              pb.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier]),
              let image = NSImage(pasteboard: pb) else { return nil }
        let png = pb.data(forType: .png) ?? pngData(image)
        guard let png else { return nil }
        return Found(image: (png, image))
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Dropped onto a SwiftUI view: file URLs and images.
    static func load(_ providers: [NSItemProvider], into tray: AgentAttachmentTray,
                     client: AgentDaemonClient) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in tray.attach(Found(urls: [url]), client: client) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let image = obj as? NSImage, let png = pngData(image) else { return }
                    Task { @MainActor in tray.attach(Found(image: (png, image)), client: client) }
                }
            }
        }
        return handled
    }
}

// MARK: - Input-area views

/// The paperclip: pick files to attach.
struct AgentAttachButton: View {
    @ObservedObject var tray: AgentAttachmentTray
    @EnvironmentObject private var client: AgentDaemonClient

    var body: some View {
        Button(action: pick) {
            Image(systemName: "paperclip").agentFont(.title3)
        }
        .buttonStyle(.borderless)
        .help(L("Attach files or images (you can also paste or drop them)"))
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let done: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK else { return }
            tray.attach(AgentPasteboard.Found(urls: panel.urls), client: client)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }
}

/// The attachments about to be sent, each removable.
struct AgentAttachmentStrip: View {
    @ObservedObject var tray: AgentAttachmentTray

    var body: some View {
        if !tray.files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tray.files) { chip($0) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func chip(_ f: AgentPendingFile) -> some View {
        HStack(spacing: 6) {
            Group {
                if let thumb = f.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc").agentFont(.title3)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                if !f.label.isEmpty {
                    Text(f.label).agentFont(.caption2, weight: .semibold).foregroundColor(.accentColor)
                }
                Text(f.name).agentFont(.caption).lineLimit(1).truncationMode(.middle)
                if let error = f.error {
                    Text(error).agentFont(.caption2).foregroundColor(.red).lineLimit(1)
                } else if f.uploading {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(L("Uploading…")).agentFont(.caption2).foregroundColor(.secondary)
                    }
                } else if let size = f.uploaded?.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .agentFont(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 160, alignment: .leading)
            Button { tray.remove(f.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L("Remove"))
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(f.error == nil ? Color.primary.opacity(0.06) : Color.red.opacity(0.1)))
    }
}

/// Drop files or images anywhere on a view to attach them.
struct AgentDropTarget: ViewModifier {
    let tray: AgentAttachmentTray
    let client: AgentDaemonClient
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                AgentPasteboard.load(providers, into: tray, client: client)
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.accentColor.opacity(0.06))
                        .overlay(Label(L("Drop to attach"), systemImage: "paperclip")
                            .agentFont(.headline).foregroundColor(.accentColor))
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Attachments of a sent message

/// Images as thumbnails, other files as chips; clicking opens them.
struct AgentSentFiles: View {
    let files: [AgentChatFile]
    let project: String
    var mine = true

    var body: some View {
        let images = files.filter { $0.kind == "image" }
        let others = files.filter { $0.kind != "image" }
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images, id: \.path) { AgentRemoteImage(file: $0, project: project) }
                }
            }
            ForEach(others, id: \.path) { AgentSentFileChip(file: $0, project: project) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

private struct AgentSentFileChip: View {
    let file: AgentChatFile
    let project: String

    var body: some View {
        AgentOpenAttachment(file: file, project: project) {
            Label(file.name, systemImage: "doc")
                .agentFont(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
    }
}

/// Your message with its attachments where their "[Image #1]" marks were,
/// as you wrote it; attachments without a mark go above.
struct AgentUserMessage: View {
    let text: String
    let files: [AgentChatFile]
    let project: String

    private enum Part {
        case text(String)
        case file(AgentChatFile)
    }

    private var placed: [AgentChatFile] {
        files.filter { !($0.label ?? "").isEmpty && text.contains($0.label ?? "") }
    }

    private var parts: [Part] {
        var out: [Part] = []
        var rest = Substring(text)
        while true {
            let hits = placed.compactMap { f in rest.range(of: f.label ?? "").map { ($0, f) } }
            guard let (range, f) = hits.min(by: { $0.0.lowerBound < $1.0.lowerBound }) else { break }
            let before = rest[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { out.append(.text(before)) }
            out.append(.file(f))
            rest = rest[range.upperBound...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(.text(tail)) }
        return out
    }

    var body: some View {
        let loose = files.filter { f in !placed.contains(where: { $0.path == f.path }) }
        VStack(alignment: .trailing, spacing: 4) {
            if !loose.isEmpty {
                AgentSentFiles(files: loose, project: project)
            }
            if placed.isEmpty {
                if !text.isEmpty { AgentBubble(text: text, mine: true) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let s):
                            Text(LocalizedStringKey(s)).agentFont(.body).textSelection(.enabled)
                        case .file(let f):
                            if f.kind == "image" {
                                AgentRemoteImage(file: f, project: project)
                            } else {
                                AgentSentFileChip(file: f, project: project)
                            }
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.22)))
                .frame(maxWidth: 620, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// Opens an attachment with its default app (fetched from the host first
/// when the host isn't this Mac).
struct AgentOpenAttachment<Label: View>: View {
    let file: AgentChatFile
    let project: String
    @ViewBuilder let label: () -> Label
    @EnvironmentObject private var client: AgentDaemonClient
    @State private var opening = false

    var body: some View {
        Button {
            guard !opening else { return }
            opening = true
            Task {
                if let url = await AgentAttachmentCache.localURL(file, project: project, client: client) {
                    NSWorkspace.shared.open(url)
                }
                opening = false
            }
        } label: { label() }
        .buttonStyle(.plain)
        .help(file.name)
    }
}

/// A sent image, loaded from the daemon.
private struct AgentRemoteImage: View {
    let file: AgentChatFile
    let project: String
    @EnvironmentObject private var client: AgentDaemonClient
    @Environment(\.agentZoom) private var zoom
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        AgentOpenAttachment(file: file, project: project) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if failed {
                    Label(file.name, systemImage: "photo").agentFont(.callout).padding(8)
                } else {
                    ProgressView().controlSize(.small).frame(width: 80, height: 60)
                }
            }
            .frame(maxWidth: 240 * zoom, maxHeight: 180 * zoom)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        }
        .task(id: file.path) {
            if let data = await AgentAttachmentCache.data(file, project: project, client: client),
               let img = NSImage(data: data) {
                image = img
            } else {
                failed = true
            }
        }
    }
}

/// Attachments fetched from a host, kept for the session.
@MainActor
enum AgentAttachmentCache {
    private static let memory = NSCache<NSString, NSData>()

    static func data(_ file: AgentChatFile, project: String, client: AgentDaemonClient) async -> Data? {
        let key = "\(client.hostKey)|\(file.path)" as NSString
        if let d = memory.object(forKey: key) { return d as Data }
        let data: Data?
        if client.isLocal {
            data = await Task.detached { try? Data(contentsOf: URL(fileURLWithPath: file.path)) }.value
        } else {
            data = await client.attachment(project: project, path: file.path)
        }
        if let data { memory.setObject(data as NSData, forKey: key) }
        return data
    }

    /// A file on this Mac to open: the original on this host, a copy otherwise.
    static func localURL(_ file: AgentChatFile, project: String, client: AgentDaemonClient) async -> URL? {
        if client.isLocal { return URL(fileURLWithPath: file.path) }
        guard let data = await data(file, project: project, client: client) else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGhost/agent-attachments", isDirectory: true)
            // The stored name is unique (stamped); the copy keeps the shown one.
            .appendingPathComponent(URL(fileURLWithPath: file.path).lastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.name)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
