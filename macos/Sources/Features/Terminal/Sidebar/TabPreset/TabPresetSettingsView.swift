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

            if manager.presets.isEmpty {
                Text(L("No presets yet."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.presets) { preset in
                            presetRow(preset)
                        }
                    }
                }
                .frame(minHeight: 60, maxHeight: 240)
            }

            Button {
                isAddingNew = true
                // A new preset starts out under the tag being browsed.
                editingPreset = TabPreset(
                    name: "",
                    tagIDs: manager.selectedTagID.map { [$0] } ?? [])
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
        .padding(20)
        .frame(width: 480)
        .sheet(item: $editingPreset) { preset in
            TabPresetForm(
                manager: manager,
                preset: preset,
                isNew: isAddingNew,
                onSave: { manager.upsert($0) })
        }
    }

    // MARK: Presets

    @ViewBuilder
    private func presetRow(_ preset: TabPreset) -> some View {
        let tags = manager.tags(of: preset)
        let lines = preset.commandLines
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(preset.name)
                        .font(.body)
                        .lineLimit(1)
                    ForEach(tags) { tag in
                        TabPresetTagBadge(name: tag.name)
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
                manager.move(preset, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(manager.presets.first?.id == preset.id)
            .help(L("Move up"))

            Button {
                manager.move(preset, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(manager.presets.last?.id == preset.id)
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
                manager.presets.removeAll { $0.id == preset.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete preset"))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Tags

    @ViewBuilder
    private var tagList: some View {
        VStack(spacing: 4) {
            ForEach(manager.tags) { tag in
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
                    .frame(height: 130)
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
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                        alignment: .leading, spacing: 4
                    ) {
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
        .padding(20)
        .frame(width: 460)
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
