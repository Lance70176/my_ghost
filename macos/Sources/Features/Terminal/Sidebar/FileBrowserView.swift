import SwiftUI
import AppKit

/// A simple file entry for listing directory contents.
struct FileEntry: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
}

/// Observable state for the file browser, persisted across mode switches.
class FileBrowserState: ObservableObject {
    @Published var currentPath: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var entries: [FileEntry] = []

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

    func loadEntries() {
        let fm = FileManager.default
        do {
            let urls = try fm.contentsOfDirectory(
                at: currentPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            entries = urls.compactMap { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileEntry(name: url.lastPathComponent, url: url, isDirectory: isDir)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            entries = []
        }
    }

    func navigate(to url: URL) {
        currentPath = url
        loadEntries()
    }
}

/// A file browser view that displays directory contents.
struct FileBrowserView: View {
    @ObservedObject var state: FileBrowserState
    @State private var selectedEntryID: UUID?

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
                                selectedEntryID = nil
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

            // File list
            List(state.entries, selection: $selectedEntryID) { entry in
                FileRowView(entry: entry, state: state)
                    .tag(entry.id)
            }
            .listStyle(.sidebar)
            .onChange(of: selectedEntryID) { newValue in
                guard let newValue = newValue,
                      let entry = state.entries.first(where: { $0.id == newValue }),
                      entry.isDirectory else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    state.navigate(to: entry.url)
                    selectedEntryID = nil
                }
            }
        }
        .onAppear {
            if state.entries.isEmpty {
                state.loadEntries()
            }
        }
        .background(FileListKeyMonitor(
            onSpace: {
                guard let selectedID = selectedEntryID,
                      let entry = state.entries.first(where: { $0.id == selectedID }) else { return }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                task.arguments = ["-p", entry.url.path]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()
            },
            onReturn: {
                guard let selectedID = selectedEntryID,
                      let entry = state.entries.first(where: { $0.id == selectedID }) else { return }
                FileBrowserActions.rename(entry: entry, state: state)
            },
            onDelete: {
                guard let selectedID = selectedEntryID,
                      let entry = state.entries.first(where: { $0.id == selectedID }) else { return }
                FileBrowserActions.delete(entry: entry, state: state)
            }
        ))
    }
}

// MARK: - Keyboard shortcuts (only when List has focus)

/// Monitors key presses only when the first responder is
/// an NSTableView/NSOutlineView (SwiftUI List), not the terminal.
private struct FileListKeyMonitor: NSViewRepresentable {
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> FileListKeyNSView {
        let view = FileListKeyNSView()
        view.onSpace = onSpace
        view.onReturn = onReturn
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: FileListKeyNSView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onReturn = onReturn
        nsView.onDelete = onDelete
    }
}

private class FileListKeyNSView: NSView {
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                guard self.window == event.window else { return event }

                // Only intercept when first responder is a table view (List)
                guard let responder = self.window?.firstResponder,
                      responder is NSTableView || responder is NSOutlineView else {
                    return event
                }

                switch event.keyCode {
                case 49: // Space → Quick Look
                    self.onSpace?()
                    return nil
                case 36: // Return → Rename
                    self.onReturn?()
                    return nil
                case 51: // Delete/Backspace
                    if event.modifierFlags.contains(.command) { // Cmd+Delete → Move to Trash
                        self.onDelete?()
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil, let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - File browser actions

enum FileBrowserActions {

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

// MARK: - Row view using NSViewRepresentable for proper context menu + drag

/// Each file row is an NSView so we get native right-click menu and drag support,
/// bypassing SwiftUI's broken .contextMenu + .draggable interaction.
private struct FileRowView: NSViewRepresentable {
    let entry: FileEntry
    let state: FileBrowserState

    func makeNSView(context: Context) -> FileRowNSView {
        let view = FileRowNSView()
        view.configure(entry: entry, state: state)
        return view
    }

    func updateNSView(_ nsView: FileRowNSView, context: Context) {
        nsView.configure(entry: entry, state: state)
    }
}

private class FileRowNSView: NSView {
    private var entry: FileEntry?
    private var state: FileBrowserState?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(entry: FileEntry, state: FileBrowserState) {
        self.entry = entry
        self.state = state

        let iconName = entry.isDirectory ? NSImage.folderName : "doc"
        if entry.isDirectory {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            iconView.contentTintColor = .controlAccentColor
        } else {
            iconView.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        }
        label.stringValue = entry.name
    }

    // MARK: - Right-click context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entry = entry else { return nil }
        let menu = NSMenu()

        if entry.isDirectory {
            let openItem = NSMenuItem(title: "Open", action: #selector(openFolder), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
            menu.addItem(.separator())
        }

        let qlItem = NSMenuItem(title: "Quick Look", action: #selector(quickLookFile), keyEquivalent: " ")
        qlItem.target = self
        menu.addItem(qlItem)

        let openDefaultItem = NSMenuItem(title: "Open with Default App", action: #selector(openWithDefault), keyEquivalent: "")
        openDefaultItem.target = self
        menu.addItem(openDefaultItem)

        menu.addItem(.separator())

        let renameItem = NSMenuItem(title: "Rename…", action: #selector(renameFile), keyEquivalent: "\r")
        renameItem.target = self
        menu.addItem(renameItem)

        let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(deleteFile), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = .command
        deleteItem.target = self
        menu.addItem(deleteItem)

        menu.addItem(.separator())

        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "")
        finderItem.target = self
        menu.addItem(finderItem)

        return menu
    }

    @objc private func openFolder() {
        guard let entry = entry, entry.isDirectory else { return }
        state?.navigate(to: entry.url)
    }

    @objc private func quickLookFile() {
        guard let entry = entry else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        task.arguments = ["-p", entry.url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    @objc private func openWithDefault() {
        guard let entry = entry else { return }
        NSWorkspace.shared.open(entry.url)
    }

    @objc private func renameFile() {
        guard let entry = entry, let state = state else { return }
        FileBrowserActions.rename(entry: entry, state: state)
    }

    @objc private func deleteFile() {
        guard let entry = entry, let state = state else { return }
        FileBrowserActions.delete(entry: entry, state: state)
    }

    @objc private func showInFinder() {
        guard let entry = entry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    // MARK: - Drag support

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let entry = entry else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(entry.url.absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: entry.url.path))

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
}

extension FileRowNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }
}
