import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A terminal controller that uses a left sidebar for tab management instead of
/// macOS native window tabs. Each "tab" is a SidebarTabEntry holding its own
/// surface tree; only the selected tab's tree is active in the controller's
/// `surfaceTree` property.
class SidebarTerminalController: BaseTerminalController {
    /// Strong references to all live sidebar controllers. NSWindow.windowController is
    /// weak/unowned, so without this the controller would be deallocated immediately.
    private static var allControllers: Set<SidebarTerminalController> = []

    /// All tabs managed by this controller.
    @Published var tabs: [SidebarTabEntry] = []

    /// The ID of the currently selected tab (top-level tab or group).
    @Published var selectedTabID: UUID?

    /// The ID of the item that should be highlighted in the sidebar.
    /// For standalone tabs this equals selectedTabID; for group children
    /// it tracks which child is focused.
    @Published var highlightedItemID: UUID?

    /// Shared UI state for sidebar mode switching.
    let sidebarUIState = SidebarUIState()

    /// Derived config for window-level settings.
    private var derivedConfig: DerivedConfig

    /// Set to true during window close to prevent surfaceTreeDidChange from
    /// overwriting the saved session state.
    private var isClosing = false

    /// Set to true while closeChildTab is modifying the tree, to prevent
    /// surfaceTreeDidChange from double-processing the removal.
    private var isModifyingChildren = false

    // MARK: - Init

    init(_ ghostty: Ghostty.App, withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        self.derivedConfig = DerivedConfig(ghostty.config)

        // If screen is available and no custom command, wrap in screen
        let mgr = ScreenSessionManager.shared
        var config = base
        var initialScreenName: String? = nil
        if mgr.isAvailable && (base == nil || base?.command == nil) {
            var c = base ?? Ghostty.SurfaceConfiguration()
            let tabID = UUID()
            let name = mgr.sessionName(for: tabID)
            c.command = mgr.createCommand(sessionName: name, workingDirectory: c.workingDirectory)
            config = c
            initialScreenName = name
        }

        super.init(ghostty, baseConfig: config)

        // Wrap the initial surface tree (created by super) into the first tab entry.
        let firstTab = SidebarTabEntry(surfaceTree: surfaceTree, focusedSurface: focusedSurface)
        firstTab.screenSessionName = initialScreenName
        tabs.append(firstTab)
        selectedTabID = firstTab.id

        // Notifications
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Self.allControllers.remove(self)
    }

    // MARK: - Hashable (for Set storage)

    override var hash: Int { ObjectIdentifier(self).hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SidebarTerminalController else { return false }
        return self === other
    }

    // MARK: - Window Lifecycle

    /// Set up the window programmatically (no nib).
    private func setupWindow() {
        let window = SidebarTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.sidebarController = self
        window.title = "Ghostty"
        window.tabbingMode = .disallowed
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Build the content: sidebar on the left, terminal or editor on the right.
        window.contentView = TerminalViewContainer {
            SidebarRootView(controller: self, uiState: self.sidebarUIState)
        }

        window.center()
        self.window = window
    }

    /// Switch to a tab by its 1-based flat index (Cmd+1 → index 1, etc.).
    func switchToFlatIndex(_ index: Int) {
        let flatItems = flatActivatableItems
        guard !flatItems.isEmpty else { return }
        let finalIndex = min(index - 1, flatItems.count - 1)
        guard finalIndex >= 0 else { return }
        let item = flatItems[finalIndex]

        if let group = item.group {
            if group.id != selectedTabID {
                selectTab(group)
            }
            highlightedItemID = item.tab.id
            if group.isFullMode {
                switchFullModeChild(to: item.tab, in: group)
            } else if let surface = item.tab.focusedSurface ?? item.tab.originalSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        } else {
            selectTab(item.tab)
        }
    }

    override func windowWillClose(_ notification: Notification) {
        isClosing = true
        saveScreenSessionState()
        super.windowWillClose(notification)
        Self.allControllers.remove(self)
    }

    // MARK: - Tab Management

    /// Select a tab by switching the active surface tree.
    func selectTab(_ tab: SidebarTabEntry) {
        guard tab.id != selectedTabID else { return }

        // Prevent surfaceTreeDidChange from misinterpreting the tree swap
        isModifyingChildren = true
        defer { isModifyingChildren = false }

        // Save current state to the old tab
        if let oldTab = currentTab {
            oldTab.surfaceTree = surfaceTree
            oldTab.updateFocusedSurface(focusedSurface)
        }

        // Load new tab's state
        selectedTabID = tab.id
        highlightedItemID = tab.id
        surfaceTree = tab.surfaceTree

        // Update window title to current tab
        window?.title = tab.displayTitle

        // Restore focus
        if let savedFocus = tab.focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: savedFocus)
            }
        }
    }

    /// Add a new tab with a fresh terminal surface.
    /// If screen is available and no custom command is set, wraps the shell in a screen session.
    func addNewTab(baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        guard let ghostty_app = ghostty.app else { return }

        var config = baseConfig ?? Ghostty.SurfaceConfiguration()

        // Inherit working directory from the current tab if not explicitly set
        if config.workingDirectory == nil {
            if let pwd = focusedSurface?.pwd {
                config.workingDirectory = pwd
            } else if let tab = currentTab, let screenName = tab.screenSessionName {
                // Screen eats OSC 7 so pwd may be nil. Query the shell process directly.
                config.workingDirectory = ScreenSessionManager.shared.getSessionWorkingDirectory(sessionName: screenName)
            }
        }

        let mgr = ScreenSessionManager.shared
        var screenName: String? = nil

        // Wrap in screen if available and no custom command specified
        if mgr.isAvailable && config.command == nil {
            let tabID = UUID()
            let name = mgr.sessionName(for: tabID)
            config.command = mgr.createCommand(sessionName: name, workingDirectory: config.workingDirectory)
            screenName = name
        }

        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        let newTree = SplitTree<Ghostty.SurfaceView>(view: newSurface)
        let newTab = SidebarTabEntry(surfaceTree: newTree, focusedSurface: newSurface)
        newTab.screenSessionName = screenName

        tabs.append(newTab)
        // Don't set selectedTabID here — selectTab() handles it.
        selectTab(newTab)
        saveScreenSessionState()
    }

    /// Add a restored tab that reattaches to an existing screen session.
    func addRestoredTab(screenName: String, title: String, workingDirectory: String?) {
        guard let ghostty_app = ghostty.app else { return }

        let mgr = ScreenSessionManager.shared
        var config = Ghostty.SurfaceConfiguration()
        config.command = mgr.reattachCommand(sessionName: screenName)
        if let wd = workingDirectory {
            config.workingDirectory = wd
        }

        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        let newTree = SplitTree<Ghostty.SurfaceView>(view: newSurface)
        let newTab = SidebarTabEntry(surfaceTree: newTree, focusedSurface: newSurface)
        newTab.screenSessionName = screenName
        newTab.defaultTitle = title

        tabs.append(newTab)
        selectTab(newTab)
    }

    /// Close a specific tab.
    func closeTab(_ tab: SidebarTabEntry) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        // Check if any surface in this tab needs confirmation
        let needsConfirm = tab.surfaceTree.root?.needsConfirmQuit ?? false

        if needsConfirm {
            confirmClose(
                messageText: "Close Tab?",
                informativeText: "The tab still has a running process. If you close the tab the process will be killed."
            ) { [weak self] in
                self?.closeTabImmediately(tab, at: index)
            }
        } else {
            closeTabImmediately(tab, at: index)
        }
    }

    private func closeTabImmediately(_ tab: SidebarTabEntry, at index: Int) {
        // Kill screen sessions for this tab and its children
        let mgr = ScreenSessionManager.shared
        if let name = tab.screenSessionName {
            mgr.killSession(name: name)
        }
        for child in tab.children {
            if let name = child.screenSessionName {
                mgr.killSession(name: name)
            }
        }

        let wasSelected = (tab.id == selectedTabID)
        tabs.remove(at: index)

        if tabs.isEmpty {
            // No more tabs — close the window.
            saveScreenSessionState()
            window?.close()
            return
        }

        if wasSelected {
            // Switch to an adjacent tab.
            let newIndex = min(index, tabs.count - 1)
            let newTab = tabs[newIndex]
            selectTab(newTab)
        }

        saveScreenSessionState()
    }

    /// Join `source` tab into `target` tab with smart layout:
    /// - 1→2 panes: left-right split
    /// - 2→3 panes: top row (2) + bottom row (1)
    /// - 3→4 panes: 2x2 grid
    /// - 4+ panes: not allowed
    ///
    /// If target is already a group, source is added to it.
    /// If target is a standalone tab, a new group ("New Tab Area") is created
    /// containing both target and source as split pane children.
    func joinTab(_ source: SidebarTabEntry, into target: SidebarTabEntry) {
        guard source.id != target.id else { return }
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == source.id }) else { return }
        guard let targetIndex = tabs.firstIndex(where: { $0.id == target.id }) else { return }

        // Get the surface from the source tab's tree
        guard let sourceRoot = source.surfaceTree.root else { return }
        let sourceSurface = sourceRoot.leftmostLeaf()

        // Determine the actual group to insert into
        let group: SidebarTabEntry
        let isNewGroup: Bool

        if target.isGroup {
            // Target is already a group — add source into it
            group = target
            isNewGroup = false
        } else {
            // Target is a standalone tab — create a new group
            isNewGroup = true
            group = SidebarTabEntry(
                groupName: "New Tab Area",
                surfaceTree: target.surfaceTree,
                children: [target]
            )
        }

        // Determine current tree to work with
        // If group is in full mode, operate on the savedSplitTree (the actual layout)
        let currentTree: SplitTree<Ghostty.SurfaceView>
        if group.isFullMode, let saved = group.savedSplitTree {
            currentTree = saved
        } else if target.id == selectedTabID || group.id == selectedTabID {
            currentTree = surfaceTree
        } else {
            currentTree = group.surfaceTree
        }
        let leafCount = currentTree.root?.leaves().count ?? 0

        // Max 4 panes per tab area
        guard leafCount < 4 else { return }

        // Determine insertion point and direction based on current leaf count
        let insertionSurface: Ghostty.SurfaceView
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection

        switch leafCount {
        case 1:
            guard let leaf = currentTree.root?.leftmostLeaf() else { return }
            insertionSurface = leaf
            direction = .right

        case 2:
            guard let root = currentTree.root else { return }
            insertionSurface = root.rightmostLeaf()
            direction = .down

        case 3:
            guard let leaf = currentTree.root?.leftmostLeaf() else { return }
            insertionSurface = leaf
            direction = .down

        default:
            return
        }

        // Perform the insertion into the group's tree
        let isActive = (target.id == selectedTabID) || (group.id == selectedTabID)

        if group.isFullMode {
            // In full mode, insert into the savedSplitTree (the real layout)
            guard let saved = group.savedSplitTree else { return }
            do {
                let newTree = try saved.inserting(
                    view: sourceSurface,
                    at: insertionSurface,
                    direction: direction
                )
                group.savedSplitTree = newTree
            } catch {
                return
            }
        } else if isActive {
            do {
                let newTree = try surfaceTree.inserting(
                    view: sourceSurface,
                    at: insertionSurface,
                    direction: direction
                )
                surfaceTree = newTree
                group.surfaceTree = newTree
            } catch {
                return
            }
        } else {
            do {
                let newTree = try group.surfaceTree.inserting(
                    view: sourceSurface,
                    at: insertionSurface,
                    direction: direction
                )
                group.surfaceTree = newTree
            } catch {
                return
            }
        }

        // Add source as a child of the group
        group.children.append(source)

        // Remove source from top-level tabs
        // Re-fetch source index since it may have shifted
        if let idx = tabs.firstIndex(where: { $0.id == source.id }) {
            tabs.remove(at: idx)
        }

        if isNewGroup {
            // Replace target with the new group in the tabs array
            if let idx = tabs.firstIndex(where: { $0.id == target.id }) {
                tabs[idx] = group
            }
            // If target was selected, switch selection to the group
            if selectedTabID == target.id {
                selectedTabID = group.id
            }
        }

        // If the source was selected, switch to the group
        if selectedTabID == source.id {
            selectTab(group)
        }

        saveScreenSessionState()
    }

    /// Unjoin a child tab from its group, restoring it as an independent top-level tab.
    /// If the group is left with only one child, the group dissolves and that child
    /// becomes a standalone top-level tab.
    func unjoinTab(_ child: SidebarTabEntry, from group: SidebarTabEntry) {
        // Find and remove the child's surface from the group's tree
        guard let childSurface = child.originalSurface else { return }
        let leafNode = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: childSurface)

        if group.isFullMode {
            // In full mode, remove from savedSplitTree
            if let saved = group.savedSplitTree {
                group.savedSplitTree = saved.removing(leafNode)
            }

            // If the active child is being removed, switch to another child
            if group.fullModeActiveChildID == child.id {
                let remaining = group.children.filter { $0.id != child.id }
                if let next = remaining.first {
                    group.fullModeActiveChildID = next.id
                    if let surface = next.originalSurface {
                        let singleTree = SplitTree<Ghostty.SurfaceView>(view: surface)
                        if group.id == selectedTabID {
                            surfaceTree = singleTree
                            group.surfaceTree = singleTree
                            DispatchQueue.main.async {
                                Ghostty.moveFocus(to: surface)
                            }
                        } else {
                            group.surfaceTree = singleTree
                        }
                    }
                }
            }
        } else {
            if group.id == selectedTabID {
                let newTree = surfaceTree.removing(leafNode)
                surfaceTree = newTree
                group.surfaceTree = newTree
            } else {
                let newTree = group.surfaceTree.removing(leafNode)
                group.surfaceTree = newTree
            }
        }

        // Remove from group's children
        group.children.removeAll { $0.id == child.id }

        // Restore child as an independent tab with its own tree
        let newTree = SplitTree<Ghostty.SurfaceView>(view: childSurface)
        child.surfaceTree = newTree
        child.focusedSurface = childSurface

        // Insert child right after the group
        if let groupIndex = tabs.firstIndex(where: { $0.id == group.id }) {
            tabs.insert(child, at: groupIndex + 1)
        } else {
            tabs.append(child)
        }

        // Exit full mode if only 1 child remains
        if group.isGroup && group.children.count == 1 && group.isFullMode {
            group.isFullMode = false
            group.savedSplitTree = nil
            group.fullModeActiveChildID = nil
        }

        saveScreenSessionState()
    }

    /// Close a single child tab within a group, removing its surface from the
    /// group's split tree and killing its screen session. If the group is left
    /// with only one child, the group dissolves into a standalone tab.
    func closeChildTab(_ child: SidebarTabEntry, from group: SidebarTabEntry) {
        guard let childSurface = child.originalSurface else { return }
        let leafNode = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: childSurface)

        // Prevent surfaceTreeDidChange from double-processing
        isModifyingChildren = true
        defer { isModifyingChildren = false }

        // Remove the child's surface from the group's tree
        if group.isFullMode {
            if let saved = group.savedSplitTree {
                group.savedSplitTree = saved.removing(leafNode)
            }
            if group.fullModeActiveChildID == child.id {
                let remaining = group.children.filter { $0.id != child.id }
                if let next = remaining.first {
                    group.fullModeActiveChildID = next.id
                    if let surface = next.originalSurface {
                        let singleTree = SplitTree<Ghostty.SurfaceView>(view: surface)
                        if group.id == selectedTabID {
                            surfaceTree = singleTree
                            group.surfaceTree = singleTree
                            DispatchQueue.main.async {
                                Ghostty.moveFocus(to: surface)
                            }
                        } else {
                            group.surfaceTree = singleTree
                        }
                    }
                }
            }
        } else {
            if group.id == selectedTabID {
                let newTree = surfaceTree.removing(leafNode)
                surfaceTree = newTree
                group.surfaceTree = newTree
            } else {
                let newTree = group.surfaceTree.removing(leafNode)
                group.surfaceTree = newTree
            }
        }

        // Remove from group's children
        group.children.removeAll { $0.id == child.id }

        // Force @Published tabs to fire so SwiftUI re-computes flatRows.
        let snapshot = tabs
        tabs = snapshot

        // Kill the child's screen session
        if let name = child.screenSessionName {
            ScreenSessionManager.shared.killSession(name: name)
        }

        // If no children left, close the group entirely
        if group.children.isEmpty {
            if let index = tabs.firstIndex(where: { $0.id == group.id }) {
                tabs.remove(at: index)
                if tabs.isEmpty {
                    saveScreenSessionState()
                    window?.close()
                    return
                }
                if group.id == selectedTabID {
                    let newIndex = min(index, tabs.count - 1)
                    selectTab(tabs[newIndex])
                }
            }
        } else if group.isFullMode, group.children.count == 1 {
            // Exit full mode when only 1 child remains (no need to switch)
            group.isFullMode = false
            group.savedSplitTree = nil
            group.fullModeActiveChildID = nil
        }

        saveScreenSessionState()
    }

    /// Dissolve a group with a single remaining child, promoting that child
    /// back to a standalone top-level tab.
    private func dissolveGroup(_ group: SidebarTabEntry) {
        guard let remaining = group.children.first else { return }
        guard let groupIndex = tabs.firstIndex(where: { $0.id == group.id }) else { return }

        // Restore the remaining child's own surface tree
        if let surface = remaining.originalSurface {
            remaining.surfaceTree = SplitTree<Ghostty.SurfaceView>(view: surface)
            remaining.focusedSurface = surface
        } else {
            remaining.surfaceTree = group.surfaceTree
        }

        // Replace group with the remaining child
        tabs[groupIndex] = remaining

        // If the group was selected, switch to the remaining child
        if selectedTabID == group.id {
            selectedTabID = remaining.id
            surfaceTree = remaining.surfaceTree
            if let surface = remaining.focusedSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        }
    }

    /// The currently selected tab entry.
    private var currentTab: SidebarTabEntry? {
        tabs.first(where: { $0.id == selectedTabID })
    }

    // MARK: - Full Mode (Group)

    /// Enter full mode for a group: save the current split tree and show only one child.
    func enterFullMode(for group: SidebarTabEntry) {
        guard group.isGroup, !group.isFullMode else { return }
        guard !group.children.isEmpty else { return }

        // Prevent surfaceTreeDidChange from interpreting the tree swap as child removal
        isModifyingChildren = true
        defer { isModifyingChildren = false }

        // Save the current split tree
        let isActive = group.id == selectedTabID
        group.savedSplitTree = isActive ? surfaceTree : group.surfaceTree

        // Pick the first child as the active one
        let activeChild = group.children.first!
        group.fullModeActiveChildID = activeChild.id
        group.isFullMode = true

        // Build a single-surface tree for the active child
        if let surface = activeChild.originalSurface {
            let singleTree = SplitTree<Ghostty.SurfaceView>(view: surface)
            if isActive {
                surfaceTree = singleTree
                group.surfaceTree = singleTree
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            } else {
                group.surfaceTree = singleTree
            }
        }

        saveScreenSessionState()
    }

    /// Exit full mode for a group: restore the saved split tree.
    func exitFullMode(for group: SidebarTabEntry) {
        guard group.isGroup, group.isFullMode else { return }
        guard let savedTree = group.savedSplitTree else { return }

        // Prevent surfaceTreeDidChange from interpreting the tree swap as child removal
        isModifyingChildren = true
        defer { isModifyingChildren = false }

        let isActive = group.id == selectedTabID
        group.isFullMode = false
        group.fullModeActiveChildID = nil
        group.savedSplitTree = nil

        if isActive {
            surfaceTree = savedTree
            group.surfaceTree = savedTree
            // Focus the first leaf
            if let firstLeaf = savedTree.root?.leftmostLeaf() {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: firstLeaf)
                }
            }
        } else {
            group.surfaceTree = savedTree
        }

        saveScreenSessionState()
    }

    /// Switch the displayed child in full mode.
    func switchFullModeChild(to child: SidebarTabEntry, in group: SidebarTabEntry) {
        guard group.isGroup, group.isFullMode else { return }
        guard group.children.contains(where: { $0.id == child.id }) else { return }
        guard child.id != group.fullModeActiveChildID else { return }

        // Prevent surfaceTreeDidChange from interpreting the tree swap as child removal
        isModifyingChildren = true
        defer { isModifyingChildren = false }

        group.fullModeActiveChildID = child.id

        let isActive = group.id == selectedTabID
        if let surface = child.originalSurface {
            let singleTree = SplitTree<Ghostty.SurfaceView>(view: surface)
            if isActive {
                surfaceTree = singleTree
                group.surfaceTree = singleTree
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            } else {
                group.surfaceTree = singleTree
            }
        }
    }

    // MARK: - Tab Reordering

    /// Move a top-level tab from one index to another.
    func moveTab(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex else { return }
        guard fromIndex >= 0, fromIndex < tabs.count else { return }
        guard toIndex >= 0, toIndex <= tabs.count else { return }
        let tab = tabs.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        tabs.insert(tab, at: insertAt)
        saveScreenSessionState()
    }

    // MARK: - Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // During window close, surfaces are torn down which triggers tree changes.
        // We've already saved the correct state in windowWillClose, so skip all processing.
        guard !isClosing else { return }

        // If closeChildTab is actively modifying the tree, skip — it handles everything.
        guard !isModifyingChildren else { return }

        guard let tab = currentTab else { return }

        // If tree becomes empty, the user typed `exit` — screen session is already dead.
        if to.isEmpty {
            tab.screenSessionName = nil
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                closeTabImmediately(tab, at: index)
            }
            return
        }

        // Keep the current tab's surfaceTree in sync
        tab.surfaceTree = to

        // For groups: detect which children's surfaces were removed from the tree
        // (e.g. via Cmd+W closing a split pane) and sync group.children accordingly.
        if tab.isGroup {
            let remainingSurfaces = to.root?.leaves() ?? []
            let removedChildren = tab.children.filter { child in
                guard let surface = child.originalSurface else { return true }
                return !remainingSurfaces.contains(where: { $0 === surface })
            }

            if !removedChildren.isEmpty {
                for child in removedChildren {
                    if let name = child.screenSessionName {
                        ScreenSessionManager.shared.killSession(name: name)
                    }
                    tab.children.removeAll { $0.id == child.id }
                }

                // Force @Published tabs to fire so SwiftUI re-computes flatRows.
                // Modifying tab.children alone doesn't trigger controller.objectWillChange
                // because the tabs array reference hasn't changed.
                let snapshot = tabs
                tabs = snapshot

                // If no children left, close the group
                if tab.children.isEmpty {
                    if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                        closeTabImmediately(tab, at: index)
                        return
                    }
                } else if tab.isFullMode, tab.children.count == 1 {
                    tab.isFullMode = false
                    tab.savedSplitTree = nil
                    tab.fullModeActiveChildID = nil
                }

                saveScreenSessionState()
            }
        }
    }

    override func focusedSurfaceDidChange(to surface: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: surface)

        // Keep the current tab's focused surface in sync.
        guard let surface else { return }
        currentTab?.updateFocusedSurface(surface)

        // Update sidebar highlight to follow focus within a group.
        if let tab = currentTab, tab.isGroup {
            if let child = tab.children.first(where: { $0.originalSurface === surface }) {
                highlightedItemID = child.id
            }
        }
    }

    // MARK: - Notification Handlers

    @objc private func onToggleFullscreen(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surface) else { return }
        toggleFullscreen(mode: .native)
    }

    /// A flattened list of activatable items for Cmd+Number shortcuts.
    /// Standalone tabs and group children are included; group headers are skipped.
    /// Each element is (tab: the tab/child entry, group: the parent group if child, otherwise nil).
    var flatActivatableItems: [(tab: SidebarTabEntry, group: SidebarTabEntry?)] {
        var items: [(tab: SidebarTabEntry, group: SidebarTabEntry?)] = []
        for tab in tabs {
            if tab.isGroup {
                for child in tab.children {
                    items.append((tab: child, group: tab))
                }
            } else {
                items.append((tab: tab, group: nil))
            }
        }
        return items
    }

    @objc private func onGotoTab(notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == focusedSurface else { return }

        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        let flatItems = flatActivatableItems
        guard !flatItems.isEmpty else { return }

        // Find current position in the flat list
        let currentFlatIndex: Int
        if let selectedID = selectedTabID {
            // Try to find the currently focused item in the flat list
            currentFlatIndex = flatItems.firstIndex(where: { $0.tab.id == selectedID }) ?? 0
        } else {
            currentFlatIndex = 0
        }

        let finalIndex: Int

        if tabIndex <= 0 {
            if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                finalIndex = currentFlatIndex == 0 ? flatItems.count - 1 : currentFlatIndex - 1
            } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                finalIndex = currentFlatIndex == flatItems.count - 1 ? 0 : currentFlatIndex + 1
            } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
                finalIndex = flatItems.count - 1
            } else {
                return
            }
        } else {
            guard tabIndex >= 1 else { return }
            finalIndex = min(Int(tabIndex - 1), flatItems.count - 1)
        }

        guard finalIndex >= 0 else { return }
        let item = flatItems[finalIndex]

        if let group = item.group {
            // It's a child inside a group — select the group, then focus the child
            if group.id != selectedTabID {
                selectTab(group)
            }
            if group.isFullMode {
                switchFullModeChild(to: item.tab, in: group)
            } else if let surface = item.tab.focusedSurface ?? item.tab.originalSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        } else {
            selectTab(item.tab)
        }
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }
        derivedConfig = DerivedConfig(config)
    }

    // MARK: - Screen Session Persistence

    /// Collect all tabs' screen session info and persist to disk.
    func saveScreenSessionState() {
        let mgr = ScreenSessionManager.shared
        guard mgr.isAvailable else { return }

        func stateFor(_ tab: SidebarTabEntry) -> ScreenSessionManager.SessionState? {
            if tab.isGroup {
                let childStates = tab.children.compactMap { stateFor($0) }
                guard !childStates.isEmpty else { return nil }
                // Find active child index for full mode
                var activeIndex: Int? = nil
                if tab.isFullMode, let activeID = tab.fullModeActiveChildID {
                    activeIndex = tab.children.firstIndex(where: { $0.id == activeID })
                }
                return ScreenSessionManager.SessionState(
                    screenSessionName: "",
                    title: tab.displayTitle,
                    workingDirectory: nil,
                    isGroup: true,
                    groupName: tab.groupName,
                    children: childStates,
                    isFullMode: tab.isFullMode ? true : nil,
                    fullModeActiveChildIndex: activeIndex
                )
            } else {
                guard let name = tab.screenSessionName else { return nil }
                return ScreenSessionManager.SessionState(
                    screenSessionName: name,
                    title: tab.displayTitle,
                    workingDirectory: nil,
                    isGroup: false,
                    groupName: nil,
                    children: nil
                )
            }
        }

        let sessions = tabs.compactMap { stateFor($0) }
        let selectedName = currentTab?.screenSessionName
        mgr.saveState(ScreenSessionManager.SavedState(sessions: sessions, selectedScreenName: selectedName))
    }

    /// Attempt to restore a window from saved screen sessions.
    /// Returns nil if no sessions could be restored.
    static func restoreWindow(_ ghostty: Ghostty.App) -> SidebarTerminalController? {
        let mgr = ScreenSessionManager.shared
        guard mgr.isAvailable else { return nil }
        guard let state = mgr.loadState() else { return nil }
        guard let ghostty_app = ghostty.app else { return nil }

        let aliveSessions = Set(mgr.listAliveSessions())

        // Filter to sessions that are still alive
        func isAlive(_ s: ScreenSessionManager.SessionState) -> Bool {
            if s.isGroup {
                return s.children?.contains(where: isAlive) ?? false
            }
            return aliveSessions.contains(s.screenSessionName)
        }

        let restorableSessions = state.sessions.filter { isAlive($0) }
        guard !restorableSessions.isEmpty else { return nil }

        // Build a config for the first restorable leaf session
        func firstLeaf(_ s: ScreenSessionManager.SessionState) -> ScreenSessionManager.SessionState? {
            if s.isGroup {
                return s.children?.compactMap({ firstLeaf($0) }).first
            }
            return aliveSessions.contains(s.screenSessionName) ? s : nil
        }

        guard let firstSession = restorableSessions.compactMap({ firstLeaf($0) }).first else {
            return nil
        }

        // Create the controller with the first session as the base
        var baseConfig = Ghostty.SurfaceConfiguration()
        baseConfig.command = mgr.reattachCommand(sessionName: firstSession.screenSessionName)
        if let wd = firstSession.workingDirectory {
            baseConfig.workingDirectory = wd
        }

        let controller = SidebarTerminalController(ghostty, withBaseConfig: baseConfig)
        // Set screen session name on the first tab
        controller.tabs.first?.screenSessionName = firstSession.screenSessionName
        controller.tabs.first?.defaultTitle = firstSession.title

        // Track whether the first leaf (used to bootstrap the controller) has been consumed
        var firstLeafUsed = true

        /// Helper: create a SidebarTabEntry for a leaf session by reattaching to its tmux session.
        func makeChildTab(_ session: ScreenSessionManager.SessionState) -> SidebarTabEntry {
            var config = Ghostty.SurfaceConfiguration()
            config.command = mgr.reattachCommand(sessionName: session.screenSessionName)
            if let wd = session.workingDirectory {
                config.workingDirectory = wd
            }
            let surface = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
            let tree = SplitTree<Ghostty.SurfaceView>(view: surface)
            let tab = SidebarTabEntry(surfaceTree: tree, focusedSurface: surface)
            tab.screenSessionName = session.screenSessionName
            tab.defaultTitle = session.title
            return tab
        }

        /// Helper: build a combined split tree from an array of surfaces using the same
        /// layout strategy as joinTab (left-right, then top rows).
        func buildSplitTree(from surfaces: [Ghostty.SurfaceView]) -> SplitTree<Ghostty.SurfaceView> {
            guard !surfaces.isEmpty else { return SplitTree<Ghostty.SurfaceView>() }
            if surfaces.count == 1 {
                return SplitTree<Ghostty.SurfaceView>(view: surfaces[0])
            }

            var tree = SplitTree<Ghostty.SurfaceView>(view: surfaces[0])
            for (i, surface) in surfaces.dropFirst().enumerated() {
                let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
                switch i {
                case 0: direction = .right   // 1→2: left-right
                case 1: direction = .down    // 2→3: bottom row
                default: direction = .down   // 3→4: grid-ish
                }
                // Insert at the appropriate existing surface
                let insertAt: Ghostty.SurfaceView
                switch i {
                case 0: insertAt = surfaces[0]
                case 1: insertAt = tree.root!.rightmostLeaf()
                default: insertAt = tree.root!.leftmostLeaf()
                }
                if let newTree = try? tree.inserting(view: surface, at: insertAt, direction: direction) {
                    tree = newTree
                }
            }
            return tree
        }

        // Restore all sessions, rebuilding groups properly
        for session in restorableSessions {
            if session.isGroup {
                guard let children = session.children else { continue }
                let aliveChildren = children.filter { aliveSessions.contains($0.screenSessionName) }
                guard !aliveChildren.isEmpty else { continue }

                // Build child tab entries
                var childTabs: [SidebarTabEntry] = []
                for child in aliveChildren {
                    if firstLeafUsed, child.screenSessionName == firstSession.screenSessionName {
                        // Reuse the controller's initial tab as the first child
                        firstLeafUsed = false
                        if let existingTab = controller.tabs.first {
                            childTabs.append(existingTab)
                        }
                    } else {
                        childTabs.append(makeChildTab(child))
                    }
                }

                if childTabs.count == 1 {
                    // Only one child survived — restore as standalone tab with the group name
                    // (don't create a group for a single child)
                    let tab = childTabs[0]
                    if controller.tabs.contains(where: { $0.id == tab.id }) {
                        // Already in tabs (reused initial tab) — just keep it
                    } else {
                        controller.tabs.append(tab)
                    }
                } else {
                    // Multiple children — build a proper group
                    let surfaces = childTabs.compactMap { $0.originalSurface }
                    let combinedTree = buildSplitTree(from: surfaces)

                    let group = SidebarTabEntry(
                        groupName: session.groupName ?? "Tab Area",
                        surfaceTree: combinedTree,
                        children: childTabs
                    )

                    // Restore full mode if it was saved
                    if session.isFullMode == true {
                        group.savedSplitTree = combinedTree
                        group.isFullMode = true
                        let activeIdx = session.fullModeActiveChildIndex ?? 0
                        let clampedIdx = min(activeIdx, childTabs.count - 1)
                        let activeChild = childTabs[clampedIdx]
                        group.fullModeActiveChildID = activeChild.id
                        // Show only the active child's surface
                        if let surface = activeChild.originalSurface {
                            group.surfaceTree = SplitTree<Ghostty.SurfaceView>(view: surface)
                        }
                    }

                    // Remove the initial tab from top-level if it was consumed into this group
                    if let initialTab = controller.tabs.first,
                       childTabs.contains(where: { $0.id == initialTab.id }) {
                        controller.tabs.removeAll { $0.id == initialTab.id }
                    }

                    controller.tabs.append(group)
                }
            } else if aliveSessions.contains(session.screenSessionName) {
                if firstLeafUsed, session.screenSessionName == firstSession.screenSessionName {
                    firstLeafUsed = false
                    continue
                }
                controller.addRestoredTab(
                    screenName: session.screenSessionName,
                    title: session.title,
                    workingDirectory: session.workingDirectory
                )
            }
        }

        // Select the first tab/group and set up the surface tree
        if let first = controller.tabs.first {
            controller.selectedTabID = first.id
            controller.surfaceTree = first.surfaceTree
        }

        // Try to restore the selected tab
        if let selectedName = state.selectedScreenName {
            // Search in top-level tabs and group children
            for tab in controller.tabs {
                if tab.screenSessionName == selectedName {
                    controller.selectTab(tab)
                    break
                }
                if tab.isGroup {
                    // If the selected session was in a group, select the group
                    if tab.children.contains(where: { $0.screenSessionName == selectedName }) {
                        controller.selectTab(tab)
                        break
                    }
                }
            }
        }

        // Set up the window and show it (same as newWindow)
        controller.setupWindow()
        allControllers.insert(controller)
        DispatchQueue.main.async {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        return controller
    }

    // MARK: - Static Factory

    /// Creates a new sidebar-based terminal window.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> SidebarTerminalController {
        let c = SidebarTerminalController(ghostty, withBaseConfig: baseConfig)
        c.setupWindow()

        // Retain the controller — NSWindow.windowController is weak.
        allControllers.insert(c)

        DispatchQueue.main.async {
            c.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        return c
    }

    // MARK: - DerivedConfig

    private struct DerivedConfig {
        let focusFollowsMouse: Bool

        init(_ config: Ghostty.Config) {
            self.focusFollowsMouse = config.focusFollowsMouse
        }
    }
}

// MARK: - Sidebar UI State

/// Standalone ObservableObject for sidebar mode,
/// so SwiftUI can properly observe changes (NSWindowController doesn't
/// conform to ObservableObject).
class SidebarUIState: ObservableObject {
    @Published var sidebarMode: SidebarMode = .terminal
}

// MARK: - Root SwiftUI View (observes SidebarUIState for mode switching)

private struct SidebarRootView: View {
    let controller: SidebarTerminalController
    @ObservedObject var uiState: SidebarUIState

    var body: some View {
        HSplitView {
            SidebarView(controller: controller, sidebarMode: $uiState.sidebarMode)
                .frame(minWidth: 150, maxWidth: 300)

            TerminalView(ghostty: controller.ghostty, viewModel: controller, delegate: controller)
                .splitPaneTitleBar(true)
                .padding(.leading, 4)
                .frame(minWidth: 400)
        }
    }
}

// MARK: - SplitTree.Node helpers

extension SplitTree.Node where ViewType == Ghostty.SurfaceView {
    /// Whether any surface in this node subtree needs confirmation to quit.
    var needsConfirmQuit: Bool {
        switch self {
        case .leaf(let view):
            return view.needsConfirmQuit
        case .split(let split):
            return split.left.needsConfirmQuit || split.right.needsConfirmQuit
        }
    }
}

// MARK: - Custom NSWindow for Cmd+1~9 interception

/// NSWindow subclass that intercepts Cmd+1~9 key equivalents for sidebar tab switching.
/// This is necessary because SidebarTerminalController disables native macOS tabs,
/// so the default tab-switching key equivalents don't exist. By overriding
/// performKeyEquivalent, we intercept BEFORE the SurfaceView's performKeyEquivalent
/// sends the key to the terminal.
class SidebarTerminalWindow: NSWindow {
    weak var sidebarController: SidebarTerminalController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only intercept Cmd+digit (no other modifiers)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           let chars = event.charactersIgnoringModifiers,
           let digit = chars.first?.wholeNumberValue,
           digit >= 1, digit <= 9,
           let controller = sidebarController {
            controller.switchToFlatIndex(digit)
            return true  // consumed
        }

        return super.performKeyEquivalent(with: event)
    }
}
