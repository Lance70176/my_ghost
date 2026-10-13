import Foundation
import SwiftUI

/// One permission request held by ghost-agentd (`agentd/` in this repo),
/// waiting for someone to answer it here, on Telegram or on the phone page.
struct AgentPending: Decodable, Identifiable, Equatable {
    let id: String
    let project: String
    let sessionId: String
    let tmuxSession: String
    let tabTitle: String
    let toolName: String
    let summary: String
    let reason: String
    let level: Int
    let levelName: String
    let state: String
    let alwaysPattern: String?
    let canAlways: Bool
    let remaining: Int
    /// Taken into a discussion: never times out until someone decides.
    let discussing: Bool?

    var isConfirming: Bool { state == "confirming" }
    var isDiscussing: Bool { discussing ?? false }

    /// `remaining` ticks down on every poll; it alone isn't a change worth
    /// re-rendering the cards for.
    static func == (a: AgentPending, b: AgentPending) -> Bool {
        a.id == b.id && a.state == b.state && a.discussing == b.discussing
    }
    var isHighRisk: Bool { level >= 3 }
}

/// A Claude Code conversation the daemon has heard from through its hooks.
struct AgentSession: Decodable, Equatable {
    let sessionId: String
    let project: String
    let tmuxSession: String
    let tabTitle: String
    /// running | waiting | done | ended
    let status: String
}

/// One project registered with ghost-agentd, as the assistant list shows it.
struct AgentProject: Decodable, Identifiable, Equatable {
    let name: String
    let resident: Bool
    let tgReady: Bool
    let pending: Int
    let sessions: Int
    let waiting: Int
    let running: Int
    let lastActivity: Double

    var id: String { name }
    /// Requests outside every project.
    var isDefault: Bool { name == "_default" }
    var displayName: String { isDefault ? L("Other conversations") : name }
}

/// One line of a project's decisions.jsonl.
struct AgentDecisionRecord: Decodable, Identifiable, Equatable {
    let ts: Double
    let id: String
    let project: String
    let sessionId: String?
    let tmuxSession: String?
    let tab: String?
    let tool: String?
    let summary: String
    let level: String
    let reason: String?
    let state: String
    let by: String
    let alwaysAdded: String?
    let discussed: Bool?
    let denyMessage: String?

    var date: Date { Date(timeIntervalSince1970: ts) }
    var allowed: Bool { state == "allowed" }
    /// L0/L1 decisions made by the rules rather than a person.
    var byRule: Bool { by.hasPrefix("rule:") }
}

private struct AgentProjects: Decodable { let projects: [AgentProject] }
private struct AgentDecisions: Decodable { let decisions: [AgentDecisionRecord] }

private struct AgentState: Decodable {
    let version: Int
    let pending: [AgentPending]
    let sessions: [AgentSession]
}

/// Long-polls ghost-agentd for pending decisions and conversation status.
///
/// While this keeps polling, the daemon counts MyGhost as a place a decision
/// card can be shown; when the app quits it stops counting it after 90s, and
/// with no Telegram configured either, sessions fall back to asking in the
/// terminal instead of waiting on a card nobody can see.
@MainActor
final class AgentDaemonClient: ObservableObject {
    static let shared = AgentDaemonClient()

    @Published private(set) var pending: [AgentPending] = []
    /// Status per tmux session name (`myghost_…`), the key sidebar tabs know.
    @Published private(set) var statusByTmux: [String: String] = [:]
    @Published private(set) var online = false
    @Published private(set) var projects: [AgentProject] = []
    /// Bumped whenever the daemon's state changes, so open history lists know
    /// to reload.
    @Published private(set) var changeCount = 0

    var totalPending: Int { pending.count }

    private let base = URL(string: ProcessInfo.processInfo.environment["GHOST_AGENTD_URL"]
                           ?? "http://127.0.0.1:7788")!
    private var version = -1
    private var task: Task<Void, Never>?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 70
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.pollOnce()
                if !ok { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            }
        }
    }

    private func pollOnce() async -> Bool {
        var comps = URLComponents(url: base.appendingPathComponent("api/state"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "myghost"),
            URLQueryItem(name: "since", value: String(version)),
            URLQueryItem(name: "wait", value: "25"),
        ]
        do {
            let (data, resp) = try await session.data(from: comps.url!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let state = try Self.decoder.decode(AgentState.self, from: data)
            apply(state)
            return true
        } catch {
            if online || !pending.isEmpty || !statusByTmux.isEmpty {
                online = false
                pending = []
                statusByTmux = [:]
            }
            version = -1
            return false
        }
    }

    private func apply(_ state: AgentState) {
        online = true
        if state.version != version { changeCount += 1 }
        version = state.version
        Task { await refreshProjects() }
        if state.pending != pending { pending = state.pending }
        var map: [String: String] = [:]
        // The daemon lists newest first; let the newest conversation in a tab win.
        for s in state.sessions.reversed() where !s.tmuxSession.isEmpty && s.status != "ended" {
            map[s.tmuxSession] = s.status
        }
        if map != statusByTmux { statusByTmux = map }
    }

    func refreshProjects() async {
        guard let (data, _) = try? await session.data(from: base.appendingPathComponent("api/projects")),
              let list = try? Self.decoder.decode(AgentProjects.self, from: data) else { return }
        if list.projects != projects { projects = list.projects }
    }

    /// Newest first; nil project means every project.
    func decisions(project: String?, limit: Int = 300) async -> [AgentDecisionRecord] {
        var comps = URLComponents(url: base.appendingPathComponent("api/decisions"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let project { comps.queryItems?.append(URLQueryItem(name: "project", value: project)) }
        guard let (data, _) = try? await session.data(from: comps.url!),
              let list = try? Self.decoder.decode(AgentDecisions.self, from: data) else { return [] }
        return list.decisions
    }

    /// action: allow | deny | always | confirm | cancel | discuss. Returns the daemon's
    /// explanation when it refused (already handled, needs confirmation…).
    @discardableResult
    func decide(_ p: AgentPending, action: String, message: String = "") async -> String? {
        var req = URLRequest(url: base.appendingPathComponent("api/decisions/\(p.id)"))
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Ghost")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": action, "by": "myghost", "message": message,
        ])
        do {
            let (data, resp) = try await session.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 { return nil }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return obj?["message"] as? String ?? L("ghost-agentd refused the request")
        } catch {
            return L("ghost-agentd is not reachable")
        }
    }
}

/// The small "waiting for you / running / done" capsule on a sidebar row.
struct AgentStatusBadge: View {
    @ObservedObject private var client = AgentDaemonClient.shared
    let sessionName: String?

    var body: some View {
        if let name = sessionName, let status = client.statusByTmux[name] {
            switch status {
            case "waiting":
                badge(L("Needs you"), fg: .orange, bg: Color.orange.opacity(0.18))
                    .help(L("Claude is waiting for your decision or input"))
            case "running":
                badge(L("Running"), fg: .blue, bg: Color.blue.opacity(0.15))
            case "done":
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.green)
                    .help(L("Claude finished this turn"))
            default:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(bg))
            .fixedSize()
    }
}
