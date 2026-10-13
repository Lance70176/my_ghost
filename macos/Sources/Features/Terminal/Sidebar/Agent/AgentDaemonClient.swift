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

    var isConfirming: Bool { state == "confirming" }

    /// `remaining` ticks down on every poll; it alone isn't a change worth
    /// re-rendering the cards for.
    static func == (a: AgentPending, b: AgentPending) -> Bool {
        a.id == b.id && a.state == b.state
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
        version = state.version
        if state.pending != pending { pending = state.pending }
        var map: [String: String] = [:]
        // The daemon lists newest first; let the newest conversation in a tab win.
        for s in state.sessions.reversed() where !s.tmuxSession.isEmpty && s.status != "ended" {
            map[s.tmuxSession] = s.status
        }
        if map != statusByTmux { statusByTmux = map }
    }

    /// action: allow | deny | always | confirm | cancel. Returns the daemon's
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
