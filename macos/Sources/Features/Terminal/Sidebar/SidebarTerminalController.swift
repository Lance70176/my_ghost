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

    /// The ID of the currently selected tab.
    @Published var selectedTabID: UUID?

    /// Derived config for window-level settings.
    private var derivedConfig: DerivedConfig

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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghostty"
        window.tabbingMode = .disallowed
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Build the content: sidebar on the left, terminal on the right.
        window.contentView = TerminalViewContainer {
            HSplitView {
                SidebarView(controller: self)
                    .frame(minWidth: 150, maxWidth: 300)

                TerminalView(ghostty: self.ghostty, viewModel: self, delegate: self)
                    .splitPaneTitleBar(true)
                    .frame(minWidth: 400)
                    .padding(.leading, 4)
            }
        }

        window.center()
        self.window = window
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        Self.allControllers.remove(self)
    }

    // MARK: - Tab Management

    /// Select a tab by switching the active surface tree.
    func selectTab(_ tab: SidebarTabEntry) {
        guard tab.id != selectedTabID else { return }

        // Save current state to the old tab
        if let oldTab = currentTab {
            oldTab.surfaceTree = surfaceTree
            oldTab.updateFocusedSurface(focusedSurface)
        }

        // Load new tab's state
        selectedTabID = tab.id
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
        let currentTree = (target.id == selectedTabID || group.id == selectedTabID) ? surfaceTree : group.surfaceTree
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
        if isActive {
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

        if group.id == selectedTabID {
            let newTree = surfaceTree.removing(leafNode)
            surfaceTree = newTree
            group.surfaceTree = newTree
        } else {
            let newTree = group.surfaceTree.removing(leafNode)
            group.surfaceTree = newTree
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

        // If only one child remains in a group, dissolve the group
        if group.isGroup && group.children.count == 1 {
            dissolveGroup(group)
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

    // MARK: - Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If tree becomes empty, the user typed `exit` — screen session is already dead.
        if to.isEmpty, let tab = currentTab {
            tab.screenSessionName = nil
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                closeTabImmediately(tab, at: index)
            }
        }
    }

    override func focusedSurfaceDidChange(to surface: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: surface)

        // Keep the current tab's focused surface in sync.
        if let surface {
            currentTab?.updateFocusedSurface(surface)
        }
    }

    // MARK: - Notification Handlers

    @objc private func onToggleFullscreen(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surface) else { return }
        toggleFullscreen(mode: .native)
    }

    @objc private func onGotoTab(notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == focusedSurface else { return }

        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        guard !tabs.isEmpty else { return }
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }

        let finalIndex: Int

        if tabIndex <= 0 {
            if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                finalIndex = currentIndex == 0 ? tabs.count - 1 : currentIndex - 1
            } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                finalIndex = currentIndex == tabs.count - 1 ? 0 : currentIndex + 1
            } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
                finalIndex = tabs.count - 1
            } else {
                return
            }
        } else {
            guard tabIndex >= 1 else { return }
            finalIndex = min(Int(tabIndex - 1), tabs.count - 1)
        }

        guard finalIndex >= 0 else { return }
        let targetTab = tabs[finalIndex]
        selectTab(targetTab)
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
                return ScreenSessionManager.SessionState(
                    screenSessionName: "",
                    title: tab.displayTitle,
                    workingDirectory: nil,
                    isGroup: true,
                    groupName: tab.groupName,
                    children: childStates
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

        var firstLeafUsed = true

        // Restore remaining sessions
        for session in restorableSessions {
            if session.isGroup {
                // For groups, restore each alive child as a separate tab
                // (simplified — full group restore would require join logic)
                guard let children = session.children else { continue }
                for child in children where aliveSessions.contains(child.screenSessionName) {
                    if firstLeafUsed, child.screenSessionName == firstSession.screenSessionName {
                        firstLeafUsed = false
                        continue
                    }
                    controller.addRestoredTab(
                        screenName: child.screenSessionName,
                        title: child.title,
                        workingDirectory: child.workingDirectory
                    )
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

        // Try to restore the selected tab
        if let selectedName = state.selectedScreenName,
           let tab = controller.tabs.first(where: { $0.screenSessionName == selectedName }) {
            controller.selectTab(tab)
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
