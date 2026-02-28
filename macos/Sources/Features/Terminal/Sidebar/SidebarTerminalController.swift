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

        super.init(ghostty, baseConfig: base)

        // Wrap the initial surface tree (created by super) into the first tab entry.
        let firstTab = SidebarTabEntry(surfaceTree: surfaceTree, focusedSurface: focusedSurface)
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
    func addNewTab(baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        guard let ghostty_app = ghostty.app else { return }

        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: baseConfig)
        let newTree = SplitTree<Ghostty.SurfaceView>(view: newSurface)
        let newTab = SidebarTabEntry(surfaceTree: newTree, focusedSurface: newSurface)

        tabs.append(newTab)
        // Don't set selectedTabID here — selectTab() handles it.
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
        let wasSelected = (tab.id == selectedTabID)
        tabs.remove(at: index)

        if tabs.isEmpty {
            // No more tabs — close the window.
            window?.close()
            return
        }

        if wasSelected {
            // Switch to an adjacent tab.
            let newIndex = min(index, tabs.count - 1)
            let newTab = tabs[newIndex]
            selectTab(newTab)
        }
    }

    /// Join `source` tab into `target` tab with smart layout:
    /// - 1→2 panes: left-right split
    /// - 2→3 panes: top row (2) + bottom row (1)
    /// - 3→4 panes: 2x2 grid
    /// - 4+ panes: not allowed
    func joinTab(_ source: SidebarTabEntry, into target: SidebarTabEntry) {
        guard source.id != target.id else { return }
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == source.id }) else { return }

        // Get the surface from the source tab's tree
        guard let sourceRoot = source.surfaceTree.root else { return }
        let sourceSurface = sourceRoot.leftmostLeaf()

        // Determine current tree to work with
        let currentTree = (target.id == selectedTabID) ? surfaceTree : target.surfaceTree
        let leafCount = currentTree.root?.leaves().count ?? 0

        // Max 4 panes per tab
        guard leafCount < 4 else { return }

        // Determine insertion point and direction based on current leaf count
        let insertionSurface: Ghostty.SurfaceView
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection

        switch leafCount {
        case 1:
            // 1→2: left-right split → [1 | 2]
            guard let leaf = currentTree.root?.leftmostLeaf() else { return }
            insertionSurface = leaf
            direction = .right

        case 2:
            // 2→3: split the RIGHT leaf downward → [1 | [2 / 3]]
            guard let root = currentTree.root else { return }
            insertionSurface = root.rightmostLeaf()
            direction = .down

        case 3:
            // 3→4: split the LEFT-TOP leaf downward → [[1 / 4] | [2 / 3]] = 2x2
            guard let leaf = currentTree.root?.leftmostLeaf() else { return }
            insertionSurface = leaf
            direction = .down

        default:
            return
        }

        // Perform the insertion
        if target.id == selectedTabID {
            do {
                let newTree = try surfaceTree.inserting(
                    view: sourceSurface,
                    at: insertionSurface,
                    direction: direction
                )
                surfaceTree = newTree
                target.surfaceTree = newTree
            } catch {
                return
            }
        } else {
            do {
                let newTree = try target.surfaceTree.inserting(
                    view: sourceSurface,
                    at: insertionSurface,
                    direction: direction
                )
                target.surfaceTree = newTree
            } catch {
                return
            }
        }

        // Remove source from top-level and add as child of target
        tabs.remove(at: sourceIndex)
        target.children.append(source)
        // If the source was selected, switch to target
        if selectedTabID == source.id {
            selectTab(target)
        }
    }

    /// Unjoin a child tab from its parent, restoring it as an independent top-level tab.
    func unjoinTab(_ child: SidebarTabEntry, from parent: SidebarTabEntry) {
        // Find and remove the child's surface from the parent's tree
        guard let childSurface = child.originalSurface else { return }
        let leafNode = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: childSurface)

        if parent.id == selectedTabID {
            // Parent is active — modify live tree
            let newTree = surfaceTree.removing(leafNode)
            surfaceTree = newTree
            parent.surfaceTree = newTree
        } else {
            let newTree = parent.surfaceTree.removing(leafNode)
            parent.surfaceTree = newTree
        }

        // Remove from parent's children
        parent.children.removeAll { $0.id == child.id }

        // Restore child as an independent tab with its own tree
        let newTree = SplitTree<Ghostty.SurfaceView>(view: childSurface)
        child.surfaceTree = newTree
        child.focusedSurface = childSurface

        // Insert as a new top-level tab right after the parent
        if let parentIndex = tabs.firstIndex(where: { $0.id == parent.id }) {
            tabs.insert(child, at: parentIndex + 1)
        } else {
            tabs.append(child)
        }
    }

    /// The currently selected tab entry.
    private var currentTab: SidebarTabEntry? {
        tabs.first(where: { $0.id == selectedTabID })
    }

    // MARK: - Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If tree becomes empty, close the current tab instead of the window.
        if to.isEmpty, let tab = currentTab {
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
