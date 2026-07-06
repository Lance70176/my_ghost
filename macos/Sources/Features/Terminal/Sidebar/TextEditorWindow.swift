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

        let doc = EditorDocument(url: fileURL, text: text)
        doc.textView.onCloseTab = { [weak self, weak doc] in
            guard let doc = doc else { return }
            self?.closeDocument(doc)
        }
        state.documents.append(doc)
        state.activeID = doc.id
        return true
    }

    func select(_ doc: EditorDocument) {
        state.activeID = doc.id
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
        guard doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(doc.name)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            doc.save()
            return !doc.isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

/// One open file in the editor. Owns its own text view so undo history,
/// scroll position, and dirty state survive tab switches.
class EditorDocument: NSObject, ObservableObject, Identifiable, NSTextViewDelegate {
    let id = UUID()
    let url: URL
    let scrollView = NSScrollView()
    let textView: EditorTextView

    @Published var isDirty = false

    var name: String { url.lastPathComponent }

    init(url: URL, text: String) {
        self.url = url
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
        textView.usesFindBar = true
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
        textView.onSave = { [weak self] in self?.save() }

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }

    func save() {
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
    }
}

/// Observable list of open documents shared with the SwiftUI chrome.
class EditorPanelState: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var activeID: UUID?

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
                VStack {
                    Spacer()
                    Text("No open files")
                        .font(.system(size: 13))
                        .foregroundColor(EditorTheme.dimText)
                    Text("Right-click a file in the file browser and choose \"Edit\"")
                        .font(.system(size: 11))
                        .foregroundColor(EditorTheme.dimText.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                EditorAreaView(state: state)
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
            Text("OPEN FILES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if state.documents.isEmpty {
                Text("No open files")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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
            Button("Close") { onClose() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([doc.url])
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
            Text(state.activeDocument?.url.path ?? "")
                .font(.system(size: 11))
                .foregroundColor(EditorTheme.dimText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Color(nsColor: EditorTheme.background))
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

/// NSTextView that handles Cmd+S (save) and Cmd+W (close tab).
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
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
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
