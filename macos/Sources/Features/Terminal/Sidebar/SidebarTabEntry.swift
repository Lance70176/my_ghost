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

    /// Whether any surface in this tab currently has the bell active.
    @Published var bell: Bool = false

    /// Child tabs that have been joined into this tab's split tree.
    @Published var children: [SidebarTabEntry] = []

    /// The screen session name associated with this tab (e.g. "myghost_<uuid>").
    /// When set, the tab's shell runs inside a GNU screen session for persistence.
    var screenSessionName: String?

    /// When non-nil, this entry is a named group container (Tab Area).
    /// The group header displays this name, which can be renamed via right-click.
    @Published var groupName: String?

    /// Whether this entry is a group container.
    var isGroup: Bool { groupName != nil }

    /// The title to display in the sidebar.
    var displayTitle: String {
        if let groupName { return groupName }
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

        // If this tab has no original surface yet (shouldn't happen), adopt this one
        guard let surface else { return }
        if originalSurface == nil {
            originalSurface = surface
            subscribeTo(surface: surface)
        } else if surface === originalSurface {
            // Re-subscribe in case the subscription was lost
            subscribeTo(surface: surface)
        }
        // If surface is a child's surface, do NOT re-subscribe — keep our own title
    }
}
