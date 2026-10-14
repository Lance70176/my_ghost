import AppKit
import SwiftUI

// MARK: - Navigation

/// Shows an assistant in the main window: switches the sidebar to the ✦ mode
/// and puts that assistant (nil = the all-projects overview) where the
/// terminal was.
@MainActor
enum AgentAssistantNav {
    static func show(project: String?, hostKey: String) {
        let windows = NSApp.orderedWindows.filter { $0.windowController is SidebarTerminalController }
        // Prefer a window that has this host open.
        let withHost = windows.first { w in
            (w.windowController as? SidebarTerminalController)?.hostTabs.contains { $0.key == hostKey } ?? false
        }
        guard let window = withHost ?? windows.first(where: \.isKeyWindow) ?? windows.first,
              let controller = window.windowController as? SidebarTerminalController else { return }
        if let host = controller.hostTabs.first(where: { $0.key == hostKey }) {
            controller.selectHost(host)
        }
        controller.sidebarUIState.assistantProject = project
        controller.sidebarUIState.sidebarMode = .assistant
        if controller.sidebarUIState.isSidebarCollapsed {
            controller.sidebarUIState.isSidebarCollapsed = false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Sidebar list (the ✦ AI assistant sidebar mode)

/// The assistant list shown when the sidebar is in `.assistant` mode: an
/// "All projects" row, then one row per project assistant — resident ones
/// first. Clicking a row shows it in the main area.
struct AgentAssistantSidebarList: View {
    @ObservedObject var uiState: SidebarUIState
    @ObservedObject var controller: SidebarTerminalController

    var body: some View {
        let client = AgentHub.shared.client(for: controller.currentHost)
        AgentAssistantSidebarContent(uiState: uiState, client: client)
            .id(client.hostKey)
    }
}

private struct AgentAssistantSidebarContent: View {
    @ObservedObject var uiState: SidebarUIState
    @ObservedObject var client: AgentDaemonClient
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Label(client.hostName, systemImage: client.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                if !client.online {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(client.isLocal ? L("ghost-agentd isn't running on this Mac")
                                             : L("Can't reach ghost-agentd on %@", client.hostName),
                              systemImage: "bolt.horizontal.circle")
                            .font(.callout)
                            .foregroundColor(.orange)
                        Text(client.isLocal ? L("Install it with agentd/install.sh, then this list fills in.")
                                            : L("It's reached over SSH; install it on that host with agentd/install.sh."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                }

                row(selected: uiState.assistantProject == nil) {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                        Text(L("All projects")).fontWeight(.semibold)
                        Spacer()
                        if client.totalPending > 0 { CountBadge(count: client.totalPending) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                } action: { uiState.assistantProject = nil }

                Divider().padding(.horizontal, 8)

                ForEach(client.projects) { p in
                    row(selected: uiState.assistantProject == p.name) {
                        AgentProjectRow(project: p, assistant: client.assistants[p.name])
                    } action: { uiState.assistantProject = p.name }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .task { await client.refreshProjects() }
    }

    private func row<Content: View>(selected: Bool, @ViewBuilder content: () -> Content,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

private struct AgentProjectRow: View {
    let project: AgentProject
    let assistant: AgentAssistantStatus?

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
                } else if assistant?.busy == true {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(statusLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var statusLine: String {
        var parts = [project.resident ? L("Resident") : L("Wakes on events")]
        if let a = assistant {
            parts.append(a.busy ? L("Replying…") : (a.running ? L("Ready") : L("Asleep")))
        }
        if project.sessions > 0 { parts.append(L("%d conversations", project.sessions)) }
        return parts.joined(separator: " · ")
    }
}

struct CountBadge: View {
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

// MARK: - Main area

/// What replaces the terminal in `.assistant` mode: the conversation (or the
/// overview) in the middle, pending decisions and history on the right.
struct AgentAssistantMainView: View {
    @ObservedObject var uiState: SidebarUIState
    @ObservedObject var controller: SidebarTerminalController

    var body: some View {
        let client = AgentHub.shared.client(for: controller.currentHost)
        AgentAssistantMainContent(uiState: uiState)
            .environmentObject(client)
            .id(client.hostKey)
            .onChange(of: client.hostKey) { _ in
                // Another host has other projects; start from its overview.
                uiState.assistantProject = nil
            }
    }
}

private struct AgentAssistantMainContent: View {
    @ObservedObject var uiState: SidebarUIState
    @EnvironmentObject private var client: AgentDaemonClient

    var body: some View {
        HSplitView {
            Group {
                if let project = uiState.assistantProject {
                    AgentChatView(project: project, client: client)
                        .id(project)
                } else {
                    AgentOverview(uiState: uiState)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            AgentRightColumn(project: uiState.assistantProject)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)
        }
    }
}

// MARK: - Conversation

/// Long-polls one assistant's chat while its view is on screen.
@MainActor
final class AgentChatModel: ObservableObject {
    let project: String
    let client: AgentDaemonClient
    @Published private(set) var items: [AgentChatItem] = []
    @Published private(set) var partial = ""
    @Published private(set) var status: AgentAssistantStatus?
    @Published var error: String?
    private var task: Task<Void, Never>?

    init(project: String, client: AgentDaemonClient) {
        self.project = project
        self.client = client
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var since = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let chunk = await self.client.chat(project: self.project, since: since, wait: 25) {
                    if !chunk.items.isEmpty {
                        self.items.append(contentsOf: chunk.items)
                        if self.items.count > 600 { self.items.removeFirst(self.items.count - 600) }
                        since = chunk.items.last!.seq
                    }
                    if chunk.partial != self.partial { self.partial = chunk.partial }
                    if chunk.status != self.status { self.status = chunk.status }
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func send(_ text: String) {
        Task {
            error = await client.sendMessage(project: project, text: text)
        }
    }

    func interrupt() {
        Task { await client.stopAssistant(project: project) }
    }
}

struct AgentChatView: View {
    let project: String
    @StateObject private var model: AgentChatModel
    @ObservedObject private var lang = LanguageManager.shared
    @State private var draft = ""
    @State private var showTools = false
    @FocusState private var inputFocused: Bool

    init(project: String, client: AgentDaemonClient) {
        self.project = project
        _model = StateObject(wrappedValue: AgentChatModel(project: project, client: client))
    }

    private var visible: [AgentChatItem] {
        model.items.filter { item in
            if item.role == "tool" {
                // Claude Code loading its own tools isn't worth a line.
                return showTools && !item.text.hasPrefix("ToolSearch")
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.items.isEmpty {
                            emptyHint
                        }
                        ForEach(visible) { item in
                            AgentChatRow(item: item, project: project)
                                .id(item.seq)
                        }
                        if !model.partial.isEmpty {
                            AgentBubble(text: model.partial, mine: false, streaming: true)
                                .id(Int.max)
                        } else if model.status?.busy == true {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L("Thinking…")).font(.caption).foregroundColor(.secondary)
                            }
                            .id(Int.max)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: model.items.count) { _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(model.items.last?.seq, anchor: .bottom) }
                }
                .onChange(of: model.partial) { _ in proxy.scrollTo(Int.max, anchor: .bottom) }
                .onAppear { proxy.scrollTo(model.items.last?.seq, anchor: .bottom) }
            }
            Divider()
            input
        }
        .onAppear {
            model.start()
            inputFocused = true
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(.accentColor)
            Text(L("%@ assistant", project == "_default" ? L("Other conversations") : project))
                .font(.headline)
            if let s = model.status {
                Text(s.resident ? L("Resident") : L("Wakes on events"))
                    .font(.caption).foregroundColor(.secondary)
                Text(s.busy ? L("Replying…") : (s.running ? L("Ready") : L("Asleep")))
                    .font(.caption)
                    .foregroundColor(s.busy ? .orange : (s.running ? .green : .secondary))
            }
            Spacer()
            Toggle(L("Show tool calls"), isOn: $showTools)
                .toggleStyle(.checkbox)
                .font(.caption)
            if let s = model.status {
                if let pct = s.contextPct {
                    Text(L("Context %d%%", pct)).font(.caption.monospacedDigit())
                        .foregroundColor(pct >= 80 ? .orange : .secondary)
                }
                Text(L("Woken %d× today", s.wakesToday)).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Ask this project's assistant anything — e.g. \"What's still unfinished?\""))
                .font(.callout)
            Text(L("Replies also go to the project's Telegram group, and what you say there shows up here."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 20)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(L("Message the %@ assistant… (Return sends, ⇧Return for a new line)", project))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    AgentInputField(text: $draft, onSubmit: submit)
                        .focused($inputFocused)
                        .frame(minHeight: 34, maxHeight: 140)
                }
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))

                if model.status?.busy == true {
                    Button { model.interrupt() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help(L("Stop this reply"))
                }
                Button(action: submit) {
                    Image(systemName: "paperplane.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(L("Send"))
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
        .padding(10)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text)
    }
}

/// A multi-line text field where Return sends and Shift-Return breaks the line.
private struct AgentInputField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 8)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.string != text { tv.string = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentInputField
        init(_ parent: AgentInputField) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Composing with an input method: Return confirms the candidate.
            if tv.hasMarkedText() { return false }
            if NSEvent.modifierFlags.contains(.shift) {
                tv.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }
    }
}

private struct AgentChatRow: View {
    let item: AgentChatItem
    let project: String
    @EnvironmentObject private var client: AgentDaemonClient

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        switch item.role {
        case "user":
            VStack(alignment: .trailing, spacing: 2) {
                if item.source == "tg" || item.source == "web" {
                    Text(item.source == "tg" ? L("From Telegram") : L("From the phone page"))
                        .font(.caption2).foregroundColor(.blue)
                }
                AgentBubble(text: item.text, mine: true)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case "assistant":
            AgentBubble(text: item.text, mine: false)
        case "tool":
            Label(item.text, systemImage: "wrench.and.screwdriver")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case "choice":
            VStack(alignment: .leading, spacing: 6) {
                Label(item.text, systemImage: "questionmark.bubble.fill")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !item.chosen.isEmpty {
                    Text(L("You chose: %@", item.chosen)).font(.caption).foregroundColor(.secondary)
                } else if client.pending.contains(where: { $0.id == item.choiceId }) {
                    AgentChoiceButtons(choiceId: item.choiceId, options: item.options,
                                       busy: .constant(false), error: .constant(nil))
                } else {
                    Text(L("Answered")).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.6)))
        case "discuss":
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Discussing this request"), systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.semibold)).foregroundColor(.blue)
                Text(item.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if let card = client.pending.first(where: { $0.id == item.cardId }) {
                    AgentDecisionCard(p: card, width: 460)
                } else {
                    Text(L("Already decided")).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.08)))
        default:  // notice
            Text(item.text)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct AgentBubble: View {
    let text: String
    let mine: Bool
    var streaming = false

    var body: some View {
        Text(LocalizedStringKey(text))
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(mine ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(alignment: .bottomTrailing) {
                if streaming {
                    ProgressView().controlSize(.mini).padding(4)
                }
            }
            .frame(maxWidth: 620, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

/// The option buttons of an assistant's question.
struct AgentChoiceButtons: View {
    @EnvironmentObject private var client: AgentDaemonClient
    let choiceId: String
    let options: [AgentChoiceOption]
    @Binding var busy: Bool
    @Binding var error: String?
    @State private var working = false

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button(o.label) { pick("o\(i)") }
                    .buttonStyle(.borderedProminent)
                    .tint(o.action == "deny" ? .red : (o.action == "allow" ? .green : .accentColor))
                    .controlSize(.small)
            }
            Button(L("Skip")) { pick("deny") }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .disabled(working || busy)
    }

    private func pick(_ action: String) {
        working = true
        Task {
            error = await client.decide(id: choiceId, action: action)
            working = false
        }
    }
}

/// Lays buttons out left to right, wrapping like text.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - Overview

/// Every project at a glance; a row shows that project's assistant.
private struct AgentOverview: View {
    @ObservedObject var uiState: SidebarUIState
    @EnvironmentObject private var client: AgentDaemonClient

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
                    let a = client.assistants[p.name]
                    Text(a?.busy == true ? L("Replying…") : (a?.running == true ? L("Ready")
                         : (p.resident ? L("Resident") : L("Wakes on events"))))
                        .foregroundColor(.secondary)
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
                    Button(L("Open")) { uiState.assistantProject = p.name }
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
    @EnvironmentObject private var client: AgentDaemonClient

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
    @EnvironmentObject private var client: AgentDaemonClient
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
