import AppKit
import SwiftUI

/// What the picker is showing and which row Return would open. A class so the
/// key monitor, installed once, always acts on the current state.
@MainActor
private final class TabPresetPickerModel: ObservableObject {
    /// The highlighted row: 0 is "None", the presets follow.
    @Published var index = 0

    let manager: TabPresetManager
    var onOpen: (TabPreset?) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private var monitor: Any?

    init(manager: TabPresetManager) {
        self.manager = manager
    }

    /// The rows under the current tag. nil is "None", a tab with no preset.
    var rows: [TabPreset?] {
        [nil] + manager.presets(taggedWith: manager.selectedTagID)
    }

    /// The tag filters in display order. nil is "All".
    var filters: [UUID?] {
        [nil] + manager.tags.map(\.id)
    }

    func select(tag: UUID?) {
        manager.selectedTagID = tag
        index = 0
    }

    func openHighlighted() {
        let rows = rows
        onOpen(rows.indices.contains(index) ? rows[index] : nil)
    }

    // MARK: Keyboard

    /// The terminal keeps first responder while the picker is up, so keys
    /// are picked off before they reach it rather than through focus.
    func startMonitoringKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    func stopMonitoringKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the key was one of ours. Every plain key is — the
    /// picker sits over the terminal, and what is typed at it must not land
    /// in the shell underneath. Cmd shortcuts still go through.
    private func handle(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
        let modifiers = event.modifierFlags.intersection([.control, .option])
        guard modifiers.isEmpty else { return true }

        switch event.keyCode {
        case 126: // up
            index = max(index - 1, 0)
        case 125: // down
            index = min(index + 1, rows.count - 1)
        case 123: // left
            stepTag(by: -1)
        case 124: // right
            stepTag(by: 1)
        case 36, 76: // return, keypad enter
            openHighlighted()
        case 53: // escape
            onCancel()
        default:
            break
        }
        return true
    }

    private func stepTag(by offset: Int) {
        let filters = filters
        guard filters.count > 1 else { return }
        let current = filters.firstIndex(of: manager.selectedTagID) ?? 0
        let next = min(max(current + offset, 0), filters.count - 1)
        guard next != current else { return }
        select(tag: filters[next])
    }
}

/// The picker behind the sidebar's "+" and Cmd+T: pick a saved preset to open a tab
/// named after it with its commands already running, or "None" — highlighted
/// to begin with, so Return alone opens a plain new tab.
struct TabPresetPickerView: View {
    /// Re-renders this view when the interface language changes.
    @ObservedObject private var lang = LanguageManager.shared

    @ObservedObject var manager: TabPresetManager

    /// The remote host the tab will open on. nil for this Mac.
    let hostName: String?

    /// Called with the chosen preset, or nil for a plain tab.
    let onOpen: (TabPreset?) -> Void

    /// Called to open the preset settings.
    let onManage: () -> Void

    /// Called when the picker is dismissed without choosing (Esc).
    let onCancel: () -> Void

    @StateObject private var model: TabPresetPickerModel

    init(
        manager: TabPresetManager,
        hostName: String?,
        onOpen: @escaping (TabPreset?) -> Void,
        onManage: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.manager = manager
        self.hostName = hostName
        self.onOpen = onOpen
        self.onManage = onManage
        self.onCancel = onCancel
        _model = StateObject(wrappedValue: TabPresetPickerModel(manager: manager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !manager.tags.isEmpty {
                tagBar
            }

            Divider()

            rowList

            Divider()

            footer
        }
        .frame(width: 390)
        .onAppear {
            manager.reload()
            model.onOpen = onOpen
            model.onCancel = onCancel
            model.index = 0
            model.startMonitoringKeys()
        }
        .onDisappear {
            model.stopMonitoringKeys()
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(L("New Tab"))
                .font(.headline)
            if let hostName {
                Text(L("on %@", hostName))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var tagBar: some View {
        TabPresetTagFilterBar(
            manager: manager,
            selection: Binding(
                get: { manager.selectedTagID },
                set: { model.select(tag: $0) }))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    private var rowList: some View {
        let rows = model.rows
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { offset, preset in
                        row(preset, at: offset)
                            .id(offset)
                    }

                    if rows.count == 1 {
                        Text(manager.presets.isEmpty
                            ? L("No presets yet. Add one to open a tab with its commands already running.")
                            : L("No presets under this tag."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 390)
            .onChange(of: model.index) { index in
                proxy.scrollTo(index)
            }
        }
    }

    private func row(_ preset: TabPreset?, at offset: Int) -> some View {
        let isHighlighted = model.index == offset
        return Button(action: {
            model.index = offset
            model.openHighlighted()
        }) {
            HStack(spacing: 8) {
                Image(systemName: preset == nil ? "terminal" : "play.rectangle")
                    .frame(width: 18)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset?.name ?? L("None"))
                        .font(.body)
                        .lineLimit(1)
                    Text(Self.summary(of: preset))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if isHighlighted {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.index = offset } }
    }

    private static func summary(of preset: TabPreset?) -> String {
        guard let preset else { return L("A plain new tab") }
        let lines = preset.commandLines
        return lines.isEmpty ? L("Names the tab only") : lines.joined(separator: " ; ")
    }

    private var footer: some View {
        HStack {
            Button(action: onManage) {
                Label(L("Manage Presets…"), systemImage: "slider.horizontal.3")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            Text((manager.tags.isEmpty ? L("↑↓ select  ⏎ open") : L("↑↓ select  ←→ tag  ⏎ open"))
                + "  " + L("esc close"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Puts the new-tab picker in the middle of the window over a dimmed
/// backdrop — clicking the backdrop dismisses it — and hosts the preset
/// settings sheet it leads to. Renders nothing while neither is up.
struct NewTabPickerLayer: View {
    @ObservedObject var controller: SidebarTerminalController
    @ObservedObject private var manager = TabPresetManager.shared

    var body: some View {
        ZStack {
            if controller.isNewTabPickerVisible {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.dismissNewTabPrompt() }

                TabPresetPickerView(
                    manager: manager,
                    hostName: controller.currentHost.flatMap { $0.isLocal ? nil : $0.name },
                    onOpen: { controller.finishNewTabPrompt(with: $0) },
                    onManage: { controller.managePresetsFromNewTabPrompt() },
                    onCancel: { controller.dismissNewTabPrompt() })
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            }
        }
        .sheet(isPresented: $controller.isPresetSettingsVisible) {
            TabPresetSettingsView(manager: manager)
        }
    }
}
