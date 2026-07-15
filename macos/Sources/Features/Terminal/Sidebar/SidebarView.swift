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

/// The hint shown at the tail of the hovered row during a drag. Recent pointer
/// movement shows a direction arrow (reorder); lingering for 0.5s over a tab
/// area shows a Join badge (releasing a standalone tab there joins the group).
private enum DragHint: Equatable {
    case up
    case down
    case join
}

/// Mutable drag-session state shared by all row drop delegates. A class so the
/// per-row delegate structs (recreated on every render) mutate the same values.
private final class DragHintTracker {
    /// Pointer y in the hovered row's coordinate space at the last update.
    var lastY: CGFloat?
    /// The row the pointer most recently entered. Unlike `dropTargetID` it is
    /// not cleared by exit callbacks, so entering the next row can compute the
    /// travel direction even when exit/enter arrive out of order.
    var lastRowID: UUID?
    /// Pending work that flips the hint to .join after the linger delay.
    var joinWork: DispatchWorkItem?
    /// The ID of the row where the current drag session started (set by the
    /// drag source), letting hover logic know what is being dragged — the drop
    /// payload itself is only readable at release time.
    var draggedID: UUID?
}

/// A drop delegate for a tab row. Reports enter/move/exit to the sidebar (which
/// drives the tail hint) and, on release, reports the drop position as a
/// fraction of the row height so the sidebar can place the tab accordingly.
private struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let rowHeight: CGFloat
    let tracker: DragHintTracker
    let onEntered: (_ rowID: UUID) -> Void
    let onMoved: (_ dy: CGFloat) -> Void
    let onExited: (_ rowID: UUID) -> Void
    let perform: (_ providers: [NSItemProvider], _ fraction: CGFloat) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        tracker.lastY = info.location.y
        onEntered(targetTabID)
    }

    func dropExited(info: DropInfo) {
        onExited(targetTabID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let y = info.location.y
        if let last = tracker.lastY {
            onMoved(y - last)
        }
        tracker.lastY = y
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let fraction = rowHeight > 0 ? min(max(info.location.y / rowHeight, 0), 1) : 0.5
        return perform(info.itemProviders(for: [.plainText]), fraction)
    }
}

/// Attaches drag source, drop delegate, height measurement, and the drag hint
/// badge to a tab row.
///
/// The row height is tracked as local @State fed by a GeometryReader in the
/// row's own background: preferences don't reliably propagate out of List rows
/// on macOS (NSTableView-backed), which previously left the height at 0 and
/// made every drop classify as a join — breaking drag-to-reorder.
private struct TabDragDropModifier: ViewModifier {
    let id: UUID
    /// The hint to show at this row's tail (nil unless this row is the current
    /// drop target).
    let hint: DragHint?
    let tracker: DragHintTracker
    let onEntered: (_ rowID: UUID) -> Void
    let onMoved: (_ dy: CGFloat) -> Void
    let onExited: (_ rowID: UUID) -> Void
    let onDrop: (_ providers: [NSItemProvider], _ fraction: CGFloat) -> Bool

    @State private var rowHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Open up the vertical gap between tabs (~1.3x the default row
            // height); the padding also enlarges each drop target.
            .padding(.vertical, 3)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { rowHeight = geo.size.height }
                    .onChange(of: geo.size.height) { rowHeight = $0 }
            })
            .overlay(hintBadge, alignment: .trailing)
            .onDrag {
                // Record what is being dragged so hover logic can tell whether
                // a join is possible before the payload is readable.
                tracker.draggedID = id
                return NSItemProvider(object: id.uuidString as NSString)
            }
            .onDrop(of: [.plainText], delegate: TabDropDelegate(
                targetTabID: id,
                rowHeight: rowHeight,
                tracker: tracker,
                onEntered: onEntered,
                onMoved: onMoved,
                onExited: onExited,
                perform: onDrop
            ))
    }

    /// Small badge at the row's tail: ↑/↓ while the drag is moving (reorder),
    /// or "Join" once the pointer has lingered.
    @ViewBuilder
    private var hintBadge: some View {
        if let hint {
            HStack(spacing: 3) {
                switch hint {
                case .up:
                    Image(systemName: "arrow.up")
                case .down:
                    Image(systemName: "arrow.down")
                case .join:
                    Image(systemName: "arrow.triangle.merge")
                    Text("Join")
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
            .padding(.trailing, 4)
            .allowsHitTesting(false)
        }
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

    /// The hint currently shown at the drop target row's tail.
    @State private var dragHint: DragHint?

    /// Shared mutable drag-session state (pointer position, linger timer).
    @State private var dragTracker = DragHintTracker()

    /// Current sidebar mode — bound to the controller so the right-side view can switch.
    @Binding var sidebarMode: SidebarMode

    /// Persistent file browser state across mode switches.
    @StateObject private var fileBrowserState = FileBrowserState()

    /// Whether the "Add Remote Host" sheet is visible.
    @State private var showAddRemoteHostSheet = false

    /// AI quota accounts and their latest usage, shown above the menu.
    @ObservedObject private var quotaManager = AIQuotaManager.shared

    /// Whether the AI usage settings sheet is visible.
    @State private var showAIQuotaSettings = false

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

    /// Build a flat list of row items — children are shown unless their group
    /// is collapsed via the header's disclosure chevron.
    private var flatRows: [SidebarRowItem] {
        var rows: [SidebarRowItem] = []
        for (index, tab) in controller.tabs.enumerated() {
            if tab.isGroup {
                rows.append(.group(group: tab, index: index))
                if !tab.isCollapsed {
                    for child in tab.children {
                        rows.append(.groupChild(child: child, group: tab))
                    }
                }
            } else {
                rows.append(.tab(tab: tab, index: index))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            // Row 0: AI usage/quota stats above the menu (toggled in settings)
            if quotaManager.showInSidebar && !quotaManager.visibleAccounts.isEmpty {
                AIQuotaSectionView(manager: quotaManager) {
                    showAIQuotaSettings = true
                }
                Divider()
            }

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

            Divider()

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

                    // Entry point to AI usage settings, still reachable when
                    // the stats section itself is hidden.
                    Button(action: { showAIQuotaSettings = true }) {
                        Image(systemName: "gauge")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.borderless)
                    .help("AI usage accounts & display settings")

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
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
        .sheet(isPresented: $showAIQuotaSettings) {
            AIQuotaSettingsView(manager: quotaManager)
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

    // MARK: Drag hint tracking

    /// The pointer entered a row. Derive the travel direction from the row
    /// order in the flattened list, and restart the linger timer.
    private func dragEntered(row id: UUID) {
        if let prev = dragTracker.lastRowID, prev != id,
           let prevIndex = flatRows.firstIndex(where: { $0.id == prev }),
           let newIndex = flatRows.firstIndex(where: { $0.id == id }) {
            dragHint = newIndex > prevIndex ? .down : .up
        }
        dragTracker.lastRowID = id
        dropTargetID = id
        scheduleJoinHint()
    }

    /// The pointer moved within the current row.
    private func dragMoved(dy: CGFloat) {
        // Ignore sub-pixel jitter so a lingering pointer still reaches the
        // join hint.
        guard abs(dy) > 2 else { return }
        dragHint = dy > 0 ? .down : .up
        scheduleJoinHint()
    }

    /// The pointer left a row (and didn't enter another).
    private func dragExited(row id: UUID) {
        guard dropTargetID == id else { return }
        dropTargetID = nil
        dragHint = nil
        dragTracker.joinWork?.cancel()
    }

    /// After 0.5s without movement, show the Join badge — but only where a
    /// release would actually join (a standalone tab hovering over a tab area).
    /// Elsewhere the linger just clears the movement arrow.
    private func scheduleJoinHint() {
        dragTracker.joinWork?.cancel()
        let work = DispatchWorkItem { dragHint = joinHintApplies ? .join : nil }
        dragTracker.joinWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Whether releasing at the current drop target would join: the dragged
    /// item is a standalone top-level tab hovering over a tab area, or a group
    /// child hovering over a *different* tab area. Group drags and tab-onto-tab
    /// drops never join.
    private var joinHintApplies: Bool {
        guard let targetID = dropTargetID,
              let draggedID = dragTracker.draggedID,
              let targetGroup = groupContaining(targetID)
        else { return false }
        if let dragged = controller.tabs.first(where: { $0.id == draggedID }) {
            return !dragged.isGroup
        }
        if let sourceGroup = groupContaining(draggedID) {
            return sourceGroup.id != targetGroup.id
        }
        return false
    }

    /// Handle a drop of a dragged tab UUID onto a target row. `fraction` is the
    /// release position within the row (0 = top, 1 = bottom), used to pick the
    /// insertion point when joining into a group.
    private func handleDrop(of providers: [NSItemProvider], targetTabID: UUID, fraction: CGFloat) -> Bool {
        dropTargetID = nil
        dragHint = nil
        dragTracker.joinWork?.cancel()
        dragTracker.lastRowID = nil
        dragTracker.draggedID = nil
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
            guard let data = data as? Data, let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString) else { return }
            DispatchQueue.main.async {
                performDrop(draggedID: draggedID, targetTabID: targetTabID, fraction: fraction)
            }
        }
        return true
    }

    /// Apply a resolved drop on the main thread.
    private func performDrop(draggedID: UUID, targetTabID: UUID, fraction: CGFloat) {
        guard draggedID != targetTabID else { return }

        // 1) The dragged item is a child pane of some group.
        if let sourceGroup = controller.tabs.first(where: { tab in
            tab.isGroup && tab.children.contains { $0.id == draggedID }
        }) {
            guard let fromIndex = sourceGroup.children.firstIndex(where: { $0.id == draggedID }) else { return }

            // Dropped onto a sibling → reorder within the group.
            if let toIndex = sourceGroup.children.firstIndex(where: { $0.id == targetTabID }) {
                guard fromIndex != toIndex else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    let child = sourceGroup.children.remove(at: fromIndex)
                    sourceGroup.children.insert(child, at: toIndex)
                    // Force @Published tabs to fire so SwiftUI re-computes flatRows.
                    let snapshot = controller.tabs
                    controller.tabs = snapshot
                    controller.saveScreenSessionState()
                }
                return
            }

            // Dropped onto another tab area (its header or a child) → move the
            // pane across at the release position; refused with a "full" alert
            // if the destination already holds 4 panes.
            if let destGroup = groupContaining(targetTabID), destGroup.id != sourceGroup.id {
                let insertIndex: Int?
                if let childIndex = destGroup.children.firstIndex(where: { $0.id == targetTabID }) {
                    insertIndex = childIndex + (fraction > 0.5 ? 1 : 0)
                } else {
                    // Released on the destination's header — insert at the top.
                    insertIndex = 0
                }
                let child = sourceGroup.children[fromIndex]
                controller.moveChildTab(child, from: sourceGroup, to: destGroup, at: insertIndex)
                return
            }

            // Child dropped anywhere else (own header, standalone rows): no-op.
            return
        }

        // From here on the dragged item is a top-level entry (tab or group).
        guard let dragged = controller.tabs.first(where: { $0.id == draggedID }) else { return }

        // 2) A standalone tab dropped onto a group (its header or one of its
        //    children) → join it into that group at the release position:
        //    above/below the child under the pointer, or at the top for the
        //    header row. joinTab hard-blocks (with a "full" alert) at 4 panes.
        if !dragged.isGroup, let targetGroup = groupContaining(targetTabID) {
            let insertIndex: Int?
            if let childIndex = targetGroup.children.firstIndex(where: { $0.id == targetTabID }) {
                insertIndex = childIndex + (fraction > 0.5 ? 1 : 0)
            } else {
                // Released on the group header — insert at the top.
                insertIndex = 0
            }
            controller.joinTab(dragged, into: targetGroup, hardLimit: true, at: insertIndex)
            return
        }

        // 3) Reorder top-level entries — standalone tabs and groups alike. When
        //    the target row belongs to a group (e.g. dragging a group over
        //    another group's rows), reorder relative to that group.
        let resolvedTargetID: UUID?
        if controller.tabs.contains(where: { $0.id == targetTabID }) {
            resolvedTargetID = targetTabID
        } else {
            resolvedTargetID = groupContaining(targetTabID)?.id
        }
        guard let targetID = resolvedTargetID,
              let fromIndex = controller.tabs.firstIndex(where: { $0.id == draggedID }),
              let toIndex = controller.tabs.firstIndex(where: { $0.id == targetID }),
              fromIndex != toIndex else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            let tab = controller.tabs.remove(at: fromIndex)
            controller.tabs.insert(tab, at: toIndex)
            controller.saveScreenSessionState()
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
                        hint: dropTargetID == tab.id ? dragHint : nil,
                        tracker: dragTracker,
                        onEntered: dragEntered(row:),
                        onMoved: dragMoved(dy:),
                        onExited: dragExited(row:),
                        onDrop: { providers, fraction in handleDrop(of: providers, targetTabID: tab.id, fraction: fraction) }
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
                        hint: dropTargetID == group.id ? dragHint : nil,
                        tracker: dragTracker,
                        onEntered: dragEntered(row:),
                        onMoved: dragMoved(dy:),
                        onExited: dragExited(row:),
                        onDrop: { providers, fraction in handleDrop(of: providers, targetTabID: group.id, fraction: fraction) }
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
                        hint: dropTargetID == child.id ? dragHint : nil,
                        tracker: dragTracker,
                        onEntered: dragEntered(row:),
                        onMoved: dragMoved(dy:),
                        onExited: dragExited(row:),
                        onDrop: { providers, fraction in handleDrop(of: providers, targetTabID: child.id, fraction: fraction) }
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
            // Disclosure chevron: collapses/expands the group's child rows in
            // the sidebar (display only — panes are unaffected).
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        group.isCollapsed.toggle()
                        // Force @Published tabs to fire so SwiftUI re-computes
                        // flatRows (child property changes don't).
                        let snapshot = controller.tabs
                        controller.tabs = snapshot
                    }
                }

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
