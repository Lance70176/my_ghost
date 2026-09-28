import Foundation
import SwiftUI

/// A user-made label for sorting presets — a project, or a Mac the preset is
/// meant for. The "+" picker filters by one tag at a time.
struct TabPresetTag: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// A saved way of opening a tab: the name the tab gets, and the commands typed
/// into it, in order, once its shell is up.
struct TabPreset: Codable, Identifiable, Hashable {
    var id = UUID()

    /// Shown in the picker, and given to the tab as its name.
    var name: String

    /// One command per line.
    var commands: String = ""

    /// The tags this preset is filed under. Untagged presets only show under "All".
    var tagIDs: [UUID] = []

    /// The commands with blank lines and stray indentation dropped.
    var commandLines: [String] {
        commands.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What is typed into the new tab: every command followed by Return.
    /// nil when the preset only names the tab.
    var input: String? {
        let lines = commandLines
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Holds the saved new-tab presets and their tags.
///
/// Presets and tags live in one file in Application Support/MyGhost, so the
/// same set can be copied to another Mac as is. Which tag the picker is
/// filtering by is kept apart from it, in this Mac's defaults: that is the
/// one thing meant to differ between machines sharing a preset file.
@MainActor
class TabPresetManager: ObservableObject {
    static let shared = TabPresetManager()

    @Published var presets: [TabPreset] = [] {
        didSet { save() }
    }

    @Published var tags: [TabPresetTag] = [] {
        didSet { save() }
    }

    /// The tag the picker is filtering by. nil shows every preset.
    @Published var selectedTagID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedTagID?.uuidString, forKey: Self.selectedTagDefaultsKey)
        }
    }

    private struct PersistedState: Codable {
        var presets: [TabPreset]
        var tags: [TabPresetTag]
    }

    private static let selectedTagDefaultsKey = "MyGhostTabPresetSelectedTag"

    private var stateFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MyGhost/tab_presets.json")
    }

    private var loading = false

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.selectedTagDefaultsKey) {
            selectedTagID = UUID(uuidString: saved)
        }
        load()
    }

    // MARK: - Lookup

    /// The presets filed under a tag, in their saved order. nil means all of them.
    func presets(taggedWith tagID: UUID?) -> [TabPreset] {
        guard let tagID else { return presets }
        return presets.filter { $0.tagIDs.contains(tagID) }
    }

    /// The tags a preset is filed under, in the tag list's order.
    func tags(of preset: TabPreset) -> [TabPresetTag] {
        tags.filter { preset.tagIDs.contains($0.id) }
    }

    // MARK: - Editing

    /// Add a tag, or return the existing one of the same name.
    @discardableResult
    func addTag(named name: String) -> TabPresetTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let tag = TabPresetTag(name: trimmed)
        tags.append(tag)
        return tag
    }

    /// Delete a tag and take it off every preset that carried it.
    func deleteTag(_ tag: TabPresetTag) {
        for index in presets.indices where presets[index].tagIDs.contains(tag.id) {
            presets[index].tagIDs.removeAll { $0 == tag.id }
        }
        tags.removeAll { $0.id == tag.id }
        if selectedTagID == tag.id { selectedTagID = nil }
    }

    /// Replace the preset with the same id, or append it as a new one.
    func upsert(_ preset: TabPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
    }

    /// Move a preset one place up or down the list.
    func move(_ preset: TabPreset, by offset: Int) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let target = index + offset
        guard presets.indices.contains(target) else { return }
        presets.swapAt(index, target)
    }

    // MARK: - Persistence

    /// Read the file again, picking up a copy dropped in from another Mac
    /// while the app was running.
    func reload() {
        load()
    }

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        if state.presets != presets { presets = state.presets }
        if state.tags != tags { tags = state.tags }
        // A tag remembered from before may be gone from the file by now.
        if let selected = selectedTagID, !tags.contains(where: { $0.id == selected }) {
            selectedTagID = nil
        }
    }

    private func save() {
        guard !loading else { return }
        let state = PersistedState(presets: presets, tags: tags)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: stateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateFileURL, options: .atomic)
        } catch {
            // Best-effort persistence
        }
    }
}
