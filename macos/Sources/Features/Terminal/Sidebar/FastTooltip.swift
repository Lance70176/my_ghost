import AppKit
import SwiftUI

/// One coloured run of text inside a tooltip line.
struct FastTooltipSpan: Equatable {
    var text: String
    var color: NSColor?
    var bold: Bool = false

    init(_ text: String, color: NSColor? = nil, bold: Bool = false) {
        self.text = text
        self.color = color
        self.bold = bold
    }
}

/// A tooltip line, built from one or more coloured spans.
struct FastTooltipLine: Equatable {
    var spans: [FastTooltipSpan]

    init(_ spans: [FastTooltipSpan]) { self.spans = spans }
    init(_ text: String, color: NSColor? = nil, bold: Bool = false) {
        self.spans = [FastTooltipSpan(text, color: color, bold: bold)]
    }
}

/// A tooltip that appears almost immediately on hover.
///
/// SwiftUI's `.help()` maps to AppKit tooltips, whose ~1s initial delay is set
/// by the system and can't be shortened per view. Quota bars are scanned at a
/// glance, so they use this panel instead: a borderless, non-activating window
/// that shows after `delay` and never takes focus from the terminal.
final class FastTooltipPanel {
    static let shared = FastTooltipPanel()

    // Monospaced so the label/percent/time columns line up across lines.
    private static let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
    private static let padding = NSSize(width: 18, height: 13)

    private var panel: NSPanel?
    private var label: NSTextField?
    private var pending: DispatchWorkItem?
    /// Identifies the view that requested the current tooltip, so a hover-exit
    /// from a different row can't dismiss a tooltip that row didn't open.
    private var ownerID: UUID?

    private init() {}

    /// Show `lines` near the cursor after a short delay. Replaces any tooltip
    /// already scheduled or visible.
    func schedule(_ lines: [FastTooltipLine], owner: UUID, delay: TimeInterval = 0.1) {
        pending?.cancel()
        ownerID = owner
        let item = DispatchWorkItem { [weak self] in
            self?.show(lines)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Hide the tooltip if `owner` is the view that opened it.
    func cancel(owner: UUID) {
        guard ownerID == owner else { return }
        cancel()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        ownerID = nil
        panel?.orderOut(nil)
    }

    /// Refresh the text of an already-visible tooltip (countdowns tick while
    /// the pointer rests on a row).
    func update(_ lines: [FastTooltipLine], owner: UUID) {
        guard ownerID == owner, let panel, panel.isVisible else { return }
        show(lines, keepPosition: true)
    }

    private func show(_ lines: [FastTooltipLine], keepPosition: Bool = false) {
        let panel = self.panel ?? makePanel()
        guard let label else { return }

        let attributed = Self.attributedString(from: lines)
        label.attributedStringValue = attributed
        // Measure with an unbounded width: `NSAttributedString.size()` rounds
        // short enough that the last run wraps onto its own line.
        let unbounded = CGFloat.greatestFiniteMagnitude
        let bounds = attributed.boundingRect(
            with: NSSize(width: unbounded, height: unbounded),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Generous slack: an NSTextField drops a whole line when its frame is
        // even a point short, which silently swallowed the last row.
        let labelSize = NSSize(width: ceil(bounds.width) + 4, height: ceil(bounds.height) + 8)
        let size = NSSize(
            width: labelSize.width + Self.padding.width * 2,
            height: labelSize.height + Self.padding.height * 2)
        label.frame = NSRect(
            x: Self.padding.width, y: Self.padding.height,
            width: labelSize.width, height: labelSize.height)

        if keepPosition, panel.isVisible {
            // Grow from the existing top-left corner so a ticking countdown
            // doesn't make the panel jump.
            let top = panel.frame.maxY
            panel.setFrame(
                NSRect(x: panel.frame.origin.x, y: top - size.height,
                       width: size.width, height: size.height),
                display: true)
        } else {
            panel.setFrame(NSRect(origin: Self.origin(for: size), size: size), display: false)
        }
        // orderFrontRegardless keeps the terminal key — showing a tooltip must
        // never steal focus from the surface the user is typing into.
        panel.orderFrontRegardless()
    }

    /// Sit below-right of the pointer like a system tooltip, flipping when that
    /// would push the panel off the screen it is on.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height - 14)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.x + size.width > visible.maxX { origin.x = mouse.x - size.width - 14 }
            if origin.x < visible.minX { origin.x = visible.minX + 4 }
            if origin.y < visible.minY { origin.y = mouse.y + 22 }
        }
        return origin
    }

    private static func attributedString(from lines: [FastTooltipLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            for span in line.spans {
                result.append(NSAttributedString(string: span.text, attributes: [
                    .font: span.bold ? boldFont : font,
                    .foregroundColor: span.color ?? NSColor.labelColor,
                ]))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        result.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: result.length))
        return result
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        // A dark HUD background regardless of theme, so the status colours
        // (green/yellow/orange/red) stay legible.
        panel.appearance = NSAppearance(named: .vibrantDark)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        background.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.maximumNumberOfLines = 0
        label.drawsBackground = false
        label.isBezeled = false
        background.addSubview(label)

        panel.contentView = background
        self.panel = panel
        self.label = label
        return panel
    }
}

extension View {
    /// Like `.help()`, but shows after `delay` instead of the ~1s system delay,
    /// and supports coloured multi-line content.
    func fastHelp(_ lines: [FastTooltipLine], delay: TimeInterval = 0.1) -> some View {
        modifier(FastHelpModifier(lines: lines, delay: delay))
    }

    func fastHelp(_ text: String, delay: TimeInterval = 0.1) -> some View {
        modifier(FastHelpModifier(lines: [FastTooltipLine(text)], delay: delay))
    }
}

private struct FastHelpModifier: ViewModifier {
    let lines: [FastTooltipLine]
    let delay: TimeInterval

    /// Stable per-view identity so overlapping hover events stay paired.
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    FastTooltipPanel.shared.schedule(lines, owner: id, delay: delay)
                } else {
                    FastTooltipPanel.shared.cancel(owner: id)
                }
            }
            .onChange(of: lines) { newLines in
                FastTooltipPanel.shared.update(newLines, owner: id)
            }
            .onDisappear {
                FastTooltipPanel.shared.cancel(owner: id)
            }
    }
}
