import SwiftUI

// MARK: - Following new messages

/// Where a conversation's end marker sits in its scroll view's viewport.
struct AgentScrollEndKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// Put last in a conversation's scroll content; reports how far below the
/// viewport's top the end is (infinity when it isn't laid out at all).
struct AgentScrollEndMarker: View {
    static let id = "agent-scroll-end"

    var body: some View {
        Color.clear
            .frame(height: 1)
            .background(GeometryReader { g in
                Color.clear.preference(key: AgentScrollEndKey.self,
                                       value: g.frame(in: .named(AgentFollow.space)).maxY)
            })
            .id(Self.id)
    }
}

extension ScrollViewProxy {
    /// To a conversation's end — and again once the lazily laid-out rows have
    /// measured themselves: one jump lands on estimated heights, which in a
    /// long conversation leaves it far short of the end (near the top).
    func settleAtEnd() {
        for delay in [0.0, 0.1, 0.3, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                scrollTo(AgentScrollEndMarker.id, anchor: .bottom)
            }
        }
    }
}

/// Whether a conversation view should follow new messages. It follows only
/// while you're at the bottom (or just sent something); reading further up,
/// new messages don't pull you down — they're counted for a "↓ N new" button.
@MainActor
final class AgentFollow: ObservableObject {
    static let space = "agent-scroll"

    @Published private(set) var atBottom = true
    @Published var unseen = 0
    /// Set when you send: the next message scrolls into view regardless.
    var followNext = false

    func endMoved(to y: CGFloat, viewport: CGFloat) {
        let bottom = y <= viewport + 48
        if bottom != atBottom { atBottom = bottom }
        if bottom && unseen != 0 { unseen = 0 }
    }

    /// A new message arrived: scroll (returns true) or count it.
    func shouldFollow() -> Bool {
        if atBottom || followNext {
            followNext = false
            return true
        }
        unseen += 1
        return false
    }
}

/// The "↓ N new messages" button shown while reading further up.
struct AgentNewMessagesButton: View {
    @ObservedObject var follow: AgentFollow
    let jump: () -> Void

    var body: some View {
        if follow.unseen > 0 {
            Button(action: jump) {
                Label(L("%d new messages", follow.unseen), systemImage: "arrow.down.circle.fill")
                    .agentFont(.callout, weight: .semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .transition(.opacity)
        }
    }
}

// MARK: - Drafts and tabs that survive navigation

/// Unsent text and the chosen tab, per host / project / conversation, so
/// visiting another project or the terminal and coming back loses nothing.
/// Not observed by any view: views read it when they appear and write on
/// change, so typing doesn't re-render the window.
@MainActor
final class AgentDraftStore {
    static let shared = AgentDraftStore()
    private var drafts: [String: String] = [:]
    private var flags: [String: Bool] = [:]

    func draft(_ key: String) -> String { drafts[key] ?? "" }
    func setDraft(_ key: String, _ text: String) { drafts[key] = text.isEmpty ? nil : text }
    func flag(_ key: String) -> Bool { flags[key] ?? false }
    func setFlag(_ key: String, _ value: Bool) { flags[key] = value }
}
