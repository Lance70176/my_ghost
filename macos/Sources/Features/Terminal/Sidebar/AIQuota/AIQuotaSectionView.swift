import SwiftUI

/// The "AI Usage" section shown at the top of the sidebar: one row per
/// visible account with a usage bar per rate-limit window. Clicking a row
/// queries that account's quota; the arrow button refreshes all of them.
struct AIQuotaSectionView: View {
    @ObservedObject var manager: AIQuotaManager

    /// Opens the account settings sheet (owned by the sidebar).
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("AI Usage")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { manager.refreshAllVisible() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Refresh all accounts")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("AI usage settings")
            }

            ForEach(manager.visibleAccounts) { account in
                AIQuotaAccountRow(
                    account: account,
                    snapshot: manager.snapshots[account.id],
                    isRefreshing: manager.refreshing.contains(account.id),
                    onTap: { manager.refresh(account) })
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear { manager.refreshAllVisible() }
    }
}

/// One account's row: provider icon + name, then a compact bar per window.
private struct AIQuotaAccountRow: View {
    let account: AIQuotaAccount
    let snapshot: AIUsageSnapshot?
    let isRefreshing: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: account.provider.symbolName)
                    .font(.caption2)
                    .foregroundColor(account.provider == .claudeCode ? .orange : .green)
                    .frame(width: 12)

                Text(account.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else if snapshot?.isError == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                        .help(snapshot?.errorMessage ?? "")
                } else if snapshot == nil {
                    Text("Tap to check")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .help(rowHelp)

            if let snapshot, !snapshot.windows.isEmpty {
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 4) {
                        Text(window.label)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .leading)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.2))
                                Capsule()
                                    .fill(barColor(for: window.usedPercent))
                                    .frame(width: geo.size.width * window.usedPercent / 100)
                            }
                        }
                        .frame(height: 5)

                        Text("\(Int(window.usedPercent.rounded()))%")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .help(resetHelp(for: window))
                }
            } else if let error = snapshot?.errorMessage {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.secondary.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
    }

    private var rowHelp: String {
        var lines = ["\(account.provider.displayName) — click to check quota"]
        if let fetchedAt = snapshot?.fetchedAt {
            lines.append("Updated \(Self.timeFormatter.string(from: fetchedAt))")
        }
        return lines.joined(separator: "\n")
    }

    /// Tooltip for one window row: absolute reset time, remaining countdown,
    /// and when the numbers were last fetched.
    private func resetHelp(for window: AIUsageWindow) -> String {
        var lines: [String] = []
        if let resetsAt = window.resetsAt {
            lines.append("\(window.label): resets \(Self.dateTimeFormatter.string(from: resetsAt)) (\(remaining(until: resetsAt)))")
        } else {
            lines.append(window.label)
        }
        if let fetchedAt = snapshot?.fetchedAt {
            lines.append("Updated \(Self.timeFormatter.string(from: fetchedAt))")
        }
        return lines.joined(separator: "\n")
    }

    /// Human-readable time remaining, e.g. "in 2d 14h" / "in 1h 05m".
    private func remaining(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "resetting now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return String(format: "in %dh %02dm", hours, minutes) }
        return "in \(minutes)m"
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private func barColor(for percent: Double) -> Color {
        switch percent {
        case ..<50: return .green
        case ..<80: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }
}
