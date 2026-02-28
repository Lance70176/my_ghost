import Foundation
import Combine
import GhosttyKit

/// Represents a single tab entry in the sidebar. Each tab owns a surface tree
/// (potentially with splits) and tracks its title and bell state.
/// A tab can have children (joined tabs) which share the same split tree.
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

    /// The title to display in the sidebar.
    var displayTitle: String {
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
