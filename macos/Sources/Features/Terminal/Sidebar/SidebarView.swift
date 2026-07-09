import SwiftUI
import UniformTypeIdentifiers

/// Sidebar display mode.
enum SidebarMode {
    case terminal
    case fileBrowser
    case editor
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

/// Where within a target row a dragged tab was released.
private enum DropZone {
    /// Middle of the row — merge the dragged tab into the target (join).
    case join
    /// Top/bottom edge of the row — reorder relative to the target.
    case reorder
}

/// A drop delegate for a tab row. Uses `DropInfo.location` (reliably in the
/// row's own coordinate space) together with the row's measured height to
/// classify the drop as a join (middle) or a reorder (edge).
private struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let rowHeight: CGFloat
    @Binding var dropTargetID: UUID?
    let perform: (_ providers: [NSItemProvider], _ zone: DropZone) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        dropTargetID = targetTabID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetTabID { dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetID = nil
        let providers = info.itemProviders(for: [.plainText])
        // Middle 50% of the row = join; top/bottom 25% = reorder. If the height
        // isn't measured yet, default to join (dropping squarely on a row).
        let zone: DropZone
        if rowHeight > 0 {
            let y = info.location.y
            zone = (y > rowHeight * 0.25 && y < rowHeight * 0.75) ? .join : .reorder
        } else {
            zone = .join
        }
        return perform(providers, zone)
    }
}

/// Attaches drag source, drop delegate, and height measurement to a tab row.
///
/// The row height is tracked as local @State fed by a GeometryReader in the
/// row's own background: preferences don't reliably propagate out of List rows
/// on macOS (NSTableView-backed), which previously left the height at 0 and
/// made every drop classify as a join — breaking drag-to-reorder.
private struct TabDragDropModifier: ViewModifier {
    let id: UUID
    @Binding var dropTargetID: UUID?
    let onDrop: (_ providers: [NSItemProvider], _ zone: DropZone) -> Bool

    @State private var rowHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Open up the vertical gap between tabs (~1.3x the default row
            // height); the padding also enlarges each drop zone, making the
            // edge (reorder) and middle (join) bands easier to hit.
            .padding(.vertical, 3)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { rowHeight = geo.size.height }
                    .onChange(of: geo.size.height) { rowHeight = $0 }
            })
            .onDrag { NSItemProvider(object: id.uuidString as NSString) }
            .onDrop(of: [.plainText], delegate: TabDropDelegate(
                targetTabID: id,
                rowHeight: rowHeight,
                dropTargetID: $dropTargetID,
                perform: onDrop
            ))
    }
}

/// The sidebar view showing a list of tabs. Supports selection, right-click
/// context menu (close / join), drag-to-reorder / drag-to-join, and +/- buttons.
struct SidebarView: View {
    @ObservedObject var controller: SidebarTerminalController

    /// Local selection state for the List.
    @State private var selection: UUID?

    /// The tab ID currently being hovered during a drag operation.
    @State private var dropTargetID: UUID?

    /// Current sidebar mode — bound to the controller so the right-side view can switch.
    @Binding var sidebarMode: SidebarMode

    /// Persistent file browser state across mode switches.
    @StateObject private var fileBrowserState = FileBrowserState()

    /// Whether the "Add Remote Host" sheet is visible.
    @State private var showAddRemoteHostSheet = false

    /// A mapping from tab/child ID to its Cmd+Number shortcut index (1-based), using the flat activatable list.
    private var shortcutIndexMap: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (i, item) in controller.flatActivatableItems.enumerated() {
            if i < 9 {
                map[item.tab.id] = i + 1
            }
        }
        return map
    }

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
            // Row 1: Mode switcher — two buttons each 50% width
            HStack(spacing: 0) {
                Button(action: { sidebarMode = .terminal }) {
                    Image(systemName: "terminal")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(sidebarMode == .terminal ? Color.accentColor.opacity(0.25) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Button(action: { sidebarMode = .fileBrowser }) {
                    Image(systemName: "folder")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(sidebarMode == .fileBrowser ? Color.accentColor.opacity(0.25) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Button(action: { sidebarMode = .editor }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(sidebarMode == .editor ? Color.accentColor.opacity(0.25) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .padding(.top, 2)
            .padding(.bottom, 2)

            // Row 2: Action buttons (sub-menu style)
            if sidebarMode == .terminal {
                HStack(spacing: 14) {
                    Button(action: { controller.addNewTab() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 17))
                    }
                    .buttonStyle(.borderless)

                    Button(action: {
                        if let sel = selection {
                            // Check if selection is a child within a group
                            for group in controller.tabs where group.isGroup {
                                if let child = group.children.first(where: { $0.id == sel }) {
                                    controller.closeChildTab(child, from: group)
                                    return
                                }
                            }
                            // Check if the selection is a group itself — close the
                            // active/first child instead of the entire group.
                            if let tab = controller.tabs.first(where: { $0.id == sel }), tab.isGroup {
                                if let activeChild = tab.children.first(where: { $0.id == tab.fullModeActiveChildID })
                                    ?? tab.children.first {
                                    controller.closeChildTab(activeChild, from: tab)
                                } else {
                                    controller.closeTab(tab)
                                }
                                return
                            }
                            // Otherwise close the top-level standalone tab
                            if let tab = controller.tabs.first(where: { $0.id == sel }) {
                                controller.closeTab(tab)
                            }
                        }
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 17))
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.tabs.isEmpty)

                    remoteHostMenu

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
                        fileBrowserState.onEditFile = { url in
                            if TextEditorManager.shared.openDocument(url: url) {
                                sidebarMode = .editor
                            }
                        }
                    }

            case .editor:
                EditorSidebarList(state: TextEditorManager.shared.state)
            }
        }
        .frame(minWidth: 150, idealWidth: 200)
        .onChange(of: controller.selectedTabID) { _ in
            // Auto-switch sidebar to terminal tab list when tab changes (e.g. Cmd+number)
            if sidebarMode == .fileBrowser {
                sidebarMode = .terminal
            }
        }
        .sheet(isPresented: $showAddRemoteHostSheet) {
            AddRemoteHostSheet { host in
                RemoteHostManager.shared.addManualHost(host)
                controller.addRemoteTab(host: host)
            }
        }
    }

    /// Menu for connecting to a remote host: lists ~/.ssh/config aliases and
    /// manually saved hosts, plus an entry to add a new host.
    private var remoteHostMenu: some View {
        Menu {
            let configHosts = RemoteHostManager.shared.sshConfigHosts()
            let manualHosts = RemoteHostManager.shared.manualHosts()

            if configHosts.isEmpty && manualHosts.isEmpty {
                Text("No saved hosts")
            }

            ForEach(configHosts) { host in
                Button {
                    controller.addRemoteTab(host: host)
                } label: {
                    Label(host.name, systemImage: "doc.text")
                }
            }

            if !configHosts.isEmpty && !manualHosts.isEmpty {
                Divider()
            }

            ForEach(manualHosts) { host in
                Button {
                    controller.addRemoteTab(host: host)
                } label: {
                    Label(host.name, systemImage: "network")
                }
            }

            Divider()

            Button("Add Remote Host…") {
                showAddRemoteHostSheet = true
            }

            if !manualHosts.isEmpty {
                Menu("Remove Saved Host") {
                    ForEach(manualHosts) { host in
                        Button(host.name) {
                            RemoteHostManager.shared.removeManualHost(host)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "network")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Connect to a remote host (SSH + tmux)")
    }

    /// Visual indicator shown on the drop target row.
    @ViewBuilder
    private func dropIndicator(for tabID: UUID) -> some View {
        if dropTargetID == tabID {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(.horizontal, 2)
        }
    }

    /// If `id` is a group header, or one of a group's children, return that group.
    private func groupContaining(_ id: UUID) -> SidebarTabEntry? {
        for tab in controller.tabs where tab.isGroup {
            if tab.id == id { return tab }
            if tab.children.contains(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    /// Handle a drop of a dragged tab UUID onto a target row. `zone` classifies
    /// where in the target row the drop landed (join = middle, reorder = edge).
    private func handleDrop(of providers: [NSItemProvider], targetTabID: UUID, zone: DropZone) -> Bool {
        dropTargetID = nil
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
            guard let data = data as? Data, let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString) else { return }
            DispatchQueue.main.async {
                performDrop(draggedID: draggedID, targetTabID: targetTabID, zone: zone)
            }
        }
        return true
    }

    /// Apply a resolved drop on the main thread.
    private func performDrop(draggedID: UUID, targetTabID: UUID, zone: DropZone) {
        guard draggedID != targetTabID else { return }

        // 1) Reorder within a group: both dragged and target are children of the
        //    same group. Cross-group child moves are not supported here.
        for group in controller.tabs where group.isGroup {
            guard let fromIndex = group.children.firstIndex(where: { $0.id == draggedID }) else { continue }
            guard let toIndex = group.children.firstIndex(where: { $0.id == targetTabID }),
                  fromIndex != toIndex else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                let child = group.children.remove(at: fromIndex)
                group.children.insert(child, at: toIndex)
                // Force @Published tabs to fire so SwiftUI re-computes flatRows.
                let snapshot = controller.tabs
                controller.tabs = snapshot
                controller.saveScreenSessionState()
            }
            return
        }

        // From here on the dragged item must be a standalone top-level tab.
        guard let dragged = controller.tabs.first(where: { $0.id == draggedID }), !dragged.isGroup else { return }

        // 2) Dropped onto a group (its header or one of its children) → join the
        //    dragged tab into that group. joinTab hard-blocks (with a "full"
        //    alert) if the group already holds 4 panes.
        if let targetGroup = groupContaining(targetTabID) {
            controller.joinTab(dragged, into: targetGroup, hardLimit: true)
            return
        }

        // 3) Dropped onto another standalone top-level tab.
        guard let target = controller.tabs.first(where: { $0.id == targetTabID }), !target.isGroup else { return }
        switch zone {
        case .join:
            // Ask before merging two standalone tabs into a new group.
            controller.confirmJoinTabs(dragged, into: target)
        case .reorder:
            guard let fromIndex = controller.tabs.firstIndex(where: { $0.id == draggedID }),
                  let toIndex = controller.tabs.firstIndex(where: { $0.id == targetTabID }),
                  fromIndex != toIndex else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                let tab = controller.tabs.remove(at: fromIndex)
                controller.tabs.insert(tab, at: toIndex)
                controller.saveScreenSessionState()
            }
        }
    }

    /// The terminal tab list view.
    private var terminalTabList: some View {
        let shortcuts = shortcutIndexMap
        return List(selection: $selection) {
            ForEach(flatRows) { item in
                switch item {
                case .tab(let tab, _):
                    SidebarStandaloneTabRow(
                        tab: tab,
                        shortcutIndex: shortcuts[tab.id],
                        controller: controller,
                        selection: $selection
                    )
                    .tag(tab.id)
                    .overlay(dropIndicator(for: tab.id))
                    .modifier(TabDragDropModifier(
                        id: tab.id,
                        dropTargetID: $dropTargetID,
                        onDrop: { providers, zone in handleDrop(of: providers, targetTabID: tab.id, zone: zone) }
                    ))

                case .group(let group, _):
                    SidebarGroupHeaderRow(
                        group: group,
                        controller: controller,
                        selection: $selection
                    )
                    .tag(group.id)
                    .overlay(dropIndicator(for: group.id))
                    .modifier(TabDragDropModifier(
                        id: group.id,
                        dropTargetID: $dropTargetID,
                        onDrop: { providers, zone in handleDrop(of: providers, targetTabID: group.id, zone: zone) }
                    ))

                case .groupChild(let child, let group):
                    SidebarGroupChildRow(
                        child: child,
                        group: group,
                        shortcutIndex: shortcuts[child.id],
                        controller: controller,
                        selection: $selection
                    )
                    .tag(child.id)
                    .overlay(dropIndicator(for: child.id))
                    .modifier(TabDragDropModifier(
                        id: child.id,
                        dropTargetID: $dropTargetID,
                        onDrop: { providers, zone in handleDrop(of: providers, targetTabID: child.id, zone: zone) }
                    ))
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            selection = controller.highlightedItemID ?? controller.selectedTabID
        }
        .onChange(of: selection) { newValue in
            guard let newValue else { return }
            // Update the controller's highlight to match user click
            controller.highlightedItemID = newValue

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
                    if group.isFullMode {
                        controller.switchFullModeChild(to: child, in: group)
                    } else if let surface = child.focusedSurface ?? child.originalSurface {
                        DispatchQueue.main.async {
                            Ghostty.moveFocus(to: surface)
                        }
                    }
                    return
                }
            }
        }
        .onChange(of: controller.highlightedItemID) { newValue in
            if selection != newValue {
                selection = newValue
            }
        }
    }

}

// MARK: - Tab rename helper

private enum TabRenameHelper {
    /// Prompt for a custom tab name. The custom name overrides the
    /// terminal-derived title until reset.
    static func rename(_ tab: SidebarTabEntry, controller: SidebarTerminalController) {
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = tab.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            tab.customTitle = newName
            afterChange(tab, controller: controller)
        }
    }

    /// Remove the custom name so the tab tracks the terminal title again.
    static func resetName(_ tab: SidebarTabEntry, controller: SidebarTerminalController) {
        tab.customTitle = nil
        afterChange(tab, controller: controller)
    }

    private static func afterChange(_ tab: SidebarTabEntry, controller: SidebarTerminalController) {
        if controller.selectedTabID == tab.id {
            controller.window?.title = tab.displayTitle
        }
        controller.saveScreenSessionState()
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
            if tab.isRemote {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundColor(.cyan)
                    .help("Remote: \(tab.remoteTarget ?? "")")
            }

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
            Button("Rename Tab…") {
                TabRenameHelper.rename(tab, controller: controller)
            }
            if tab.customTitle != nil {
                Button("Reset Name") {
                    TabRenameHelper.resetName(tab, controller: controller)
                }
            }

            Divider()

            // Join into another tab or group. Targets that already have 4
            // panes are allowed; joinTab asks for confirmation in that case.
            let joinableTargets = controller.tabs.filter {
                $0.id != tab.id
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
            Image(systemName: group.isFullMode ? "rectangle.stack" : "rectangle.split.2x1")
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

            if group.isFullMode {
                Button("All Unfull") {
                    controller.exitFullMode(for: group)
                }
            } else {
                Button("All Full") {
                    controller.enterFullMode(for: group)
                }
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
    @ObservedObject var group: SidebarTabEntry
    let shortcutIndex: Int?
    let controller: SidebarTerminalController
    @Binding var selection: UUID?

    @State private var isHovering = false

    /// Whether this child is currently the active/focused one.
    private var isActiveChild: Bool {
        controller.highlightedItemID == child.id
    }

    var body: some View {
        HStack(spacing: 4) {
            // Indent with tree connector
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1, height: 16)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 8, height: 1)

            Image(systemName: child.isRemote ? "antenna.radiowaves.left.and.right" : "terminal")
                .font(.caption2)
                .foregroundColor(isActiveChild ? .accentColor : (child.isRemote ? .cyan : .secondary))

            Text(child.displayTitle)
                .font(.callout)
                .fontWeight(isActiveChild ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isActiveChild {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.accentColor)
            }

            if child.bell {
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
                Button(action: { controller.closeChildTab(child, from: group) }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = child.id
            if group.id != controller.selectedTabID {
                controller.selectTab(group)
            }
            if group.isFullMode {
                controller.switchFullModeChild(to: child, in: group)
            } else if let surface = child.originalSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename Tab…") {
                TabRenameHelper.rename(child, controller: controller)
            }
            if child.customTitle != nil {
                Button("Reset Name") {
                    TabRenameHelper.resetName(child, controller: controller)
                }
            }

            Divider()

            Button("Unjoin") {
                controller.unjoinTab(child, from: group)
            }

            Divider()

            Button("Close Tab") {
                controller.closeChildTab(child, from: group)
            }
        }
    }
}

// MARK: - Add Remote Host Sheet

/// Form for adding a remote SSH host manually (IP or hostname).
/// The host is saved and a remote tab is opened immediately.
private struct AddRemoteHostSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the new host when the user confirms.
    let onConnect: (RemoteHost) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Remote Host")
                .font(.headline)

            Form {
                TextField("Host / IP:", text: $host, prompt: Text("192.168.1.10 or my-server"))
                TextField("User:", text: $user, prompt: Text("optional"))
                TextField("Port:", text: $port, prompt: Text("22"))
                TextField("Identity file:", text: $identityFile, prompt: Text("~/.ssh/id_rsa (optional)"))
                TextField("Display name:", text: $name, prompt: Text("optional"))
            }

            Text("The remote shell runs inside tmux on the host, so the session survives disconnects and reconnects automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save & Connect") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let remoteHost = RemoteHost(
                        name: trimmedName.isEmpty ? trimmedHost : trimmedName,
                        host: trimmedHost,
                        user: user.trimmingCharacters(in: .whitespaces),
                        port: Int(port.trimmingCharacters(in: .whitespaces)),
                        identityFile: identityFile.trimmingCharacters(in: .whitespaces)
                    )
                    onConnect(remoteHost)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedHost.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
