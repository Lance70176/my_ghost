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

    /// The terminal keeps first responder while the popover is up, so keys
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

    /// Returns true when the key was one of ours.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }

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
        default:
            return false
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

/// The popover behind the sidebar's "+": pick a saved preset to open a tab
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

    @StateObject private var model: TabPresetPickerModel

    init(
        manager: TabPresetManager,
        hostName: String?,
        onOpen: @escaping (TabPreset?) -> Void,
        onManage: @escaping () -> Void
    ) {
        self.manager = manager
        self.hostName = hostName
        self.onOpen = onOpen
        self.onManage = onManage
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
        .frame(width: 300)
        .onAppear {
            manager.reload()
            model.onOpen = onOpen
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    tagChip(title: L("All"), tagID: nil)
                    ForEach(manager.tags) { tag in
                        tagChip(title: tag.name, tagID: tag.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)
            .onChange(of: manager.selectedTagID) { selected in
                proxy.scrollTo(Self.chipID(selected))
            }
            .onAppear {
                proxy.scrollTo(Self.chipID(manager.selectedTagID))
            }
        }
    }

    private static func chipID(_ tagID: UUID?) -> String {
        tagID?.uuidString ?? "all"
    }

    private func tagChip(title: String, tagID: UUID?) -> some View {
        let isSelected = manager.selectedTagID == tagID
        return Button(action: { model.select(tag: tagID) }) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isSelected
                        ? Color.accentColor.opacity(0.3)
                        : Color.secondary.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(Self.chipID(tagID))
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
            .frame(maxHeight: 300)
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

            Text(manager.tags.isEmpty ? L("↑↓ select  ⏎ open") : L("↑↓ select  ←→ tag  ⏎ open"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
