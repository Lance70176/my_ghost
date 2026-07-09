import Foundation
import Combine
import GhosttyKit

/// Represents a single tab entry in the sidebar. Each tab owns a surface tree
/// (potentially with splits) and tracks its title and bell state.
/// A tab can have children (joined tabs) which share the same split tree.
/// When `groupName` is set, this entry acts as a named group container.
class SidebarTabEntry: ObservableObject, Identifiable {
    let id: UUID

    /// The surface tree for this tab. When the tab is active, this is synced
    /// with the controller's surfaceTree. When inactive, it holds the preserved state.
    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    /// The surface that was focused when this tab was last active.
    var focusedSurface: Ghostty.SurfaceView?

    /// The original surface that this tab was created with.
    /// The sidebar title always tracks this surface's title.
    var originalSurface: Ghostty.SurfaceView?

    /// Title derived from the terminal (e.g. shell process title).
    @Published var defaultTitle: String = "Terminal"

    /// User-set custom title (via right-click Rename). When set, it takes
    /// precedence over the terminal-derived title and is never overwritten
    /// by shell title updates.
    @Published var customTitle: String?

    /// Whether any surface in this tab currently has the bell active.
    @Published var bell: Bool = false

    /// Child tabs that have been joined into this tab's split tree.
    @Published var children: [SidebarTabEntry] = []

    /// The screen session name associated with this tab (e.g. "myghost_<uuid>").
    /// When set, the tab's shell runs inside a GNU screen session for persistence.
    /// For remote tabs, this is the tmux session name on the remote host.
    var screenSessionName: String?

    /// SSH destination for remote tabs (ssh config alias or "user@host").
    /// nil for local tabs.
    var remoteTarget: String?

    /// Extra ssh options (port, identity file) for remote tabs.
    var remoteSSHOptions: [String] = []

    /// Host display name shown as a badge on remote tabs.
    var remoteDisplayName: String?

    /// Whether this tab is connected to a remote host over SSH.
    var isRemote: Bool { remoteTarget != nil }

    /// When non-nil, this entry is a named group container (Tab Area).
    /// The group header displays this name, which can be renamed via right-click.
    @Published var groupName: String?

    /// Whether this group is in "full mode" (showing one child at a time instead of split panes).
    @Published var isFullMode: Bool = false

    /// Whether the group's children are hidden in the sidebar list (display
    /// state only — the panes themselves are unaffected). Toggled by the
    /// disclosure chevron at the front of the group header row.
    @Published var isCollapsed: Bool = false

    /// The split tree saved before entering full mode, so it can be restored on exit.
    var savedSplitTree: SplitTree<Ghostty.SurfaceView>?

    /// The ID of the child currently displayed in full mode.
    @Published var fullModeActiveChildID: UUID?

    /// Whether this entry is a group container.
    var isGroup: Bool { groupName != nil }

    /// The title to display in the sidebar.
    var displayTitle: String {
        if let groupName { return groupName }
        if let customTitle { return customTitle }
        return defaultTitle
    }

    private var cancellables = Set<AnyCancellable>()

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, focusedSurface: Ghostty.SurfaceView? = nil) {
        self.id = UUID()
        self.surfaceTree = surfaceTree
        self.focusedSurface = focusedSurface
        self.originalSurface = focusedSurface

        if let surface = focusedSurface {
            subscribeTo(surface: surface)
        }
    }

    /// Create a group entry that contains multiple child tabs sharing a split tree.
    init(groupName: String, surfaceTree: SplitTree<Ghostty.SurfaceView>, children: [SidebarTabEntry]) {
        self.id = UUID()
        self.groupName = groupName
        self.surfaceTree = surfaceTree
        self.children = children
        // A group's focused surface defaults to the first child's surface
        self.focusedSurface = children.first?.focusedSurface
        self.originalSurface = nil
    }

    /// Subscribe to a surface's published properties to keep our title/bell in sync.
    private func subscribeTo(surface: Ghostty.SurfaceView) {
        cancellables.removeAll()

        surface.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                self?.defaultTitle = newTitle
            }
            .store(in: &cancellables)

        surface.$bell
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newBell in
                self?.bell = newBell
            }
            .store(in: &cancellables)
    }

    /// Update the focused surface. Only re-subscribes title if the surface
    /// is this tab's own original surface (not a joined child's surface).
    func updateFocusedSurface(_ surface: Ghostty.SurfaceView?) {
        focusedSurface = surface

        // If this tab has no original surface yet, adopt this one
        guard let surface else { return }
        if originalSurface == nil {
            // Only adopt a surface that actually lives in this tab's tree.
            // During rapid tab switching the controller's focused surface can
            // still belong to another tab; adopting it would subscribe this
            // tab's title to the other tab's terminal.
            guard surfaceTree.root?.leaves().contains(where: { $0 === surface }) ?? false else { return }
            originalSurface = surface
            subscribeTo(surface: surface)
        } else if surface === originalSurface {
            // Re-subscribe in case the subscription was lost
            subscribeTo(surface: surface)
        }
        // If surface is a child's surface, do NOT re-subscribe — keep our own title
    }
}
