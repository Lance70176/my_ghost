import AppKit
import Combine

/// Whether the AI assistant (ghost-agentd) feature is on. Off by default: it
/// is an advanced feature most people won't set up, and while it is off
/// MyGhost neither polls the daemon nor opens ssh forwards for remote hosts,
/// and shows none of its UI (the ✦ sidebar mode, tab badges, decision cards).
/// Switched from the app menu; takes effect at once.
@MainActor
final class AgentFeature: ObservableObject {
    static let shared = AgentFeature()
    static let defaultsKey = "MyGhostAgentAssistantEnabled"

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    /// Called once at launch.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        isEnabled = on
        if on {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        AgentDecisionPanel.shared.start()
        AgentZoom.shared.start()
    }

    private func stop() {
        AgentDecisionPanel.shared.stop()
        AgentHub.shared.stop()
        // Windows showing the assistant go back to their terminals.
        for window in NSApp.windows {
            guard let controller = window.windowController as? SidebarTerminalController,
                  controller.sidebarUIState.sidebarMode == .assistant else { continue }
            controller.sidebarUIState.sidebarMode = .terminal
        }
    }
}
