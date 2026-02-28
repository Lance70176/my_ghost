import SwiftUI

// MARK: - Environment key for split pane title bars

private struct SplitPaneTitleBarKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var splitPaneTitleBarVisible: Bool {
        get { self[SplitPaneTitleBarKey.self] }
        set { self[SplitPaneTitleBarKey.self] = newValue }
    }
}

extension View {
    func splitPaneTitleBar(_ visible: Bool) -> some View {
        environment(\.splitPaneTitleBarVisible, visible)
    }
}


/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                action: action)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void

    @Environment(\.splitPaneTitleBarVisible) private var showTitleBar
    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if showTitleBar {
                    SplitPaneTitleBar(surfaceView: surfaceView, action: action)
                }

                Ghostty.InspectableSurface(
                    surfaceView: surfaceView,
                    isSplit: isSplit)
                .background {
                    // If we're dragging ourself, we hide the entire drop zone. This makes
                    // it so that a released drop animates back to its source properly
                    // so it is a proper invalid drop zone.
                    if !isSelfDragging {
                        Color.clear
                            .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                                dropState: $dropState,
                                viewSize: geometry.size,
                                destinationSurface: surfaceView,
                                action: action
                            ))
                    }
                }
                .overlay {
                    if !isSelfDragging, case .dropping(let zone) = dropState {
                        zone.overlay(in: geometry)
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                    isSelfDragging = value == surfaceView.id
                    if isSelfDragging {
                        dropState = .idle
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
        }
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }
}

// MARK: - Split Pane Title Bar

/// A small title bar shown above each split pane when in sidebar mode.
/// Shows the terminal title, an X close button, and supports drag-to-swap between panes.
struct SplitPaneTitleBar: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let action: (TerminalSplitOperation) -> Void

    @State private var isHovering = false
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(isHovering ? 1 : 0.5))

            Text(surfaceView.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.secondary)

            Spacer()

            Button {
                NotificationCenter.default.post(
                    name: Ghostty.Notification.ghosttyCloseSurface,
                    object: surfaceView
                )
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(isHovering ? 1 : 0.3))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isDropTarget
                ? Color.accentColor.opacity(0.3)
                : Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .draggable(surfaceView)
        .dropDestination(for: Ghostty.SurfaceView.self) { items, _ in
            guard let source = items.first, source !== surfaceView else { return false }
            // Swap: drop source onto this title bar → move source to this pane's position
            action(.drop(.init(payload: source, destination: surfaceView, zone: .left)))
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }
}
