import SwiftUI

/// Sidebar display mode.
enum SidebarMode {
    case terminal
    case fileBrowser
}

/// A flattened row item for stable List identity.
private enum SidebarRowItem: Identifiable {
    /// A standalone tab (not in a group).
    case tab(tab: SidebarTabEntry, index: Int)
    /// A group header row (Tab Area).
    case group(group: SidebarTabEntry, index: Int)
    /// A child tab within a group (split pane).
    case groupChild(child: SidebarTabEntry, group: SidebarTabEntry)

    var id: UUID {
        switch self {
        case .tab(let tab, _): return tab.id
        case .group(let group, _): return group.id
        case .groupChild(let child, _): return child.id
        }
    }
}

/// The sidebar view showing a list of tabs. Supports selection, right-click
/// context menu (close / join), drag-to-reorder, and +/- buttons.
struct SidebarView: View {
    @ObservedObject var controller: SidebarTerminalController

    /// Local selection state for the List.
    @State private var selection: UUID?

    /// Current sidebar mode.
    @State private var sidebarMode: SidebarMode = .terminal

    /// Persistent file browser state across mode switches.
    @StateObject private var fileBrowserState = FileBrowserState()

    /// Build a flat list of row items — children are always shown.
    private var flatRows: [SidebarRowItem] {
        var rows: [SidebarRowItem] = []
        for (index, tab) in controller.tabs.enumerated() {
            if tab.isGroup {
                rows.append(.group(group: tab, index: index))
                for child in tab.children {
                    rows.append(.groupChild(child: child, group: tab))
                }
            } else {
                rows.append(.tab(tab: tab, index: index))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Mode switcher
            Picker("", selection: $sidebarMode) {
                Image(systemName: "terminal").tag(SidebarMode.terminal)
                Image(systemName: "folder").tag(SidebarMode.fileBrowser)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Row 2: Action buttons (sub-menu style)
            if sidebarMode == .terminal {
                HStack(spacing: 14) {
                    Button(action: { controller.addNewTab() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 17))
                    }
                    .buttonStyle(.borderless)

                    Button(action: {
                        if let selectedID = controller.selectedTabID,
                           let tab = controller.tabs.first(where: { $0.id == selectedID }) {
                            controller.closeTab(tab)
                        }
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 17))
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.tabs.isEmpty)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            Divider()

            // Content based on mode
            switch sidebarMode {
            case .terminal:
                terminalTabList

            case .fileBrowser:
                FileBrowserView(state: fileBrowserState)
                    .onAppear {
                        fileBrowserState.onSendText = { [weak controller] text in
                            guard let surface = controller?.focusedSurface else { return }
                            surface.surfaceModel?.sendText(text)
                        }
                        fileBrowserState.onOpenInNewTab = { [weak controller] path in
                            var config = Ghostty.SurfaceConfiguration()
                            config.workingDirectory = path
                            controller?.addNewTab(baseConfig: config)
                        }
                        fileBrowserState.onRefocusTerminal = { [weak controller] in
                            guard let surface = controller?.focusedSurface else { return }
                            DispatchQueue.main.async {
                                Ghostty.moveFocus(to: surface)
                            }
                        }
                    }
            }
        }
        .frame(minWidth: 150, idealWidth: 200)
        .onChange(of: controller.selectedTabID) { _ in
            // Auto-switch sidebar to terminal tab list when tab changes (e.g. Cmd+number)
            if sidebarMode != .terminal {
                sidebarMode = .terminal
            }
        }
    }

    /// The terminal tab list view.
    private var terminalTabList: some View {
        List(selection: $selection) {
            ForEach(flatRows) { item in
                switch item {
                case .tab(let tab, let index):
                    SidebarStandaloneTabRow(
                        tab: tab,
                        shortcutIndex: index < 9 ? index + 1 : nil,
                        controller: controller,
                        selection: $selection
                    )
                    .tag(tab.id)

                case .group(let group, _):
                    SidebarGroupHeaderRow(
                        group: group,
                        controller: controller,
                        selection: $selection
                    )
                    .tag(group.id)

                case .groupChild(let child, let group):
                    SidebarGroupChildRow(
                        child: child,
                        group: group,
                        controller: controller,
                        selection: $selection
                    )
                    .tag(child.id)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            selection = controller.selectedTabID
        }
        .onChange(of: selection) { newValue in
            guard let newValue else { return }
            // Check if it's a top-level tab or group
            if let tab = controller.tabs.first(where: { $0.id == newValue }) {
                if tab.isGroup {
                    // Group selected — activate it and focus the first child's surface
                    if tab.id != controller.selectedTabID {
                        controller.selectTab(tab)
                    }
                    if let surface = tab.children.first?.focusedSurface ?? tab.children.first?.originalSurface {
                        DispatchQueue.main.async {
                            Ghostty.moveFocus(to: surface)
                        }
                    }
                } else if tab.id == controller.selectedTabID {
                    if let surface = tab.originalSurface {
                        DispatchQueue.main.async {
                            Ghostty.moveFocus(to: surface)
                        }
                    }
                } else {
                    controller.selectTab(tab)
                }
                return
            }
            // Check if it's a child tab within a group
            for group in controller.tabs where group.isGroup {
                if let child = group.children.first(where: { $0.id == newValue }) {
                    if group.id != controller.selectedTabID {
                        controller.selectTab(group)
                    }
                    if let surface = child.focusedSurface ?? child.originalSurface {
                        DispatchQueue.main.async {
                            Ghostty.moveFocus(to: surface)
                        }
                    }
                    return
                }
            }
        }
        .onChange(of: controller.selectedTabID) { newValue in
            if selection != newValue {
                selection = newValue
            }
        }
    }
}

// MARK: - Standalone tab row (not in a group)

private struct SidebarStandaloneTabRow: View {
    @ObservedObject var tab: SidebarTabEntry
    let shortcutIndex: Int?
    let controller: SidebarTerminalController
    @Binding var selection: UUID?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.displayTitle)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if tab.bell {
                Image(systemName: "bell.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }

            if let shortcutIndex {
                Text("\u{2318}\(shortcutIndex)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if isHovering {
                Button(action: { controller.closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selection = tab.id
            controller.selectTab(tab)
            if let surface = tab.originalSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            // Join into another tab or group (max 4 panes)
            let joinableTargets = controller.tabs.filter {
                $0.id != tab.id && ($0.surfaceTree.root?.leaves().count ?? 0) < 4
            }
            if !joinableTargets.isEmpty {
                Menu("Join to…") {
                    ForEach(joinableTargets) { target in
                        Button(target.displayTitle) {
                            controller.joinTab(tab, into: target)
                        }
                    }
                }
            }

            Divider()
            Button("Close Tab") {
                controller.closeTab(tab)
            }
        }
    }
}

// MARK: - Group header row (Tab Area)

private struct SidebarGroupHeaderRow: View {
    @ObservedObject var group: SidebarTabEntry
    let controller: SidebarTerminalController
    @Binding var selection: UUID?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.split.2x1")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(group.displayTitle)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovering {
                Button(action: { closeGroup() }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selection = group.id
            controller.selectTab(group)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…") {
                renameGroup()
            }

            Divider()

            Button("Close Tab Area") {
                closeGroup()
            }
        }
    }

    private func renameGroup() {
        let alert = NSAlert()
        alert.messageText = "Rename Tab Area"
        alert.informativeText = "Enter a new name:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = group.groupName ?? "New Tab Area"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                group.groupName = newName
            }
        }
    }

    private func closeGroup() {
        // Close all children then the group
        controller.closeTab(group)
    }
}

// MARK: - Group child row (split pane within a group)

private struct SidebarGroupChildRow: View {
    @ObservedObject var child: SidebarTabEntry
    let group: SidebarTabEntry
    let controller: SidebarTerminalController
    @Binding var selection: UUID?

    var body: some View {
        HStack(spacing: 4) {
            // Indent with tree connector
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1, height: 16)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 8, height: 1)

            Image(systemName: "terminal")
                .font(.caption2)
                .foregroundColor(.secondary)

            Text(child.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if child.bell {
                Image(systemName: "bell.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }
        }
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = child.id
            if group.id != controller.selectedTabID {
                controller.selectTab(group)
            }
            if let surface = child.originalSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        }
        .contextMenu {
            Button("Unjoin") {
                controller.unjoinTab(child, from: group)
            }
        }
    }
}
