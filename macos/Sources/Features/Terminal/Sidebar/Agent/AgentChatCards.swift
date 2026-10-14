import SwiftUI

/// A card the assistant raised in its conversation — a question, a drafted
/// reply, proposed work — shown as one block: live with its buttons while it
/// waits, afterwards with the draft and what became of it ("你選了…",
/// "已用 @SnakeFQ 回覆…"), which the daemon ties to the card.
struct AgentChatCard: View {
    let item: AgentChatItem
    /// The notices about this card, folded in rather than loose in the stream.
    let outcomes: [AgentChatItem]
    @EnvironmentObject private var client: AgentDaemonClient

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var accent: Color {
        if item.reply != nil { return .orange }
        if item.dispatch != nil { return .green }
        return .accentColor
    }

    var body: some View {
        Group {
            if let p = client.pending.first(where: { $0.id == item.choiceId }) {
                AgentDecisionCard(p: p, width: nil)
            } else {
                decided
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var decided: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).foregroundColor(accent)
                Text(title)
                    .agentFont(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(Self.time.string(from: Date(timeIntervalSince1970: item.ts)))
                    .agentFont(.caption).foregroundColor(.secondary)
            }
            content
            Divider()
            outcome
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accent.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.45), lineWidth: 1))
        )
    }

    private var icon: String {
        if item.reply != nil { return "paperplane.circle.fill" }
        if item.dispatch != nil { return "hammer.circle.fill" }
        return "questionmark.bubble.fill"
    }

    private var title: String {
        if let r = item.reply {
            return L("Reply to %@ as %@", r.isPrivate == false ? r.chat : r.sender, r.account)
        }
        if let d = item.dispatch {
            return L("Start work: %@", d.title ?? "")
        }
        return L("The assistant asked")
    }

    @ViewBuilder
    private var content: some View {
        if let r = item.reply {
            if let original = r.original, !original.isEmpty {
                block(caption: r.isPrivate == false ? L("%@ in %@ wrote", r.sender, r.chat) : L("%@ wrote", r.sender),
                      text: original, tint: .primary)
            }
            block(caption: L("Reply draft"), text: r.text, tint: .orange)
        } else if let d = item.dispatch, let task = d.task {
            if let repo = d.repo, let branch = d.branch {
                Label("\((repo as NSString).lastPathComponent) / \(branch)", systemImage: "arrow.triangle.branch")
                    .agentFont(.caption, design: .monospaced).foregroundColor(.secondary)
            }
            block(caption: L("Task"), text: task, tint: .green)
        } else {
            Text(LocalizedStringKey(item.text))
                .agentFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func block(caption: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).agentFont(.caption, weight: .semibold)
                .foregroundColor(tint == .primary ? .secondary : tint)
            Text(text)
                .agentFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(tint == .primary ? 0.06 : 0.12)))
        }
    }

    /// What was chosen and what happened; older cards (before the daemon tied
    /// notices to them) only know they were answered.
    @ViewBuilder
    private var outcome: some View {
        if outcomes.isEmpty {
            Label(item.chosen.isEmpty ? L("Answered") : L("You chose: %@", item.chosen),
                  systemImage: "checkmark.circle")
                .agentFont(.caption).foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outcomes) { n in
                    let failed = n.text.hasPrefix("⚠️")
                    let done = n.text.hasPrefix("已用") || n.text.hasPrefix("🚀")
                    Label(n.text, systemImage: failed ? "exclamationmark.triangle.fill"
                          : done ? "checkmark.seal.fill" : "hand.tap.fill")
                        .agentFont(.callout, weight: done || failed ? .semibold : .regular)
                        .foregroundColor(failed ? .orange : done ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
