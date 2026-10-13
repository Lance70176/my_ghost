import AppKit
import SwiftUI

// MARK: - Sidebar list (the ✦ AI assistant sidebar mode)

/// The assistant list shown when the sidebar is in `.assistant` mode: an
/// "All projects" row, then one row per project assistant — resident ones
/// first. Clicking a row opens that assistant's own window.
struct AgentAssistantSidebarList: View {
    @ObservedObject private var client = AgentDaemonClient.shared
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !client.online {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("ghost-agentd is not reachable"), systemImage: "bolt.horizontal.circle")
                            .font(.callout)
                            .foregroundColor(.orange)
                        Text(L("Install it with agentd/install.sh, then this list fills in."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                }

                Button { AgentAssistantWindows.open(project: nil) } label: {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                        Text(L("All projects")).fontWeight(.semibold)
                        Spacer()
                        if client.totalPending > 0 { CountBadge(count: client.totalPending) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.horizontal, 8)

                ForEach(client.projects) { p in
                    Button { AgentAssistantWindows.open(project: p.name) } label: {
                        AgentProjectRow(project: p)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .task { await client.refreshProjects() }
    }
}

private struct AgentProjectRow: View {
    let project: AgentProject

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: project.resident ? "sparkles" : "moon.zzz")
                    .foregroundColor(project.resident ? .accentColor : .secondary)
                    .font(.caption)
                Text(project.displayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if project.pending > 0 {
                    CountBadge(count: project.pending)
                } else if project.waiting > 0 {
                    Text(L("Needs you")).font(.caption2).foregroundColor(.orange)
                }
            }
            Text(statusLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var statusLine: String {
        let mode = project.resident ? L("Resident") : L("Wakes on events")
        if project.sessions == 0 { return mode }
        return mode + " · " + L("%d conversations", project.sessions)
            + (project.running > 0 ? " · " + L("%d running", project.running) : "")
    }
}

private struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange))
    }
}

// MARK: - Windows

/// One window per assistant (nil = the all-projects overview); opening an
/// assistant that already has a window brings that window forward.
@MainActor
enum AgentAssistantWindows {
    private static var windows: [String: NSWindow] = [:]

    static func open(project: String?) {
        let key = project ?? "*"
        if let win = windows[key] {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = AgentAssistantWindowView(project: project)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = project.map { L("AI Assistant · %@", $0 == "_default" ? L("Other conversations") : $0) }
            ?? L("AI Assistants · All projects")
        win.contentView = NSHostingView(rootView: root)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("MyGhostAssistant-\(key)")
        if !win.setFrameUsingName("MyGhostAssistant-\(key)") { win.center() }
        windows[key] = win
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
            Task { @MainActor in windows[key] = nil }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Assistant window: the conversation (or, for all projects, the overview)
/// in the middle, pending decisions and the decision history on the right.
private struct AgentAssistantWindowView: View {
    let project: String?
    @ObservedObject private var client = AgentDaemonClient.shared
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HSplitView {
            Group {
                if let project {
                    AgentConversationPlaceholder(project: project)
                } else {
                    AgentOverview()
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            AgentRightColumn(project: project)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 440)
    }
}

// MARK: - Middle: conversation (P2) / overview

/// The conversation pane. The assistant itself arrives in P2; until then this
/// says so and shows what the project's conversations are doing.
private struct AgentConversationPlaceholder: View {
    let project: String
    @ObservedObject private var client = AgentDaemonClient.shared

    private var info: AgentProject? { client.projects.first { $0.name == project } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.title2).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("%@ assistant", project == "_default" ? L("Other conversations") : project))
                        .font(.title3.weight(.semibold))
                    Text(info?.resident == true ? L("Resident") : L("Wakes on events"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("The assistant conversation arrives with phase 2"), systemImage: "hourglass")
                        .font(.callout.weight(.semibold))
                    Text(L("Once the Opus 5.5 assistant runs for this project you'll talk to it here, its multiple-choice questions become buttons, and Discuss brings a pending decision into the conversation. Until then the decisions on the right already work."))
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let info {
                HStack(spacing: 18) {
                    StatTile(value: info.pending, label: L("Pending decisions"), tint: .orange)
                    StatTile(value: info.waiting, label: L("Waiting for you"), tint: .orange)
                    StatTile(value: info.running, label: L("Running"), tint: .blue)
                    StatTile(value: info.sessions, label: L("Conversations"), tint: .secondary)
                }
            }
            Spacer()
        }
        .padding(18)
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold)).foregroundColor(value > 0 ? tint : .secondary)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }
}

/// Every project at a glance; a row opens that project's assistant.
private struct AgentOverview: View {
    @ObservedObject private var client = AgentDaemonClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("All projects")).font(.title3.weight(.semibold))
            Table(client.projects) {
                TableColumn(L("Project")) { p in
                    HStack(spacing: 6) {
                        Image(systemName: p.resident ? "sparkles" : "moon.zzz")
                            .foregroundColor(p.resident ? .accentColor : .secondary)
                        Text(p.displayName).fontWeight(.semibold)
                    }
                }
                TableColumn(L("Assistant")) { p in
                    Text(p.resident ? L("Resident") : L("Wakes on events")).foregroundColor(.secondary)
                }
                TableColumn(L("Pending")) { p in
                    Text("\(p.pending)").foregroundColor(p.pending > 0 ? .orange : .secondary)
                }
                .width(60)
                TableColumn(L("Conversations")) { p in
                    Text(L("%d · %d running · %d waiting", p.sessions, p.running, p.waiting))
                        .foregroundColor(.secondary)
                }
                TableColumn(L("Telegram")) { p in
                    Text(p.tgReady ? L("Connected") : L("Not set up"))
                        .foregroundColor(p.tgReady ? .green : .secondary)
                }
                .width(90)
                TableColumn("") { p in
                    Button(L("Open")) { AgentAssistantWindows.open(project: p.name) }
                        .controlSize(.small)
                }
                .width(60)
            }
        }
        .padding(18)
    }
}

// MARK: - Right column: pending decisions + history

private struct AgentRightColumn: View {
    let project: String?
    @ObservedObject private var client = AgentDaemonClient.shared

    private var pending: [AgentPending] {
        client.pending.filter { project == nil || $0.project == project }
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: L("Pending decisions"), count: pending.count)
                if pending.isEmpty {
                    Text(L("Nothing waiting for you."))
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(pending) { p in
                                AgentDecisionCard(p: p, width: 320)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
            }
            .padding(10)
            .frame(minHeight: 160)

            AgentHistoryList(project: project)
                .frame(minHeight: 160)
        }
    }
}

private struct SectionTitle: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack {
            Text(title).font(.headline)
            if let count, count > 0 { CountBadge(count: count) }
            Spacer()
        }
    }
}

/// Decision history, newest first, with a jump to the conversation each
/// request came from — or a note that it has been closed.
private struct AgentHistoryList: View {
    let project: String?
    @ObservedObject private var client = AgentDaemonClient.shared
    @State private var records: [AgentDecisionRecord] = []
    @State private var showRules = false
    @State private var closed: Set<String> = []
    @State private var expanded: Set<String> = []

    private var shown: [AgentDecisionRecord] {
        showRules ? records : records.filter { !$0.byRule }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: L("Decision history"))
                Toggle(L("Show automatic"), isOn: $showRules)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help(L("Also list the L0/L1 requests the rules allowed by themselves"))
            }
            if shown.isEmpty {
                Text(L("No decisions yet."))
                    .font(.callout).foregroundColor(.secondary)
                Spacer(minLength: 0)
            } else {
                List(shown) { r in
                    AgentHistoryRow(
                        record: r, showProject: project == nil,
                        isClosed: closed.contains(r.id),
                        isExpanded: expanded.contains(r.id) || closed.contains(r.id),
                        onJump: {
                            if AgentDecisionPanel.reveal(tmuxSession: r.tmuxSession ?? "") {
                                closed.remove(r.id)
                            } else {
                                closed.insert(r.id)
                            }
                        },
                        onToggle: {
                            if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
                        })
                }
                .listStyle(.inset)
            }
        }
        .padding(10)
        .task(id: client.changeCount) {
            records = await client.decisions(project: project)
        }
    }
}

private struct AgentHistoryRow: View {
    let record: AgentDecisionRecord
    let showProject: Bool
    let isClosed: Bool
    let isExpanded: Bool
    let onJump: () -> Void
    let onToggle: () -> Void

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private var icon: (String, Color) {
        switch record.state {
        case "allowed": return ("checkmark.circle.fill", .green)
        case "expired": return ("clock.badge.xmark", .secondary)
        default: return ("xmark.circle.fill", .red)
        }
    }

    private var source: String {
        switch record.by {
        case "tg": return "TG"
        case "myghost": return "MyGhost"
        case "web": return L("Phone page")
        case "timeout": return L("Timed out")
        default: return record.byRule ? L("Rule %@", record.level) : record.by
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon.0).foregroundColor(icon.1)
                Text(Self.time.string(from: record.date))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                Text(record.level).font(.caption.weight(.bold)).foregroundColor(.secondary)
                if showProject {
                    Text(record.project).font(.caption).foregroundColor(.accentColor)
                }
                Spacer()
                Button(action: onJump) {
                    Label(record.tab?.isEmpty == false ? record.tab! : L("Conversation"),
                          systemImage: "arrow.up.forward.square")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(L("Show the conversation this request came from"))
                .disabled((record.tmuxSession ?? "").isEmpty)
            }
            Text(record.summary)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.middle)
                .onTapGesture(perform: onToggle)
            if isClosed {
                Label(L("That conversation has been closed; it can't be shown."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let reason = record.reason { Text(reason) }
                    Text(L("Decided by %@", source))
                    if let msg = record.denyMessage, !msg.isEmpty { Text(msg) }
                    if let rule = record.alwaysAdded { Text(L("Always allow in this project: %@", rule)) }
                    if record.discussed == true { Text(L("Was discussed before deciding")) }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
