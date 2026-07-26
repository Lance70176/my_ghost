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
    /// True while a background directory read for this node is in flight.
    @Published var isLoading: Bool = false

    init(url: URL, isDirectory: Bool, depth: Int) {
        self.name = url.lastPathComponent
        self.url = url
        self.isDirectory = isDirectory
        self.depth = depth
    }

    /// Load this directory's children off the main thread so expanding a folder
    /// with many entries never blocks/freezes the UI. `completion` runs on the
    /// main thread after `children` is set.
    func loadChildren(completion: (() -> Void)? = nil) {
        guard isDirectory, children == nil, !isLoading else { return }
        isLoading = true
        let dirURL = url
        let childDepth = depth + 1
        FileBrowserState.ioQueue.async {
            let loaded = FileBrowserState.readDirectory(at: dirURL).map {
                FileNode(url: $0.url, isDirectory: $0.isDirectory, depth: childDepth)
            }
            DispatchQueue.main.async {
                self.children = loaded
                self.isLoading = false
                completion?()
            }
        }
    }
}

/// Observable state for the file browser, persisted across mode switches.
class FileBrowserState: ObservableObject {
    @Published var currentPath: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var rootNodes: [FileNode] = []

    /// The expanded tree flattened into the rows currently visible, in display
    /// order. The list renders this flat array inside a single LazyVStack so
    /// row creation stays lazy at every depth — rendering the tree recursively
    /// materialized a folder's entire subtree the moment it was expanded, which
    /// froze the UI on folders with thousands of entries.
    @Published private(set) var visibleRows: [FileNode] = []

    /// For backward compatibility with breadcrumb and flat entry access
    @Published var entries: [FileEntry] = []

    /// Callback to send text (e.g. cd command) to the focused terminal surface.
    var onSendText: ((String) -> Void)?
    /// Callback to open a new terminal tab at a given directory.
    var onOpenInNewTab: ((String) -> Void)?
    /// Callback to refocus the terminal after interacting with the file browser.
    var onRefocusTerminal: (() -> Void)?
    /// Callback to open a file in the built-in editor mode.
    var onEditFile: ((URL) -> Void)?

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

    /// Serial-ish background queue for all file-system reads, so directory
    /// scans (which can be slow for folders with many entries) never run on the
    /// main thread and freeze the UI.
    static let ioQueue = DispatchQueue(label: "com.myghost.filebrowser.io", qos: .userInitiated)

    /// True while a background refresh scan is in flight, used to avoid piling
    /// up overlapping scans when the 2s timer fires faster than a large tree can
    /// be read.
    private var isScanning = false

    /// Read a single directory level (the expensive syscalls + sort). Safe to
    /// call off the main thread.
    static func readDirectory(at url: URL) -> [(url: URL, isDirectory: Bool)] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.map { childURL -> (url: URL, isDirectory: Bool) in
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (url: childURL, isDirectory: isDir)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    /// Lightweight, thread-safe snapshot of a scanned directory tree. Produced
    /// entirely on the background queue, then reconciled into the live FileNode
    /// tree on the main thread.
    private struct ScanEntry {
        let url: URL
        let isDirectory: Bool
        let depth: Int
        let children: [ScanEntry]?
    }

    /// Collect the paths of every currently-expanded directory so the background
    /// scan knows how deep to recurse. Must be called on the main thread.
    private static func expandedPaths(in nodes: [FileNode], into set: inout Set<String>) {
        for node in nodes where node.isExpanded {
            set.insert(node.url.path)
            if let children = node.children {
                expandedPaths(in: children, into: &set)
            }
        }
    }

    /// Recursively scan `url`, descending only into directories whose path is in
    /// `expanded`. Runs on the background queue — touches no FileNode state.
    private static func scan(url: URL, depth: Int, expanded: Set<String>) -> [ScanEntry] {
        return readDirectory(at: url).map { entry -> ScanEntry in
            var children: [ScanEntry]? = nil
            if entry.isDirectory && expanded.contains(entry.url.path) {
                children = scan(url: entry.url, depth: depth + 1, expanded: expanded)
            }
            return ScanEntry(url: entry.url, isDirectory: entry.isDirectory, depth: depth, children: children)
        }
    }

    /// Reconcile a background scan snapshot into the live FileNode tree, reusing
    /// existing FileNode objects for unchanged paths. Reuse keeps each node's
    /// identity (and thus SwiftUI row identity, scroll position, selection, and
    /// expansion state) stable across the periodic refresh; only added/removed
    /// files produce new nodes. Must be called on the main thread.
    private static func reconcile(_ entries: [ScanEntry], reusing existing: [FileNode]) -> [FileNode] {
        var existingByPath: [String: FileNode] = [:]
        for node in existing { existingByPath[node.url.path] = node }

        return entries.map { entry -> FileNode in
            let node: FileNode
            if let reused = existingByPath[entry.url.path], reused.isDirectory == entry.isDirectory {
                node = reused
            } else {
                node = FileNode(url: entry.url, isDirectory: entry.isDirectory, depth: entry.depth)
            }
            if let childEntries = entry.children {
                let refreshed = reconcile(childEntries, reusing: node.children ?? [])
                if !(node.children?.elementsEqual(refreshed, by: ===) ?? false) {
                    node.children = refreshed
                }
            }
            return node
        }
    }

    func loadEntries(force: Bool = false) {
        // Skip overlapping periodic refreshes, but never drop a user-initiated
        // load (navigation, manual refresh) even if a scan is already running.
        guard force || !isScanning else { return }
        isScanning = true

        var expanded = Set<String>()
        Self.expandedPaths(in: rootNodes, into: &expanded)
        let path = currentPath

        Self.ioQueue.async {
            let entries = Self.scan(url: path, depth: 0, expanded: expanded)
            DispatchQueue.main.async {
                self.isScanning = false
                // The user may have navigated away while the scan was running.
                guard self.currentPath == path else { return }
                let refreshed = Self.reconcile(entries, reusing: self.rootNodes)
                if !refreshed.elementsEqual(self.rootNodes, by: ===) {
                    self.rootNodes = refreshed
                }
                // Reconcile can swap children of reused nodes even when the
                // top level is identical, so always re-derive the flat rows.
                self.rebuildVisibleRows()
            }
        }
    }

    func navigate(to url: URL) {
        currentPath = url
        // Clear the old directory's rows immediately for responsiveness; the new
        // contents arrive from the background scan.
        rootNodes = []
        rebuildVisibleRows()
        loadEntries(force: true)
    }

    /// Expand or collapse a directory row and refresh the flat row list.
    /// Children load in the background on first expansion and slot in when
    /// ready, so a huge folder never blocks the main thread.
    func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if node.isExpanded {
            node.isExpanded = false
            rebuildVisibleRows()
        } else {
            node.isExpanded = true
            rebuildVisibleRows()
            node.loadChildren { [weak self] in
                self?.rebuildVisibleRows()
            }
        }
    }

    /// Re-derive `visibleRows` from the tree. Skips the publish when the rows
    /// are identical so the 2s auto-refresh doesn't cause needless re-renders.
    private func rebuildVisibleRows() {
        var rows: [FileNode] = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                rows.append(node)
                if node.isExpanded, let children = node.children {
                    walk(children)
                }
            }
        }
        walk(rootNodes)
        if !rows.elementsEqual(visibleRows, by: ===) {
            visibleRows = rows
        }
    }

    /// Look up a visible row for keyboard shortcut support
    func visibleNode(withID id: UUID) -> FileNode? {
        visibleRows.first { $0.id == id }
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

                Button(action: { state.loadEntries(force: true) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)

            Divider()

            // Tree list, rendered as a flat lazy list of the visible rows so
            // expanding a folder with thousands of entries stays responsive.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(state.visibleRows) { node in
                        TreeRowContent(node: node, state: state, selectedNodeID: $selectedNodeID)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
        .onAppear {
            if state.rootNodes.isEmpty {
                state.loadEntries()
            }
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
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

private struct TreeRowContent: View {
    @ObservedObject var node: FileNode
    @ObservedObject var state: FileBrowserState
    @Binding var selectedNodeID: UUID?

    var isSelected: Bool { selectedNodeID == node.id }

    var body: some View {
        HStack(spacing: 6) {
            // Indent based on depth
            if node.depth > 0 {
                Spacer()
                    .frame(width: CGFloat(node.depth) * 18)
            }

            // Disclosure triangle for directories
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { state.toggle(node) }
            } else {
                Spacer().frame(width: 14)
            }

            // Icon
            if node.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                    .frame(width: 20, height: 18)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 18)
            }

            // Name
            Text(node.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedNodeID = node.id
            if node.isDirectory {
                state.toggle(node)
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !node.isDirectory {
                NSWorkspace.shared.open(node.url)
            }
        })
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
            if !node.isDirectory {
                Button("Open") {
                    NSWorkspace.shared.open(node.url)
                }
                Button("Edit") {
                    state.onEditFile?(node.url)
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
                state.loadEntries(force: true)
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
                state.loadEntries(force: true)
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
                state.loadEntries(force: true)
            } catch {
                let errAlert = NSAlert(error: error)
                errAlert.runModal()
            }
        }
    }
}
