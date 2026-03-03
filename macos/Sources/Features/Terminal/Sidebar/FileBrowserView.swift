import SwiftUI
import AppKit

/// A tree node representing a file or directory.
class FileNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    let depth: Int

    @Published var isExpanded: Bool = false
    @Published var children: [FileNode]?

    init(url: URL, isDirectory: Bool, depth: Int) {
        self.name = url.lastPathComponent
        self.url = url
        self.isDirectory = isDirectory
        self.depth = depth
    }

    func loadChildren() {
        guard isDirectory, children == nil else { return }
        let fm = FileManager.default
        do {
            let urls = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            children = urls.compactMap { childURL in
                let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: childURL, isDirectory: isDir, depth: depth + 1)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            children = []
        }
    }

    func toggle() {
        if isExpanded {
            isExpanded = false
        } else {
            loadChildren()
            isExpanded = true
        }
    }

    func reload() {
        children = nil
        if isExpanded {
            loadChildren()
        }
    }
}

/// Observable state for the file browser, persisted across mode switches.
class FileBrowserState: ObservableObject {
    @Published var currentPath: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var rootNodes: [FileNode] = []

    /// For backward compatibility with breadcrumb and flat entry access
    @Published var entries: [FileEntry] = []

    /// Callback to send text (e.g. cd command) to the focused terminal surface.
    var onSendText: ((String) -> Void)?
    /// Callback to open a new terminal tab at a given directory.
    var onOpenInNewTab: ((String) -> Void)?
    /// Callback to refocus the terminal after interacting with the file browser.
    var onRefocusTerminal: (() -> Void)?

    var pathComponents: [(name: String, url: URL)] {
        var components: [(name: String, url: URL)] = []
        var url = currentPath
        while url.path != "/" {
            components.insert((name: url.lastPathComponent, url: url), at: 0)
            url = url.deletingLastPathComponent()
        }
        components.insert((name: "/", url: URL(fileURLWithPath: "/")), at: 0)
        return components
    }

    /// Collect all expanded folder paths from a node tree.
    private func expandedPaths(in nodes: [FileNode]) -> Set<URL> {
        var paths = Set<URL>()
        for node in nodes where node.isDirectory && node.isExpanded {
            paths.insert(node.url)
            if let children = node.children {
                paths.formUnion(expandedPaths(in: children))
            }
        }
        return paths
    }

    /// Restore expansion state for nodes whose paths are in the given set.
    private func restoreExpanded(_ paths: Set<URL>, in nodes: [FileNode]) {
        for node in nodes where node.isDirectory && paths.contains(node.url) {
            node.loadChildren()
            node.isExpanded = true
            if let children = node.children {
                restoreExpanded(paths, in: children)
            }
        }
    }

    func loadEntries() {
        let previouslyExpanded = expandedPaths(in: rootNodes)
        let fm = FileManager.default
        do {
            let urls = try fm.contentsOfDirectory(
                at: currentPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            rootNodes = urls.compactMap { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: url, isDirectory: isDir, depth: 0)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            restoreExpanded(previouslyExpanded, in: rootNodes)
        } catch {
            rootNodes = []
        }
    }

    func navigate(to url: URL) {
        currentPath = url
        loadEntries()
    }

    /// Flatten the visible tree for keyboard shortcut support
    func visibleNode(withID id: UUID) -> FileNode? {
        func find(in nodes: [FileNode]) -> FileNode? {
            for node in nodes {
                if node.id == id { return node }
                if node.isExpanded, let children = node.children {
                    if let found = find(in: children) { return found }
                }
            }
            return nil
        }
        return find(in: rootNodes)
    }
}

/// Backward-compatible simple entry (used by keyboard shortcuts)
struct FileEntry: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
}

/// A file browser view that displays directory contents as an expandable tree.
struct FileBrowserView: View {
    @ObservedObject var state: FileBrowserState
    @State private var selectedNodeID: UUID?
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb path + refresh
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(state.pathComponents.enumerated()), id: \.offset) { index, component in
                            if index > 0 {
                                Text("/")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            Button(action: {
                                state.navigate(to: component.url)
                                selectedNodeID = nil
                            }) {
                                Text(component.name)
                                    .font(.system(size: 14))
                                    .foregroundColor(
                                        component.url == state.currentPath ? .primary : .accentColor
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button(action: { state.loadEntries() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Divider()

            // Tree list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.rootNodes) { node in
                        TreeNodeView(node: node, state: state, selectedNodeID: $selectedNodeID)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            if state.rootNodes.isEmpty {
                state.loadEntries()
            }
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                state.loadEntries()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .background(FileBrowserKeyMonitor(
            isFileBrowserActive: true,
            onSpace: {
                guard let id = selectedNodeID, let node = state.visibleNode(withID: id) else { return }
                if !node.isDirectory {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                    task.arguments = ["-p", node.url.path]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    try? task.run()
                }
            },
            onReturn: {
                guard let id = selectedNodeID, let node = state.visibleNode(withID: id) else { return }
                let entry = FileEntry(name: node.name, url: node.url, isDirectory: node.isDirectory)
                FileBrowserActions.rename(entry: entry, state: state)
            },
            onDelete: {
                guard let id = selectedNodeID, let node = state.visibleNode(withID: id) else { return }
                let entry = FileEntry(name: node.name, url: node.url, isDirectory: node.isDirectory)
                FileBrowserActions.delete(entry: entry, state: state)
            }
        ))
    }
}

// MARK: - Tree node row

private struct TreeNodeView: View {
    @ObservedObject var node: FileNode
    @ObservedObject var state: FileBrowserState
    @Binding var selectedNodeID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The row itself
            TreeRowContent(node: node, state: state, selectedNodeID: $selectedNodeID)

            // Expanded children
            if node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    TreeNodeView(node: child, state: state, selectedNodeID: $selectedNodeID)
                }
            }
        }
    }
}

private struct TreeRowContent: View {
    @ObservedObject var node: FileNode
    @ObservedObject var state: FileBrowserState
    @Binding var selectedNodeID: UUID?

    var isSelected: Bool { selectedNodeID == node.id }

    var body: some View {
        HStack(spacing: 4) {
            // Indent based on depth
            if node.depth > 0 {
                Spacer()
                    .frame(width: CGFloat(node.depth) * 16)
            }

            // Disclosure triangle for directories
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { node.toggle() }
            } else {
                Spacer().frame(width: 12)
            }

            // Icon (directories only)
            if node.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                    .frame(width: 18, height: 16)
            }

            // Name
            Text(node.name)
                .font(.system(size: NSFont.smallSystemFontSize))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedNodeID = node.id
            if node.isDirectory {
                node.toggle()
            }
        }
        .onDrag {
            // Drag file → provide path as text for terminal drop
            let escapedPath = node.url.path.replacingOccurrences(of: " ", with: "\\ ")
            return NSItemProvider(object: escapedPath as NSString)
        }
        .contextMenu {
            if node.isDirectory {
                Button("cd to Directory") {
                    let escapedPath = node.url.path.replacingOccurrences(of: "'", with: "'\\''")
                    state.onSendText?("cd '\(escapedPath)'\n")
                }
                Button("Open in New Tab") {
                    state.onOpenInNewTab?(node.url.path)
                }
                Divider()
            }
            Button("New File") {
                FileBrowserActions.newFile(in: state)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Divider()
            Button("Rename") {
                let entry = FileEntry(name: node.name, url: node.url, isDirectory: node.isDirectory)
                FileBrowserActions.rename(entry: entry, state: state)
            }
            Button("Delete") {
                let entry = FileEntry(name: node.name, url: node.url, isDirectory: node.isDirectory)
                FileBrowserActions.delete(entry: entry, state: state)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            Button("Copy Relative Path") {
                let basePath = state.currentPath.path
                var relativePath = node.url.path
                if relativePath.hasPrefix(basePath) {
                    relativePath = String(relativePath.dropFirst(basePath.count))
                    if relativePath.hasPrefix("/") {
                        relativePath = String(relativePath.dropFirst())
                    }
                }
                if relativePath.isEmpty { relativePath = node.name }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(relativePath, forType: .string)
            }
        }
    }
}

// MARK: - Focus-stealing click interceptor

/// An invisible NSView overlay that steals first responder from the terminal
/// when the user clicks in the file browser area. Also monitors key events
/// for Space (Quick Look), Return (Rename), Cmd+Delete (Trash).
private struct FileBrowserKeyMonitor: NSViewRepresentable {
    let isFileBrowserActive: Bool
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> FileBrowserKeyNSView {
        let view = FileBrowserKeyNSView()
        view.onSpace = onSpace
        view.onReturn = onReturn
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: FileBrowserKeyNSView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onReturn = onReturn
        nsView.onDelete = onDelete
    }
}

private class FileBrowserKeyNSView: NSView {
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    private var monitor: Any?
    private var clickMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        // Monitor mouse clicks in the file browser area to steal focus from terminal
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self = self, let myWindow = self.window else { return event }
                guard myWindow == event.window else { return event }

                // Check if click is within our view's frame
                let locationInWindow = event.locationInWindow
                let locationInView = self.convert(locationInWindow, from: nil)
                if self.bounds.contains(locationInView) {
                    // Steal focus from terminal
                    myWindow.makeFirstResponder(self)
                }
                return event
            }
        }

        // Monitor key events when we are first responder
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                guard self.window == event.window else { return event }
                // Only intercept when WE are first responder (file browser has focus)
                guard self.window?.firstResponder === self else { return event }

                // Let Cmd+key combinations pass through (e.g. Cmd+1..9 for tab switching)
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) {
                    // Except Cmd+Delete which we handle
                    if event.keyCode == 51 {
                        self.onDelete?()
                        return nil
                    }
                    return event
                }

                switch event.keyCode {
                case 49: // Space → Quick Look
                    self.onSpace?()
                    return nil
                case 36: // Return → Rename
                    self.onReturn?()
                    return nil
                default:
                    // Consume other key events so they don't reach the terminal
                    return nil
                }
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            removeMonitors()
        }
    }

    private func removeMonitors() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let clickMonitor = clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    deinit {
        removeMonitors()
    }
}

// MARK: - File browser actions

enum FileBrowserActions {

    static func newFile(in state: FileBrowserState) {
        let alert = NSAlert()
        alert.messageText = "New File"
        alert.informativeText = "Enter a name for the new file:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "untitled"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let newURL = state.currentPath.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: newURL.path) {
                let errAlert = NSAlert()
                errAlert.messageText = "A file named \"\(name)\" already exists."
                errAlert.runModal()
                return
            }
            let success = FileManager.default.createFile(atPath: newURL.path, contents: nil)
            if success {
                state.loadEntries()
            } else {
                let errAlert = NSAlert()
                errAlert.messageText = "Failed to create file \"\(name)\"."
                errAlert.runModal()
            }
        }
    }

    static func rename(entry: FileEntry, state: FileBrowserState) {
        let alert = NSAlert()
        alert.messageText = "Rename \"\(entry.name)\""
        alert.informativeText = "Enter a new name:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != entry.name else { return }
            let newURL = entry.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: entry.url, to: newURL)
                state.loadEntries()
            } catch {
                let errAlert = NSAlert(error: error)
                errAlert.runModal()
            }
        }
    }

    static func delete(entry: FileEntry, state: FileBrowserState) {
        let alert = NSAlert()
        alert.messageText = "Move \"\(entry.name)\" to Trash?"
        alert.informativeText = "You can restore this item from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                state.loadEntries()
            } catch {
                let errAlert = NSAlert(error: error)
                errAlert.runModal()
            }
        }
    }
}
