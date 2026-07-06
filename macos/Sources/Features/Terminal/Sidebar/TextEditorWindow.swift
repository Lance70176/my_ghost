import AppKit

/// Sublime-inspired dark theme for the built-in text editor.
enum EditorTheme {
    static let background = NSColor(srgbRed: 0x30/255, green: 0x38/255, blue: 0x41/255, alpha: 1)
    static let gutterBackground = NSColor(srgbRed: 0x2b/255, green: 0x33/255, blue: 0x3b/255, alpha: 1)
    static let text = NSColor(srgbRed: 0xd8/255, green: 0xde/255, blue: 0xe9/255, alpha: 1)
    static let gutterText = NSColor(srgbRed: 0x6b/255, green: 0x78/255, blue: 0x86/255, alpha: 1)
    static let selection = NSColor(srgbRed: 0x3f/255, green: 0x4b/255, blue: 0x57/255, alpha: 1)
    static let insertionPoint = NSColor(srgbRed: 0xf9/255, green: 0xae/255, blue: 0x58/255, alpha: 1)
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}

/// Manages editor windows opened from the file browser, one per file.
/// Windows share a tabbing identifier so multiple files group as native tabs.
class TextEditorManager {
    static let shared = TextEditorManager()

    private var controllers: [URL: TextEditorWindowController] = [:]

    /// Maximum file size we attempt to edit in-app (5 MB).
    private static let maxEditableSize = 5 * 1024 * 1024

    func open(url: URL) {
        let key = url.standardizedFileURL

        if let existing = controllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // Only edit reasonably sized UTF-8 text files; anything else goes
        // to the system default application.
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.maxEditableSize,
              let text = String(data: data, encoding: .utf8) else {
            NSWorkspace.shared.open(url)
            return
        }

        let controller = TextEditorWindowController(url: url, text: text)
        controller.onClose = { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller

        // Group with an existing editor window as a tab, Sublime-style.
        if let host = controllers.values.first(where: { $0 !== controller })?.window,
           let newWindow = controller.window {
            host.addTabbedWindow(newWindow, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A window controller hosting a plain-text editor with a line number gutter.
class TextEditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let fileURL: URL
    var onClose: (() -> Void)?

    private var textView: EditorTextView!
    private var isDirty = false {
        didSet { window?.isDocumentEdited = isDirty }
    }

    init(url: URL, text: String) {
        self.fileURL = url

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.representedURL = url
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = EditorTheme.background
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "MyGhostTextEditor"
        window.center()
        window.setFrameAutosaveName("MyGhostTextEditor")

        super.init(window: window)
        window.delegate = self
        setupContent(text: text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupContent(text: String) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background

        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 920, height: 0))
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
        self.textView = textView

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        window?.contentView = scrollView
        window?.makeFirstResponder(textView)
    }

    func save() {
        guard let textView = textView else { return }
        do {
            try textView.string.write(to: fileURL, atomically: true, encoding: .utf8)
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

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(fileURL.lastPathComponent)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// NSTextView that handles Cmd+S to save.
class EditorTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
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
