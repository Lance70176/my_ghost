import AppKit
import SwiftUI

/// ⌘+ / ⌘- / ⌘0 for the AI assistant area, the way they size the terminal's
/// font. Only while the key window shows the assistant; otherwise the keys go
/// to the terminal as before. The scale is remembered across launches.
@MainActor
final class AgentZoom: ObservableObject {
    static let shared = AgentZoom()

    static let range: ClosedRange<CGFloat> = 0.7...2.2
    private static let step: CGFloat = 0.1
    private static let defaultsKey = "MyGhostAssistantZoom"

    @Published var scale: CGFloat {
        didSet { UserDefaults.standard.set(Double(scale), forKey: Self.defaultsKey) }
    }

    private var monitor: Any?

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.defaultsKey)
        scale = saved > 0 ? min(max(CGFloat(saved), Self.range.lowerBound), Self.range.upperBound) : 1
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { AgentZoom.shared.handle(event) } ? nil : event
        }
    }

    /// True when the event was a zoom key for a window showing the assistant.
    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), mods.isDisjoint(with: [.control, .option]) else { return false }
        guard let controller = NSApp.keyWindow?.windowController as? SidebarTerminalController,
              controller.sidebarUIState.sidebarMode == .assistant else { return false }
        switch event.charactersIgnoringModifiers {
        case "=", "+":
            set(scale + Self.step)
        case "-", "_":
            set(scale - Self.step)
        case "0":
            set(1)
        default:
            return false
        }
        return true
    }

    private func set(_ value: CGFloat) {
        let rounded = (value * 10).rounded() / 10
        scale = min(max(rounded, Self.range.lowerBound), Self.range.upperBound)
    }
}

private struct AgentZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Scale for text in the assistant area (1 elsewhere, e.g. the
    /// bottom-right cards).
    var agentZoom: CGFloat {
        get { self[AgentZoomKey.self] }
        set { self[AgentZoomKey.self] = newValue }
    }
}

/// A system font at a text style's macOS size times the assistant zoom.
private struct AgentFontModifier: ViewModifier {
    @Environment(\.agentZoom) private var zoom
    let style: Font.TextStyle?
    let size: CGFloat?
    let weight: Font.Weight?
    let design: Font.Design
    let monoDigits: Bool

    /// macOS point sizes of the text styles.
    private static func base(_ style: Font.TextStyle) -> (CGFloat, Font.Weight) {
        switch style {
        case .largeTitle: return (26, .regular)
        case .title: return (22, .regular)
        case .title2: return (17, .regular)
        case .title3: return (15, .regular)
        case .headline: return (13, .bold)
        case .subheadline: return (11, .regular)
        case .callout: return (12, .regular)
        case .footnote: return (10, .regular)
        case .caption: return (10, .regular)
        case .caption2: return (10, .regular)
        default: return (13, .regular)
        }
    }

    func body(content: Content) -> some View {
        let (baseSize, baseWeight) = style.map(Self.base) ?? (13, .regular)
        var font = Font.system(size: (size ?? baseSize) * zoom, weight: weight ?? baseWeight, design: design)
        if monoDigits { font = font.monospacedDigit() }
        return content.font(font)
    }
}

extension View {
    func agentFont(_ style: Font.TextStyle = .body, weight: Font.Weight? = nil,
                   design: Font.Design = .default, monoDigits: Bool = false) -> some View {
        modifier(AgentFontModifier(style: style, size: nil, weight: weight, design: design, monoDigits: monoDigits))
    }

    func agentFont(size: CGFloat, weight: Font.Weight? = nil) -> some View {
        modifier(AgentFontModifier(style: nil, size: size, weight: weight, design: .default, monoDigits: false))
    }
}
