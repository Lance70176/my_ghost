import AppKit
import SwiftUI

/// Settings sheet for new-tab presets: the saved presets (add, edit, reorder,
/// delete) and the tags they are filed under.
struct TabPresetSettingsView: View {
    /// Re-renders this view when the interface language changes.
    @ObservedObject private var lang = LanguageManager.shared

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: TabPresetManager

    /// The preset being edited in the form sheet.
    @State private var editingPreset: TabPreset?
    /// Whether the form sheet is creating a new preset (vs. editing).
    @State private var isAddingNew = false
    /// The name being typed for a new tag.
    @State private var newTagName = ""
    /// The tag the preset list is filtered by. nil shows every preset.
    @State private var filterTagID: UUID?
    /// The preset being duplicated, so the copy lands right after it.
    @State private var duplicateSourceID: UUID?

    /// The presets shown under the current filter.
    private var visiblePresets: [TabPreset] {
        manager.presets(taggedWith: filterTagID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("New Tab Presets"))
                .font(.headline)

            Text(L("Pick a preset from the + button to open a tab named after it, "
                + "with its commands typed in for you."))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if !manager.tags.isEmpty {
                TabPresetTagFilterBar(manager: manager, selection: $filterTagID)
            }

            if manager.presets.isEmpty {
                Text(L("No presets yet."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if visiblePresets.isEmpty {
                Text(L("No presets under this tag."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                FittedScrollView(maxHeight: 360) {
                    VStack(spacing: 2) {
                        ForEach(visiblePresets) { preset in
                            presetRow(preset)
                        }
                    }
                }
            }

            Button {
                isAddingNew = true
                duplicateSourceID = nil
                // A new preset starts out under the tag being browsed.
                editingPreset = TabPreset(
                    name: "",
                    tagIDs: filterTagID.map { [$0] } ?? [])
            } label: {
                Label(L("Add Preset…"), systemImage: "plus")
            }

            Divider()

            Text(L("Tags"))
                .font(.subheadline.weight(.semibold))

            tagList

            HStack {
                Spacer()
                // Not the default action: Return belongs to the tag fields.
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 624)
        // Open on the tag the + picker was last browsing.
        .onAppear { filterTagID = manager.selectedTagID }
        // A tag deleted while it was the filter leaves nothing to filter by.
        .onChange(of: manager.tags) { tags in
            if let id = filterTagID, !tags.contains(where: { $0.id == id }) {
                filterTagID = nil
            }
        }
        .sheet(item: $editingPreset) { preset in
            TabPresetForm(
                manager: manager,
                preset: preset,
                isNew: isAddingNew,
                onSave: { manager.upsert($0, after: duplicateSourceID) })
        }
    }

    // MARK: Presets

    @ViewBuilder
    private func presetRow(_ preset: TabPreset) -> some View {
        let tags = manager.tags(of: preset)
        let lines = preset.commandLines
        let visible = visiblePresets
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(preset.name)
                        .font(.body)
                        .lineLimit(1)
                    // Clicking a tag filters the list by it.
                    ForEach(tags) { tag in
                        Button {
                            filterTagID = tag.id
                        } label: {
                            TabPresetTagBadge(name: tag.name)
                        }
                        .buttonStyle(.plain)
                        .help(L("Show only presets tagged “%@”", tag.name))
                    }
                }
                Text(lines.isEmpty ? L("Names the tab only") : lines.joined(separator: " ; "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Button {
                manager.move(preset, by: -1, among: visible)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(visible.first?.id == preset.id)
            .help(L("Move up"))

            Button {
                manager.move(preset, by: 1, among: visible)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(visible.last?.id == preset.id)
            .help(L("Move down"))

            Button {
                isAddingNew = false
                editingPreset = preset
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L("Edit preset"))

            Button {
                // The copy opens in the form unsaved: Cancel leaves no trace.
                isAddingNew = true
                duplicateSourceID = preset.id
                editingPreset = manager.duplicateDraft(of: preset)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help(L("Duplicate preset"))

            Button {
                manager.presets.removeAll { $0.id == preset.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete preset"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Tags

    @ViewBuilder
    private var tagList: some View {
        VStack(spacing: 4) {
            FittedScrollView(maxHeight: 200) {
                VStack(spacing: 4) {
                    ForEach(manager.tags) { tag in
                        tagRow(tag)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                TextField(L("New tag, e.g. the name of a Mac or a project"), text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)

                Button(L("Add Tag"), action: addTag)
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func tagRow(_ tag: TabPresetTag) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .foregroundColor(.secondary)
                .frame(width: 16)

            TextField(L("Tag name"), text: nameBinding(for: tag.id))
                .textFieldStyle(.roundedBorder)

            Text(usage(of: tag))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)

            Button {
                manager.deleteTag(tag)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete tag (its presets are kept)"))
        }
    }

    private func addTag() {
        guard manager.addTag(named: newTagName) != nil else { return }
        newTagName = ""
    }

    private func usage(of tag: TabPresetTag) -> String {
        let count = manager.presets(taggedWith: tag.id).count
        return count == 1 ? L("1 preset") : L("%d presets", count)
    }

    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { manager.tags.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                guard let index = manager.tags.firstIndex(where: { $0.id == id }) else { return }
                manager.tags[index].name = newValue
            })
    }
}

/// A vertical scroll view as tall as its content, up to `maxHeight` — past
/// that it scrolls. A plain ScrollView takes all the height it is offered,
/// which left a gap under a short list and pushed the rest of the sheet down.
struct FittedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { contentHeight = geo.size.height }
                        .onChange(of: geo.size.height) { contentHeight = $0 }
                })
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

/// A row of tag chips — "All" first, then every tag — that picks the tag a
/// preset list is filtered by. Shared by the + picker and the settings sheet.
struct TabPresetTagFilterBar: View {
    /// Re-renders this view when the interface language changes.
    @ObservedObject private var lang = LanguageManager.shared

    @ObservedObject var manager: TabPresetManager

    /// The tag filtered by. nil is "All".
    @Binding var selection: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: L("All"), tagID: nil)
                    ForEach(manager.tags) { tag in
                        chip(title: tag.name, tagID: tag.id)
                    }
                }
            }
            .onChange(of: selection) { selected in
                withAnimation { proxy.scrollTo(Self.chipID(selected)) }
            }
            .onAppear {
                proxy.scrollTo(Self.chipID(selection))
            }
        }
    }

    private static func chipID(_ tagID: UUID?) -> String {
        tagID?.uuidString ?? "all"
    }

    private func chip(title: String, tagID: UUID?) -> some View {
        let isSelected = selection == tagID
        let count = manager.presets(taggedWith: tagID).count
        return Button(action: { selection = tagID }) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
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
}

/// A tag shown as a small capsule beside a preset's name.
struct TabPresetTagBadge: View {
    /// Re-renders this view when the interface language changes.
    @ObservedObject private var lang = LanguageManager.shared

    let name: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }
}

// MARK: - Add / edit form

/// Form for one preset: its name, its commands, and the tags it is filed under.
private struct TabPresetForm: View {
    /// Re-renders this view when the interface language changes.
    @ObservedObject private var lang = LanguageManager.shared

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: TabPresetManager

    @State var preset: TabPreset
    let isNew: Bool
    let onSave: (TabPreset) -> Void

    /// The name being typed for a new tag.
    @State private var newTagName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? L("Add Preset") : L("Edit Preset"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Name"))
                    .font(.subheadline)
                TextField("", text: $preset.name, prompt: Text(L("e.g. FQ — also names the tab")))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Commands"))
                    .font(.subheadline)
                TabPresetCommandEditor(text: $preset.commands)
                    .frame(height: 170)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                Text(L("One command per line. They are typed into the new tab in order, "
                    + "so a line can start a shell or a program that the next lines then run in."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Tags"))
                    .font(.subheadline)

                if !manager.tags.isEmpty {
                    // Flowed, not gridded: equal-width grid columns left a
                    // wide gap after every short tag name.
                    TabPresetTagFlow(spacing: 14, lineSpacing: 6) {
                        ForEach(manager.tags) { tag in
                            Toggle(tag.name, isOn: tagBinding(tag.id))
                                .toggleStyle(.checkbox)
                                .lineLimit(1)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField(L("New tag"), text: $newTagName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTag)
                    Button(L("Add Tag"), action: addTag)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Not the default action: Return belongs to the commands
                // and the tag field.
                Button(isNew ? L("Add") : L("Save")) {
                    var saved = preset
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Tags deleted while the form was open are dropped.
                    saved.tagIDs = saved.tagIDs.filter { id in
                        manager.tags.contains(where: { $0.id == id })
                    }
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    /// Create the typed tag and file this preset under it.
    private func addTag() {
        guard let tag = manager.addTag(named: newTagName) else { return }
        if !preset.tagIDs.contains(tag.id) { preset.tagIDs.append(tag.id) }
        newTagName = ""
    }

    private func tagBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { preset.tagIDs.contains(id) },
            set: { isOn in
                if isOn {
                    if !preset.tagIDs.contains(id) { preset.tagIDs.append(id) }
                } else {
                    preset.tagIDs.removeAll { $0 == id }
                }
            })
    }
}

// MARK: - Command editor

/// A plain monospaced text box for commands. An AppKit text view rather than
/// `TextEditor`, because the system's smart dashes and quotes have to be off:
/// they turn `--flag` into `—flag` and straight quotes into curly ones, and
/// the command no longer runs.
private struct TabPresetCommandEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Lays tags out left to right at their natural width, wrapping to a new line
/// when the next one doesn't fit.
private struct TabPresetTagFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
