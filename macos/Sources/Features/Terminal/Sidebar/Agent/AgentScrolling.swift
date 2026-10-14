import SwiftUI

// MARK: - Following new messages

/// Where a conversation's content sits in its scroll view's viewport.
struct AgentScrollFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

extension View {
    /// Put on a conversation's stack of messages (inside the ScrollView), so
    /// AgentFollow can tell scrolling from the conversation growing.
    func agentScrollFrame() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: AgentScrollFrameKey.self, value: g.frame(in: .named(AgentFollow.space)))
        })
    }
}

/// Put last in a conversation's scroll content: what "to the end" scrolls to.
struct AgentScrollEndMarker: View {
    static let id = "agent-scroll-end"

    var body: some View {
        Color.clear.frame(height: 1).id(Self.id)
    }
}

/// Whether a conversation view should follow new messages. It follows while
/// you're at the bottom (or just sent something); reading further up, new
/// messages don't pull you down — they're counted for a "↓ N new" button.
///
/// Only scrolling up takes it off the bottom. A reply streaming in grows the
/// content past the viewport before the view catches up with it; judged on
/// where the end is alone, that read as "scrolled up" and it stopped
/// following. Scrolling up moves the content's top down; growing leaves the
/// top where it is, and following to the end moves it up.
@MainActor
final class AgentFollow: ObservableObject {
    static let space = "agent-scroll"

    @Published private(set) var atBottom = true
    @Published var unseen = 0
    /// Set when you send: the next message scrolls into view regardless.
    var followNext = false
    /// Where the content's top was: it moves when the view scrolls, not when
    /// the conversation grows.
    private var top: CGFloat?

    func frameMoved(_ frame: CGRect, viewport: CGFloat) {
        guard !frame.isNull else { return }
        let bottom = frame.maxY <= viewport + 48
        let scrolledUp = top.map { frame.minY > $0 + 0.5 } ?? false
        top = frame.minY
        if bottom {
            if !atBottom { atBottom = true }
            if unseen != 0 { unseen = 0 }
        } else if scrolledUp && atBottom {
            atBottom = false
        }
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

    /// To the end — and again once lazily laid-out rows have measured
    /// themselves: one jump lands on estimated heights, which in a long
    /// conversation leaves it short of the end.
    func toEnd(_ proxy: ScrollViewProxy, animated: Bool = false) {
        atBottom = true
        unseen = 0
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(AgentScrollEndMarker.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(AgentScrollEndMarker.id, anchor: .bottom)
        }
        for delay in [0.1, 0.3, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.atBottom else { return }
                proxy.scrollTo(AgentScrollEndMarker.id, anchor: .bottom)
            }
        }
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
