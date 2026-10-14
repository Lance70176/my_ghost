import AppKit

/// A conversation the project assistant dispatched (the commander pressed
/// 開工): a tmux session ghost-agentd opened on its host.
struct AgentDispatched: Decodable, Equatable {
    let id: String
    let project: String
    let title: String
    let tmux: String
}

/// Shows dispatched conversations as tabs: on the daemon's own Mac as local
/// tabs, on another Mac under that host. Each session is adopted once per
/// Mac — closing the tab is final — and adopting never takes the focus.
@MainActor
enum AgentDispatchAdopter {
    private static let defaultsKey = "AgentAdoptedSessions"

    static func adopt(_ items: [AgentDispatched], from client: AgentDaemonClient) {
        guard !items.isEmpty else { return }
        var seen = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        let before = seen
        let controllers = NSApp.windows.compactMap { $0.windowController as? SidebarTerminalController }
        for d in items {
            let mark = "\(client.hostKey)|\(d.tmux)"
            guard !seen.contains(mark) else { continue }
            // The name goes into shell commands and tmux targets.
            guard d.tmux.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { continue }
            if controllers.contains(where: { $0.hasSession(named: d.tmux) }) {
                seen.insert(mark)
                continue
            }
            let owner = controllers.first { c in c.hostTabs.contains { $0.key == client.hostKey } }
                ?? (client.isLocal ? controllers.first : nil)
            // That host isn't open in any window yet: try again on the next poll.
            guard let owner else { continue }
            owner.adoptTab(
                screenName: d.tmux,
                title: d.title,
                remoteTarget: client.target,
                remoteSSHOptions: client.sshOptions,
                remoteDisplayName: client.isLocal ? nil : client.hostName)
            seen.insert(mark)
        }
        if seen != before {
            UserDefaults.standard.set(Array(seen), forKey: defaultsKey)
        }
    }
}
