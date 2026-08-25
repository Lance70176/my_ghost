import AppKit
import SwiftUI

/// Sublime-inspired dark theme for the built-in text editor.
enum EditorTheme {
    static let background = NSColor(srgbRed: 0x30/255, green: 0x38/255, blue: 0x41/255, alpha: 1)
    static let gutterBackground = NSColor(srgbRed: 0x2b/255, green: 0x33/255, blue: 0x3b/255, alpha: 1)
    static let tabBarBackground = NSColor(srgbRed: 0x25/255, green: 0x2c/255, blue: 0x33/255, alpha: 1)
    static let text = NSColor(srgbRed: 0xd8/255, green: 0xde/255, blue: 0xe9/255, alpha: 1)
    static let gutterText = NSColor(srgbRed: 0x6b/255, green: 0x78/255, blue: 0x86/255, alpha: 1)
    static let selection = NSColor(srgbRed: 0x3f/255, green: 0x4b/255, blue: 0x57/255, alpha: 1)
    static let insertionPoint = NSColor(srgbRed: 0xf9/255, green: 0xae/255, blue: 0x58/255, alpha: 1)
    static let defaultFontSize: CGFloat = 13
    static let fontSizeDefaultsKey = "MyGhostEditorFontSize"

    /// Current editor font size, persisted across launches.
    static var fontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: fontSizeDefaultsKey)
        return saved > 0 ? CGFloat(saved) : defaultFontSize
    }()

    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static let accent = Color(nsColor: insertionPoint)
    static let dimText = Color(nsColor: gutterText)
    static let brightText = Color(nsColor: text)
}

/// Manages the shared set of documents open in the in-window editor mode.
class TextEditorManager {
    static let shared = TextEditorManager()

    /// Shared editor state: open documents and the active selection.
    let state = EditorPanelState()

    /// Maximum file size we attempt to edit in-app (5 MB).
    private static let maxEditableSize = 5 * 1024 * 1024

    /// Numbering for the scratch buffers created by "New File".
    private var untitledCounter = 0

    /// Opens a file in the built-in editor. Returns true on success; returns
    /// false when the file is not editable text (then it is handed to the
    /// system default application instead).
    @discardableResult
    func openDocument(url: URL) -> Bool {
        let fileURL = url.standardizedFileURL

        if let existing = state.documents.first(where: { $0.url == fileURL }) {
            state.activeID = existing.id
            return true
        }

        // Only edit reasonably sized UTF-8 text files; anything else goes
        // to the system default application.
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maxEditableSize,
              let text = String(data: data, encoding: .utf8) else {
            NSWorkspace.shared.open(url)
            return false
        }

        adopt(EditorDocument(url: fileURL, text: text))
        return true
    }

    /// Creates an empty scratch buffer that has no file on disk yet. It only
    /// gets a path the first time it is saved (Cmd+S, or when closing it).
    @discardableResult
    func newDocument() -> EditorDocument {
        untitledCounter += 1
        let doc = EditorDocument(url: nil, text: "",
                                 untitledName: "untitled-\(untitledCounter)")
        adopt(doc)
        DispatchQueue.main.async {
            doc.textView.window?.makeFirstResponder(doc.textView)
        }
        return doc
    }

    /// Wires a freshly built document up and makes it the active tab.
    private func adopt(_ doc: EditorDocument) {
        doc.textView.onCloseTab = { [weak self, weak doc] in
            guard let doc = doc else { return }
            self?.closeDocument(doc)
        }
        state.documents.append(doc)
        state.activeID = doc.id
    }

    func select(_ doc: EditorDocument) {
        state.activeID = doc.id
        if state.isFindBarVisible { updateMatchStatus() }
        DispatchQueue.main.async {
            doc.textView.window?.makeFirstResponder(doc.textView)
        }
    }

    func closeDocument(_ doc: EditorDocument) {
        guard confirmCloseIfDirty(doc) else { return }
        state.documents.removeAll { $0.id == doc.id }
        if state.activeID == doc.id {
            state.activeID = state.documents.last?.id
        }
    }

    // MARK: Font size (Cmd+= / Cmd+- / Cmd+0)

    func adjustFontSize(by delta: CGFloat) {
        setFontSize(EditorTheme.fontSize + delta)
    }

    func resetFontSize() {
        setFontSize(EditorTheme.defaultFontSize)
    }

    private func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 8), 36)
        guard clamped != EditorTheme.fontSize else { return }
        EditorTheme.fontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: EditorTheme.fontSizeDefaultsKey)

        let font = EditorTheme.font
        for doc in state.documents {
            // Setting `font` on a plain-text NSTextView restyles all text.
            doc.textView.font = font
            var attrs = doc.textView.typingAttributes
            attrs[.font] = font
            doc.textView.typingAttributes = attrs
        }
    }

    /// Prompts to save a dirty document. Returns false if the user cancels.
    private func confirmCloseIfDirty(_ doc: EditorDocument) -> Bool {
        // An untouched scratch buffer has nothing worth asking about.
        guard doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(doc.name)\"?"
        alert.informativeText = doc.url == nil
            ? "This file has never been saved. Choose where to keep it, or discard it."
            : "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: doc.url == nil ? "Save As…" : "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Backing out of the save panel aborts the close too.
            return doc.save()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Find & replace (Cmd+F / Cmd+Opt+F)

    /// Reveals the find bar, optionally with the replace row, and seeds the
    /// search field from the current selection like Sublime does.
    func showFindBar(withReplace: Bool) {
        if let doc = state.activeDocument {
            let selection = doc.textView.selectedRange()
            if selection.length > 0, selection.length < 200 {
                let selected = (doc.textView.string as NSString).substring(with: selection)
                if !selected.contains("\n") { state.findText = selected }
            }
        }
        if withReplace { state.showsReplaceField = true }
        state.isFindBarVisible = true
        updateMatchStatus()
        // Bumping the token re-focuses the field even if the bar was already up.
        state.findFocusToken += 1
    }

    func hideFindBar() {
        state.isFindBarVisible = false
        state.showsReplaceField = false
        if let doc = state.activeDocument {
            doc.textView.window?.makeFirstResponder(doc.textView)
        }
    }

    /// Selects the next (or previous) match, wrapping around the document.
    func findNext(reverse: Bool = false) {
        guard let doc = state.activeDocument, !state.findText.isEmpty else {
            updateMatchStatus()
            return
        }
        let textView = doc.textView
        let haystack = textView.string as NSString
        let needle = state.findText as NSString
        guard haystack.length > 0, needle.length > 0 else {
            updateMatchStatus()
            return
        }

        var options: NSString.CompareOptions = state.matchCase ? [] : [.caseInsensitive]
        if reverse { options.insert(.backwards) }

        let selection = textView.selectedRange()
        let scoped: NSRange = reverse
            ? NSRange(location: 0, length: selection.location)
            : NSRange(location: NSMaxRange(selection),
                      length: haystack.length - NSMaxRange(selection))

        var found = scoped.length > 0
            ? haystack.range(of: needle as String, options: options, range: scoped)
            : NSRange(location: NSNotFound, length: 0)
        if found.location == NSNotFound {
            // Wrap around.
            found = haystack.range(of: needle as String, options: options,
                                   range: NSRange(location: 0, length: haystack.length))
        }
        guard found.location != NSNotFound else {
            updateMatchStatus()
            NSSound.beep()
            return
        }

        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        updateMatchStatus()
    }

    /// Replaces the currently selected match, then moves on to the next one.
    func replaceCurrent() {
        guard let doc = state.activeDocument, !state.findText.isEmpty else { return }
        let textView = doc.textView
        let selection = textView.selectedRange()
        let options: NSString.CompareOptions = state.matchCase ? [] : [.caseInsensitive]

        // Only replace when the selection really is the match we searched for;
        // otherwise this click just means "find the first one".
        if selection.length > 0 {
            let selected = (textView.string as NSString).substring(with: selection)
            if selected.compare(state.findText, options: options) == .orderedSame,
               textView.shouldChangeText(in: selection, replacementString: state.replaceText) {
                let styled = NSAttributedString(string: state.replaceText,
                                                attributes: textView.typingAttributes)
                textView.textStorage?.replaceCharacters(in: selection, with: styled)
                textView.didChangeText()
                textView.setSelectedRange(
                    NSRange(location: selection.location,
                            length: (state.replaceText as NSString).length))
            }
        }
        findNext()
    }

    /// Recomputes the "3 / 12" counter next to the find field.
    func updateMatchStatus() {
        guard let doc = state.activeDocument, !state.findText.isEmpty else {
            state.findStatus = ""
            return
        }
        let haystack = doc.textView.string as NSString
        let options: NSString.CompareOptions = state.matchCase ? [] : [.caseInsensitive]
        let selection = doc.textView.selectedRange()

        var total = 0
        var current = 0
        var cursor = 0
        while cursor < haystack.length {
            let hit = haystack.range(of: state.findText, options: options,
                                     range: NSRange(location: cursor,
                                                    length: haystack.length - cursor))
            guard hit.location != NSNotFound else { break }
            total += 1
            if NSEqualRanges(hit, selection) { current = total }
            cursor = hit.location + max(1, hit.length)
        }

        if total == 0 {
            state.findStatus = "No results"
        } else if current > 0 {
            state.findStatus = "\(current) / \(total)"
        } else {
            state.findStatus = "\(total) found"
        }
    }
}

/// One open file in the editor. Owns its own text view so undo history,
/// scroll position, and dirty state survive tab switches.
class EditorDocument: NSObject, ObservableObject, Identifiable, NSTextViewDelegate {
    let id = UUID()
    let scrollView = NSScrollView()
    let textView: EditorTextView

    /// Nil until a scratch buffer is saved somewhere for the first time.
    @Published var url: URL?
    @Published var isDirty = false

    /// Placeholder name shown while the document has no file on disk.
    private let untitledName: String

    var name: String { url?.lastPathComponent ?? untitledName }

    init(url: URL?, text: String, untitledName: String = "untitled") {
        self.url = url
        self.untitledName = untitledName
        self.textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 0))
        super.init()

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background

        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 8)

        textView.isRichText = false
        // We ship our own Sublime-style find bar along the bottom, so the
        // system one must stay out of the way of Cmd+F.
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = EditorTheme.font
        textView.typingAttributes = [
            .font: EditorTheme.font,
            .foregroundColor: EditorTheme.text,
        ]
        textView.backgroundColor = EditorTheme.background
        textView.textColor = EditorTheme.text
        textView.insertionPointColor = EditorTheme.insertionPoint
        textView.selectedTextAttributes = [.backgroundColor: EditorTheme.selection]

        textView.string = text
        textView.delegate = self
        textView.onSave = { [weak self] in _ = self?.save() }

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }

    /// Writes the document out, asking for a location first if it never had
    /// one. Returns false when the write failed or the user backed out.
    @discardableResult
    func save() -> Bool {
        guard let url = url else { return saveAs() }
        return write(to: url)
    }

    /// Asks for a destination and saves there, adopting it as the file's path.
    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save \(name)"
        panel.nameFieldStringValue = url?.lastPathComponent ?? "\(untitledName).txt"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let directory = url?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let target = panel.url else { return false }
        guard write(to: target) else { return false }
        url = target
        return true
    }

    private func write(to target: URL) -> Bool {
        do {
            try textView.string.write(to: target, atomically: true, encoding: .utf8)
            isDirty = false
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
        // Keep the find counter honest while the document is being edited.
        if TextEditorManager.shared.state.isFindBarVisible {
            TextEditorManager.shared.updateMatchStatus()
        }
    }
}

/// Observable list of open documents shared with the SwiftUI chrome.
class EditorPanelState: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var activeID: UUID?

    // Find & replace bar, shown along the bottom of the editor pane.
    @Published var isFindBarVisible = false
    @Published var showsReplaceField = false
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var matchCase = false
    @Published var findStatus = ""

    /// Incremented every time Cmd+F is pressed so the field takes focus again
    /// even when the bar is already on screen.
    @Published var findFocusToken = 0

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeID }
    }
}

// MARK: - Main-area editor pane (tab bar + path bar + text editor)

/// The editor pane shown in the main content area when the sidebar is in
/// editor mode — layout modeled after Sublime Text.
struct EditorMainPane: View {
    @ObservedObject var state: EditorPanelState

    var body: some View {
        VStack(spacing: 0) {
            EditorTabBar(
                state: state,
                onSelect: { TextEditorManager.shared.select($0) },
                onClose: { TextEditorManager.shared.closeDocument($0) }
            )
            EditorPathBar(state: state)
            Divider().overlay(Color.black.opacity(0.4))
            if state.documents.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("No open files")
                        .font(.system(size: 13))
                        .foregroundColor(EditorTheme.dimText)
                    Text("Right-click a file in the file browser and choose \"Edit\"")
                        .font(.system(size: 11))
                        .foregroundColor(EditorTheme.dimText.opacity(0.7))
                    Text("…or press + above the sidebar's open-files list for a new file")
                        .font(.system(size: 11))
                        .foregroundColor(EditorTheme.dimText.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                EditorAreaView(state: state)
                if state.isFindBarVisible {
                    EditorFindBar(state: state)
                }
            }
        }
        .background(Color(nsColor: EditorTheme.background))
    }
}

// MARK: - Sidebar open-files list (shown in the sidebar in editor mode)

/// Lists every open editor document by file name.
struct EditorSidebarList: View {
    @ObservedObject var state: EditorPanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("OPEN FILES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button {
                    TextEditorManager.shared.newDocument()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("New file — a scratch buffer you pick a path for when saving")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if state.documents.isEmpty {
                Text("No open files — press + for a new one")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.documents) { doc in
                        EditorSidebarRow(
                            doc: doc,
                            isActive: doc.id == state.activeID,
                            onSelect: { TextEditorManager.shared.select(doc) },
                            onClose: { TextEditorManager.shared.closeDocument(doc) }
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EditorSidebarRow: View {
    @ObservedObject var doc: EditorDocument
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(isActive ? .accentColor : .secondary)
            Text(doc.name)
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if doc.isDirty {
                Circle()
                    .fill(EditorTheme.accent)
                    .frame(width: 6, height: 6)
            }
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Save") { _ = doc.save() }
            Button("Save As…") { _ = doc.saveAs() }
            Button("Close") { onClose() }
            if let url = doc.url {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}

// MARK: - Tab bar

/// Top tab bar, one tab per open file.
private struct EditorTabBar: View {
    @ObservedObject var state: EditorPanelState
    let onSelect: (EditorDocument) -> Void
    let onClose: (EditorDocument) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(state.documents) { doc in
                    EditorTabItem(
                        doc: doc,
                        isActive: doc.id == state.activeID,
                        onSelect: { onSelect(doc) },
                        onClose: { onClose(doc) }
                    )
                }
            }
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: EditorTheme.tabBarBackground))
    }
}

private struct EditorTabItem: View {
    @ObservedObject var doc: EditorDocument
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(isActive ? EditorTheme.accent : EditorTheme.dimText)

            Text(doc.name)
                .font(.system(size: 12))
                .foregroundColor(isActive ? EditorTheme.brightText : EditorTheme.dimText)
                .lineLimit(1)

            Button(action: onClose) {
                if doc.isDirty && !isHoveringClose {
                    Circle()
                        .fill(EditorTheme.accent)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(EditorTheme.dimText)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
            .onHover { isHoveringClose = $0 }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            isActive
                ? Color(nsColor: EditorTheme.background)
                : Color(nsColor: EditorTheme.tabBarBackground)
        )
        .overlay(alignment: .top) {
            if isActive {
                Rectangle()
                    .fill(EditorTheme.accent)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Path bar

/// Shows the full path of the active file under the tab bar.
private struct EditorPathBar: View {
    @ObservedObject var state: EditorPanelState

    var body: some View {
        HStack(spacing: 0) {
            if let doc = state.activeDocument {
                EditorPathLabel(doc: doc)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Color(nsColor: EditorTheme.background))
    }
}

/// Observes the document itself so the path appears the moment an untitled
/// buffer is saved somewhere.
private struct EditorPathLabel: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        Text(doc.url?.path ?? "\(doc.name) — not saved yet")
            .font(.system(size: 11))
            .foregroundColor(EditorTheme.dimText)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - Find & replace bar

/// Sublime-style find/replace strip pinned to the bottom of the editor pane.
/// Cmd+F shows just the find row; Cmd+Opt+F adds the replace row.
private struct EditorFindBar: View {
    @ObservedObject var state: EditorPanelState

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case find, replace }

    private let labelWidth: CGFloat = 56
    private let buttonWidth: CGFloat = 86

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                caseToggle
                Text("Find:")
                    .font(.system(size: 11))
                    .foregroundColor(EditorTheme.dimText)
                    .frame(width: labelWidth, alignment: .trailing)
                TextField("", text: $state.findText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .find)
                    .onSubmit { TextEditorManager.shared.findNext() }
                    .onChange(of: state.findText) { _ in
                        TextEditorManager.shared.updateMatchStatus()
                    }
                Text(state.findStatus)
                    .font(.system(size: 10))
                    .foregroundColor(EditorTheme.dimText)
                    .frame(width: 64, alignment: .trailing)
                Button("Find") { TextEditorManager.shared.findNext() }
                    .frame(width: buttonWidth)
                closeButton
            }

            if state.showsReplaceField {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 22, height: 1)
                    Text("Replace:")
                        .font(.system(size: 11))
                        .foregroundColor(EditorTheme.dimText)
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("", text: $state.replaceText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .replace)
                        .onSubmit { TextEditorManager.shared.replaceCurrent() }
                    Color.clear.frame(width: 64, height: 1)
                    Button("Replace") { TextEditorManager.shared.replaceCurrent() }
                        .frame(width: buttonWidth)
                    // Keeps the two rows' fields aligned under the close button.
                    Color.clear.frame(width: 18, height: 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: EditorTheme.tabBarBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1)
        }
        .onAppear { focusFindField() }
        // Forcing a nil transition first makes Cmd+F pull focus back out of
        // the text view even when the bar was already on screen.
        .onChange(of: state.findFocusToken) { _ in
            focusedField = nil
            focusFindField()
        }
        .onExitCommand { TextEditorManager.shared.hideFindBar() }
    }

    private func focusFindField() {
        DispatchQueue.main.async { focusedField = .find }
    }

    private var caseToggle: some View {
        Button {
            state.matchCase.toggle()
            TextEditorManager.shared.updateMatchStatus()
        } label: {
            Text("Aa")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(state.matchCase
                              ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06))
                )
                .foregroundColor(state.matchCase ? EditorTheme.brightText : EditorTheme.dimText)
        }
        .buttonStyle(.plain)
        .help("Match case")
    }

    private var closeButton: some View {
        Button {
            TextEditorManager.shared.hideFindBar()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(EditorTheme.dimText)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help("Close find bar (Esc)")
    }
}

// MARK: - AppKit editor host

/// Hosts the active document's AppKit scroll view inside SwiftUI.
private struct EditorAreaView: NSViewRepresentable {
    @ObservedObject var state: EditorPanelState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let active = state.activeDocument
        let current = view.subviews.first as? NSScrollView
        guard current !== active?.scrollView else { return }

        view.subviews.forEach { $0.removeFromSuperview() }
        if let doc = active {
            doc.scrollView.frame = view.bounds
            doc.scrollView.autoresizingMask = [.width, .height]
            view.addSubview(doc.scrollView)
            DispatchQueue.main.async {
                doc.textView.window?.makeFirstResponder(doc.textView)
            }
        }
    }
}

/// NSTextView that handles Cmd+S (save), Cmd+W (close tab) and the
/// find/replace shortcuts.
class EditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCloseTab: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch chars {
            case "s":
                onSave?()
                return true
            case "f":
                TextEditorManager.shared.showFindBar(withReplace: false)
                return true
            case "g":
                TextEditorManager.shared.findNext()
                return true
            case "w":
                if let onCloseTab = onCloseTab {
                    onCloseTab()
                    return true
                }
            case "=", "+":
                TextEditorManager.shared.adjustFontSize(by: 1)
                return true
            case "-":
                TextEditorManager.shared.adjustFontSize(by: -1)
                return true
            case "0":
                TextEditorManager.shared.resetFontSize()
                return true
            default:
                break
            }
        } else if flags == [.command, .shift] {
            // Cmd+Shift+= is "+" on US layouts; treat like zoom in.
            switch chars {
            case "=", "+":
                TextEditorManager.shared.adjustFontSize(by: 1)
                return true
            case "-", "_":
                TextEditorManager.shared.adjustFontSize(by: -1)
                return true
            case "g":
                TextEditorManager.shared.findNext(reverse: true)
                return true
            default:
                break
            }
        } else if flags == [.command, .option], chars == "f" {
            TextEditorManager.shared.showFindBar(withReplace: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc closes the find bar rather than running text completion.
    override func cancelOperation(_ sender: Any?) {
        if TextEditorManager.shared.state.isFindBarVisible {
            TextEditorManager.shared.hideFindBar()
            return
        }
        super.cancelOperation(sender)
    }
}

/// A vertical ruler that draws line numbers for an NSTextView.
class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    /// Character indices at which each line starts. Rebuilt on text change.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        rebuildLineIndex()

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange),
            name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textDidChange(_ notification: Notification) {
        rebuildLineIndex()
        needsDisplay = true
    }

    @objc private func frameDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    private func rebuildLineIndex() {
        guard let textView = textView else { return }
        let text = textView.string as NSString
        var starts: [Int] = [0]
        var index = 0
        while index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            starts.append(index)
        }
        lineStarts = starts

        let digits = max(3, String(starts.count).count)
        let charWidth = ("8" as NSString).size(withAttributes: [.font: EditorTheme.gutterFont]).width
        ruleThickness = CGFloat(digits) * charWidth + 16
    }

    /// 1-based line number containing the given character index.
    private func lineNumber(forCharacterIndex index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        EditorTheme.gutterBackground.setFill()
        bounds.fill()

        let text = textView.string as NSString
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let relativePoint = convert(NSZeroPoint, from: textView)
        let insetY = textView.textContainerInset.height

        var charIndex = charRange.location
        var lineNumber = lineNumber(forCharacterIndex: charIndex)

        while charIndex < NSMaxRange(charRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: lineGlyphIndex, effectiveRange: nil)
            draw(lineNumber: lineNumber,
                 atY: fragmentRect.minY + relativePoint.y + insetY,
                 lineHeight: fragmentRect.height)
            charIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // The "extra line fragment" is the empty final line shown when the
        // text ends with a newline (or the document is empty).
        if NSMaxRange(charRange) >= text.length,
           text.length == 0 || text.hasSuffix("\n") {
            let extraRect = layoutManager.extraLineFragmentRect
            let height = extraRect.height > 0 ? extraRect.height
                : EditorTheme.font.boundingRectForFont.height
            draw(lineNumber: lineStarts.count,
                 atY: extraRect.minY + relativePoint.y + insetY,
                 lineHeight: height)
        }
    }

    private func draw(lineNumber: Int, atY y: CGFloat, lineHeight: CGFloat) {
        let label = NSAttributedString(
            string: String(lineNumber),
            attributes: [
                .font: EditorTheme.gutterFont,
                .foregroundColor: EditorTheme.gutterText,
            ])
        let size = label.size()
        let point = NSPoint(
            x: ruleThickness - size.width - 8,
            y: y + (lineHeight - size.height) / 2)
        label.draw(at: point)
    }
}
