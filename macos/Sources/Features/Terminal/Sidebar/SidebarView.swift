import SwiftUI

/// Sidebar display mode.
enum SidebarMode {
    case terminal
    case fileBrowser
}

/// A flattened row item for stable List identity.
private enum SidebarRowItem: Identifiable {
    case parent(tab: SidebarTabEntry, index: Int)
    case child(child: SidebarTabEntry, parent: SidebarTabEntry)

    var id: UUID {
        switch self {
        case .parent(let tab, _): return tab.id
        case .child(let child, _): return child.id
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
            rows.append(.parent(tab: tab, index: index))
            for child in tab.children {
                rows.append(.child(child: child, parent: tab))
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
            }
        }
        .frame(minWidth: 150, idealWidth: 200)
    }

    /// The terminal tab list view.
    private var terminalTabList: some View {
        List(selection: $selection) {
            ForEach(flatRows) { item in
                switch item {
                case .parent(let tab, let index):
                    SidebarParentTabRow(
                        tab: tab,
                        shortcutIndex: index < 9 ? index + 1 : nil,
                        controller: controller,
                        selection: $selection
                    )
                    .tag(tab.id)

                case .child(let child, let parent):
                    SidebarChildTabRow(
                        child: child,
                        parent: parent,
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
            // Check if it's a top-level tab
            if let tab = controller.tabs.first(where: { $0.id == newValue }) {
                if tab.id == controller.selectedTabID {
                    // Already selected — just focus back to the parent's own surface
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
            // Check if it's a child tab — select the parent and focus the child's surface
            for parent in controller.tabs {
                if let child = parent.children.first(where: { $0.id == newValue }) {
                    // Select parent first (will no-op if already selected)
                    if parent.id != controller.selectedTabID {
                        controller.selectTab(parent)
                    }
                    // Focus the child's surface
                    if let surface = child.focusedSurface {
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

// MARK: - Parent tab row (top-level)

private struct SidebarParentTabRow: View {
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
            // Update selection and focus the parent's own surface
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
            // Only show targets that have fewer than 4 panes
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

// MARK: - Child tab row (joined tab under parent)

private struct SidebarChildTabRow: View {
    @ObservedObject var child: SidebarTabEntry
    let parent: SidebarTabEntry
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
        .padding(.leading, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            // Update selection to highlight this child row
            selection = child.id
            // Select parent (if not already) and focus the child's surface
            if parent.id != controller.selectedTabID {
                controller.selectTab(parent)
            }
            if let surface = child.originalSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: surface)
                }
            }
        }
        .contextMenu {
            Button("Unjoin") {
                controller.unjoinTab(child, from: parent)
            }
        }
    }
}
