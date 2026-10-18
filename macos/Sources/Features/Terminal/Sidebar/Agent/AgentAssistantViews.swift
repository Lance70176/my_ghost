import AppKit
import SwiftUI

// MARK: - Navigation

/// Shows an assistant in the main window: switches the sidebar to the ✦ mode
/// and puts that assistant (nil = the all-projects overview) where the
/// terminal was.
@MainActor
enum AgentAssistantNav {
    /// `focusCard`: scroll the conversation to the question behind this card.
    /// `focusDecision`: scroll the pending-decisions list to this card.
    static func show(project: String?, hostKey: String, focusCard: String? = nil,
                     focusDecision: String? = nil) {
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
        controller.sidebarUIState.assistantFocusCard = focusCard
        if let focusDecision {
            // The decision list is the right column's default view.
            controller.sidebarUIState.focusedWorkerID = nil
            controller.sidebarUIState.assistantFocusDecision = focusDecision
        }
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
    @State private var adding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Label(client.hostName, systemImage: client.isLocal ? "laptopcomputer" : "server.rack")
                    .agentFont(.caption, weight: .semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                if !client.online {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(client.isLocal ? L("ghost-agentd isn't running on this Mac")
                                             : L("Can't reach ghost-agentd on %@", client.hostName),
                              systemImage: "bolt.horizontal.circle")
                            .agentFont(.callout)
                            .foregroundColor(.orange)
                        Text(client.isLocal ? L("Install it with agentd/install.sh, then this list fills in.")
                                            : L("It's reached over SSH; install it on that host with agentd/install.sh."))
                            .agentFont(.caption)
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

                if client.online {
                    Button { adding = true } label: {
                        Label(L("New assistant"), systemImage: "plus.circle")
                            .agentFont(.callout)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Add a project assistant with its own Telegram bot"))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .task { await client.refreshProjects() }
        .sheet(isPresented: $adding) {
            AgentNewAssistantSheet(client: client) { uiState.assistantProject = $0 }
        }
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
                    .agentFont(.caption)
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
                .agentFont(.caption)
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
        let convs = project.jobs ?? project.sessions
        if convs > 0 { parts.append(L("%d conversations", convs)) }
        if let working = project.jobsWorking, working > 0 { parts.append(L("%d running", working)) }
        return parts.joined(separator: " · ")
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .agentFont(size: 10, weight: .bold)
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
    @ObservedObject private var zoom = AgentZoom.shared

    var body: some View {
        let client = AgentHub.shared.client(for: controller.currentHost)
        AgentAssistantMainContent(uiState: uiState)
            .environment(\.agentZoom, zoom.scale)
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

    /// The right column's share of the width. Stored, not left to HSplitView:
    /// HSplitView forgot a dragged width whenever the column's content changed
    /// (opening another conversation snapped it back).
    @AppStorage("MyGhostAssistantRightRatio") private var rightRatio: Double = 0.3
    @State private var dragStartWidth: CGFloat?

    private static let minRight: CGFloat = 300
    private static let minCenter: CGFloat = 320
    private static let handleWidth: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let available = max(0, total - Self.handleWidth)
            // Narrower than both minimums: the right column gives way first.
            let minRight = min(Self.minRight, max(220, available - Self.minCenter))
            let maxRight = max(minRight, min(available * 0.5, available - Self.minCenter))
            let right = min(max(CGFloat(rightRatio) * available, minRight), maxRight)
            HStack(spacing: 0) {
                Group {
                    if let project = uiState.assistantProject {
                        AgentChatView(project: project, client: client, uiState: uiState)
                            .id(project)
                    } else {
                        AgentOverview(uiState: uiState)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                AgentSplitHandle()
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? right
                                dragStartWidth = start
                                let width = min(max(start - value.translation.width, minRight), maxRight)
                                rightRatio = Double(width / max(available, 1))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )

                AgentRightColumn(project: uiState.assistantProject, uiState: uiState)
                    .frame(width: right)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// The draggable line between the conversation and the right column.
private struct AgentSplitHandle: View {
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear).frame(width: 7)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop() }
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
                    if chunk.items.isEmpty && !chunk.partial.isEmpty {
                        // Streaming: the daemon answers at once while a reply
                        // is being written; a few refreshes a second is plenty.
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
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

    /// Sends; on failure hands the text back so it isn't lost.
    func send(_ text: String, files: [[String: String]] = [], restore: ((String) -> Void)? = nil) {
        Task {
            error = await client.sendMessage(project: project, text: text, files: files)
            if error != nil { restore?(text) }
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
    @State private var draft: String
    @State private var showTools = false
    @State private var tab: Tab
    @FocusState private var inputFocused: Bool
    @EnvironmentObject private var client: AgentDaemonClient
    @StateObject private var follow = AgentFollow()
    @ObservedObject private var tray: AgentAttachmentTray
    /// The message a card's 💬 opened, highlighted for a moment.
    @State private var highlighted: Int?

    enum Tab { case chat, conversations }

    @ObservedObject var uiState: SidebarUIState
    /// Key for this host + project in the draft store.
    private let storeKey: String

    init(project: String, client: AgentDaemonClient, uiState: SidebarUIState) {
        self.project = project
        self.uiState = uiState
        storeKey = "\(client.hostKey)|\(project)"
        tray = AgentAttachmentTray.tray(storeKey, project: project, target: "assistant")
        _model = StateObject(wrappedValue: AgentChatModel(project: project, client: client))
        _draft = State(initialValue: AgentDraftStore.shared.draft(storeKey))
        _tab = State(initialValue: AgentDraftStore.shared.flag(storeKey + "|conversations") ? .conversations : .chat)
    }

    /// Notices the daemon tied to a card ("你選了…", "已用 … 回覆…"): they
    /// show inside the card instead of loose in the conversation.
    private var cardNotices: [String: [AgentChatItem]] {
        Dictionary(grouping: model.items.filter { $0.role == "notice" && !$0.choiceId.isEmpty }, by: \.choiceId)
    }

    private var visible: [AgentChatItem] {
        let cards = Set(model.items.lazy.filter { $0.role == "choice" }.map(\.choiceId))
        return model.items.filter { item in
            if item.role == "notice" && !item.choiceId.isEmpty && cards.contains(item.choiceId) {
                return false
            }
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
            if tab == .conversations {
                AgentWorkersList(project: project, selectedID: uiState.focusedWorkerID,
                                 onSelect: { w in
                                     uiState.focusedWorkerID = uiState.focusedWorkerID == w.id ? nil : w.id
                                 }) { _, w in
                    tab = .chat
                    let text = L("Please look at the conversation \"%@\" (session_id=%@): where it stands, anything unfinished, and what you need from me.",
                                 w.name, w.sessionId)
                    model.send(text)
                }
            } else {
                chatPane
            }
        }
        .onAppear {
            model.start()
            inputFocused = true
        }
        .onDisappear { model.stop() }
        .onChange(of: draft) { AgentDraftStore.shared.setDraft(storeKey, $0) }
        .onChange(of: tab) { AgentDraftStore.shared.setFlag(storeKey + "|conversations", $0 == .conversations) }
    }

    private var conversationCount: Int? {
        client.projects.first { $0.name == project }?.jobs
    }

    private var chatPane: some View {
        chatPaneContent.modifier(AgentDropTarget(tray: tray, client: client))
    }

    private var chatPaneContent: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.items.isEmpty {
                            emptyHint
                        }
                        ForEach(visible) { item in
                            AgentChatRow(item: item, project: project, outcomes: cardNotices[item.choiceId] ?? [])
                                .id(item.seq)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.accentColor.opacity(highlighted == item.seq ? 0.18 : 0))
                                        .padding(-6)
                                        .animation(.easeOut(duration: 0.4), value: highlighted)
                                )
                        }
                        if !model.partial.isEmpty {
                            AgentBubble(text: model.partial, mine: false, streaming: true)
                                .id(Int.max)
                        } else if model.status?.busy == true {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L("Thinking…")).agentFont(.caption).foregroundColor(.secondary)
                            }
                            .id(Int.max)
                        }
                        AgentScrollEndMarker()
                    }
                    .agentScrollFrame()
                    .padding(14)
                }
                .coordinateSpace(name: AgentFollow.space)
                .onPreferenceChange(AgentScrollFrameKey.self) { frame in
                    follow.frameMoved(frame, viewport: viewport.size.height)
                }
                // New messages scroll into view only while you're at the
                // bottom; reading further up, they're counted instead.
                .onChange(of: model.items.last?.seq) { _ in
                    if follow.shouldFollow() { follow.toEnd(proxy, animated: true) }
                }
                .onChange(of: model.partial) { _ in
                    if follow.atBottom { follow.toEnd(proxy) }
                }
                .onAppear { land(proxy) }
                // The messages arrive after the view does: land again once
                // they're in, else it stays at the top.
                .onChange(of: model.items.isEmpty) { _ in land(proxy) }
                .onChange(of: uiState.assistantFocusCard) { _ in land(proxy) }
                .overlay(alignment: .bottom) {
                    AgentNewMessagesButton(follow: follow) {
                        follow.toEnd(proxy, animated: true)
                    }
                }
            }
            }
            Divider()
            input
        }
    }

    /// Where to be when the conversation opens: at the question a card was
    /// opened from (highlighted for a moment), else at the newest message.
    private func land(_ proxy: ScrollViewProxy) {
        guard !model.items.isEmpty else { return }
        if let card = uiState.assistantFocusCard,
           let item = model.items.last(where: { $0.choiceId == card || $0.cardId == card }) {
            tab = .chat
            uiState.assistantFocusCard = nil
            DispatchQueue.main.async {
                withAnimation { proxy.scrollTo(item.seq, anchor: .center) }
                highlighted = item.seq
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if highlighted == item.seq { highlighted = nil }
                }
            }
        } else {
            follow.toEnd(proxy)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(.accentColor)
            Text(L("%@ assistant", project == "_default" ? L("Other conversations") : project))
                .agentFont(.headline)
            if let s = model.status {
                Text(s.resident ? L("Resident") : L("Wakes on events"))
                    .agentFont(.caption).foregroundColor(.secondary)
                Text(s.busy ? L("Replying…") : (s.running ? L("Ready") : L("Asleep")))
                    .agentFont(.caption)
                    .foregroundColor(s.busy ? .orange : (s.running ? .green : .secondary))
            }
            Picker("", selection: $tab) {
                Text(L("Assistant chat")).tag(Tab.chat)
                Text(conversationCount.map { L("Conversations %d", $0) } ?? L("Conversations")).tag(Tab.conversations)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.leading, 8)
            Spacer()
            if tab == .chat {
                Toggle(L("Show tool calls"), isOn: $showTools)
                    .toggleStyle(.checkbox)
                    .agentFont(.caption)
            }
            if let s = model.status {
                if let pct = s.contextPct {
                    Text(L("Context %d%%", pct)).agentFont(.caption, monoDigits: true)
                        .foregroundColor(pct >= 80 ? .orange : .secondary)
                }
                Text(L("Woken %d× today", s.wakesToday)).agentFont(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Ask this project's assistant anything — e.g. \"What's still unfinished?\""))
                .agentFont(.callout)
            Text(L("Replies also go to the project's Telegram group, and what you say there shows up here."))
                .agentFont(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 20)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 4) {
            AgentAttachmentStrip(tray: tray)
            HStack(alignment: .bottom, spacing: 8) {
                AgentAttachButton(tray: tray)
                    .padding(.bottom, 7)
                AgentInputField(text: $draft,
                                placeholder: L("Message the %@ assistant… (Return sends, ⇧Return for a new line)", project),
                                onSubmit: submit, autoFocus: true, tray: tray)
                    .frame(minHeight: 34, maxHeight: 140)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))

                if model.status?.busy == true {
                    Button { model.interrupt() } label: {
                        Image(systemName: "stop.circle.fill").agentFont(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help(L("Stop this reply"))
                }
                Button(action: submit) {
                    Image(systemName: "paperplane.fill").agentFont(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!canSubmit)
                .help(L("Send"))
            }
            if let error = model.error {
                Text(error).agentFont(.caption).foregroundColor(.red)
            }
        }
        .padding(10)
    }

    private var canSubmit: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tray.isEmpty) && !tray.blocking
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }
        let sent = tray.files
        let files = tray.payload
        draft = ""
        tray.clear()
        follow.followNext = true
        model.send(text, files: files) { failed in
            // Only if nothing new was typed meanwhile.
            if draft.isEmpty { draft = failed }
            tray.restore(sent)
        }
    }
}

/// A multi-line text field where Return sends and Shift-Return breaks the line.
/// An NSTextView that draws its own placeholder, hidden as soon as there is
/// anything in it — including text still being composed with an input method
/// (Chinese, Japanese…), which a SwiftUI overlay keyed on the committed text
/// drew on top of.
final class AgentPlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    /// Files or an image pasted or dropped here; text still goes in as text.
    var onAttach: ((AgentPasteboard.Found) -> Void)?

    /// Put attachment marks ("[Image #1]") at the cursor, spaced from the text.
    func insertLabels(_ labels: [String]) {
        guard !labels.isEmpty, !hasMarkedText() else { return }
        let sel = selectedRange()
        let ns = string as NSString
        var s = labels.joined(separator: " ") + " "
        if sel.location > 0, sel.location <= ns.length,
           let c = Character(ns.substring(with: NSRange(location: sel.location - 1, length: 1))) as Character?,
           !c.isWhitespace {
            s = " " + s
        }
        insertText(s, replacementRange: sel)
        window?.makeFirstResponder(self)
    }

    /// Take a mark (and the space after it) out of the text.
    func eraseLabel(_ label: String) {
        let ns = string as NSString
        var r = ns.range(of: label)
        guard r.location != NSNotFound else { return }
        if NSMaxRange(r) < ns.length, ns.character(at: NSMaxRange(r)) == 0x20 { r.length += 1 }
        if shouldChangeText(in: r, replacementString: "") {
            replaceCharacters(in: r, with: "")
            didChangeText()
        }
    }

    override func paste(_ sender: Any?) {
        if let onAttach, let found = AgentPasteboard.attachments(.general) {
            onAttach(found)
            return
        }
        super.paste(sender)
    }

    /// A plain-text view disables Paste when the pasteboard holds only an
    /// image, so ⌘V never reached paste(_:) above.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onAttach != nil,
           AgentPasteboard.attachments(.general) != nil {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Likewise it would refuse an image dragged in.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onAttach != nil, AgentPasteboard.attachments(sender.draggingPasteboard) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onAttach != nil, AgentPasteboard.attachments(sender.draggingPasteboard) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if onAttach != nil, AgentPasteboard.attachments(sender.draggingPasteboard) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onAttach, let found = AgentPasteboard.attachments(sender.draggingPasteboard) {
            onAttach(found)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let pad = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerOrigin.x + pad, y: textContainerOrigin.y)
        NSAttributedString(string: placeholder, attributes: attrs)
            .draw(in: NSRect(x: origin.x, y: origin.y,
                             width: bounds.width - origin.x - pad, height: bounds.height - origin.y))
    }
}

private struct AgentInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    let onSubmit: () -> Void
    /// Take the keyboard when shown (SwiftUI focus doesn't reach the
    /// NSTextView inside, and the terminal under the assistant must not keep it).
    var autoFocus = false
    /// Where pasted or dropped files and images go (their marks go in the
    /// text); nil leaves them to the text view.
    var tray: AgentAttachmentTray?
    @EnvironmentObject private var client: AgentDaemonClient
    @Environment(\.agentZoom) private var zoom

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let tv = AgentPlaceholderTextView(frame: .zero)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.placeholder = placeholder
        if tray != nil {
            tv.onAttach = { [weak coordinator = context.coordinator] found in
                guard let parent = coordinator?.parent else { return }
                parent.tray?.attach(found, client: parent.client)
            }
            tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 8)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if autoFocus {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! AgentPlaceholderTextView
        // Never replace the text mid-composition: the binding only holds
        // committed text, and writing it back would cancel the candidate.
        if !tv.hasMarkedText() && tv.string != text { tv.string = text }
        if tv.placeholder != placeholder { tv.placeholder = placeholder }
        if let tray {
            tray.insertLabels = { [weak tv] in tv?.insertLabels($0) }
            tray.eraseLabel = { [weak tv] in tv?.eraseLabel($0) }
        }
        let size = NSFont.systemFontSize * zoom
        if tv.font?.pointSize != size { tv.font = .systemFont(ofSize: size) }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentInputField
        init(_ parent: AgentInputField) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            // Deleting "[Image #1]" from the text drops that attachment.
            parent.tray?.prune(tv.string)
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
    /// For a card: the notices about it (shown inside it).
    var outcomes: [AgentChatItem] = []
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
                        .agentFont(.caption2).foregroundColor(.blue)
                }
                AgentUserMessage(text: item.text, files: item.files ?? [], project: project)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case "assistant":
            AgentBubble(text: item.text, mine: false)
        case "tool":
            Label(item.text, systemImage: "wrench.and.screwdriver")
                .agentFont(.caption, design: .monospaced)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case "choice":
            AgentChatCard(item: item, outcomes: outcomes)
        case "discuss":
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Discussing this request"), systemImage: "bubble.left.and.bubble.right.fill")
                    .agentFont(.caption, weight: .semibold).foregroundColor(.blue)
                Text(item.text)
                    .agentFont(.caption, design: .monospaced)
                    .textSelection(.enabled)
                if let card = client.pending.first(where: { $0.id == item.cardId }) {
                    AgentDecisionCard(p: card, width: 460)
                } else {
                    Text(L("Already decided")).agentFont(.caption).foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.08)))
        default:  // notice
            Text(item.text)
                .agentFont(.caption)
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
            .agentFont(.body)
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
                Button { pick("o\(i)") } label: { Text(o.label).agentFont(.callout) }
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
        // Without a width, assume the narrowest that fits the widest button
        // (taller rather than cut off when placed in a narrow card).
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
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
            Text(L("All projects")).agentFont(.title3, weight: .semibold)
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
    @ObservedObject var uiState: SidebarUIState
    @EnvironmentObject private var client: AgentDaemonClient

    private var pending: [AgentPending] {
        client.pending.filter { project == nil || $0.project == project }
    }

    /// The card opened from the bottom-right stack, lit up for a moment.
    @State private var highlighted: String?

    /// Scroll to the card the bottom-right stack was clicked on, once it's
    /// in the list (the page and its cards may arrive after the click).
    private func landOnFocus(_ proxy: ScrollViewProxy) {
        guard let id = uiState.assistantFocusDecision, pending.contains(where: { $0.id == id }) else { return }
        uiState.assistantFocusDecision = nil
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            highlighted = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if highlighted == id { highlighted = nil }
            }
        }
    }

    var body: some View {
        if let project, let id = uiState.focusedWorkerID {
            AgentWorkerConversationView(project: project, workerID: id, hostKey: client.hostKey) {
                uiState.focusedWorkerID = nil
            }
            .id(id)
        } else {
            decisions
        }
    }

    private var decisions: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: L("Pending decisions"), count: pending.count)
                if pending.isEmpty {
                    Text(L("Nothing waiting for you."))
                        .agentFont(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                    Spacer(minLength: 0)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(pending) { p in
                                    AgentDecisionCard(p: p, width: nil)
                                        .id(p.id)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.accentColor.opacity(highlighted == p.id ? 0.22 : 0))
                                                .padding(-4)
                                                .animation(.easeOut(duration: 0.4), value: highlighted)
                                        )
                                }
                            }
                            .padding(4)
                            .padding(.bottom, 2)
                        }
                        .onAppear { landOnFocus(proxy) }
                        .onChange(of: uiState.assistantFocusDecision) { _ in landOnFocus(proxy) }
                        .onChange(of: pending.map(\.id)) { _ in landOnFocus(proxy) }
                    }
                }
            }
            .padding(10)
            .frame(minHeight: 120)

            AgentHistoryList(project: project)
                .frame(minHeight: 140)
        }
    }
}

/// The project's Claude Code conversations (the same list Claude Code's agent
/// view shows), each with a way to ask the assistant about it.
private struct AgentWorkersList: View {
    let project: String?
    var selectedID: String?
    /// Clicking a row opens it in the right column (again closes it).
    var onSelect: ((AgentWorker) -> Void)?
    /// "Ask the assistant" about a conversation (project, conversation).
    let onAsk: (String, AgentWorker) -> Void
    @EnvironmentObject private var client: AgentDaemonClient
    @State private var workers: [(project: String, worker: AgentWorker)] = []
    @State private var expanded: Set<String> = []
    @State private var asked: String?
    @State private var loaded = false
    @State private var loadFailed = false
    /// Right-click → Delete: the one waiting for confirmation, and why a
    /// delete didn't happen.
    @State private var deleting: (project: String, worker: AgentWorker)?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let working = workers.filter { $0.worker.isWorking }.count
                let waiting = workers.filter { $0.worker.needsYou }.count
                let done = workers.filter { $0.worker.isDone }.count
                Text(L("%d awaiting input · %d working · %d completed", waiting, working, done))
                    .agentFont(.callout).foregroundColor(.secondary)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(L("Refresh"))
            }
            if loadFailed {
                HStack(spacing: 8) {
                    Label(workers.isEmpty ? L("Couldn't load the conversations.")
                                          : L("Couldn't refresh — showing what was loaded before. Retrying…"),
                          systemImage: "exclamationmark.triangle")
                        .agentFont(.caption).foregroundColor(.orange)
                    Button(L("Retry")) { Task { await reload() } }.controlSize(.small)
                }
            }
            if !loaded {
                ProgressView().controlSize(.small)
                Spacer(minLength: 0)
            } else if workers.isEmpty {
                if !loadFailed {
                    Text(L("No conversations in this project yet."))
                        .agentFont(.callout).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            } else {
                List(workers, id: \.worker.id) { item in
                    row(item.project, item.worker)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect?(item.worker) }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleting = (item.project, item.worker)
                            } label: {
                                Label(L("Delete…"), systemImage: "trash")
                            }
                        }
                        .listRowBackground(item.worker.id == selectedID
                                           ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .listStyle(.inset)
            }
        }
        .padding(10)
        .alert(L("Delete \u{201C}%@\u{201D}?", deleting?.worker.name ?? ""),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Delete"), role: .destructive) {
                if let d = deleting { Task { await delete(d.project, d.worker) } }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text((deleting?.worker.isWorking == true ? L("It is still running and will be stopped first.") + "\n" : "")
                 + L("This deletes the background conversation and its worktree, like `claude rm`. If the worktree has commits that aren't pushed, it refuses."))
        }
        .alert(L("Couldn't delete"), isPresented: Binding(get: { deleteError != nil },
                                                        set: { if !$0 { deleteError = nil } })) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .task(id: project ?? "*") {
            // Every 15 s while visible, and soon after anything changes.
            var seen = -1
            var last = Date.distantPast
            while !Task.isCancelled {
                let due = Date().timeIntervalSince(last) >= 15
                    || (client.changeCount != seen && Date().timeIntervalSince(last) >= 3)
                if due {
                    seen = client.changeCount
                    last = Date()
                    await reload()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func delete(_ proj: String, _ w: AgentWorker) async {
        if let err = await client.workerRemove(project: proj, id: w.id) {
            deleteError = err
            return
        }
        if w.id == selectedID { onSelect?(w) }  // close it on the right
        workers.removeAll { $0.worker.id == w.id }
        await reload()
    }

    private func reload() async {
        let wanted = project
        var out: [(String, AgentWorker)] = []
        var anyFailed = false
        let names = project.map { [$0] } ?? client.projects.map(\.name)
        for name in names {
            guard let list = await client.workers(project: name) else {
                anyFailed = true
                continue
            }
            for w in list { out.append((name, w)) }
        }
        out.sort { $0.1.updatedAt > $1.1.updatedAt }
        guard wanted == project else { return }
        loaded = true
        loadFailed = anyFailed
        // On failure keep what was there rather than emptying the list.
        if anyFailed && out.isEmpty { return }
        workers = out.map { (project: $0.0, worker: $0.1) }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let shown: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func when(_ s: String) -> String {
        guard let d = Self.iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) else { return "" }
        if Date().timeIntervalSince(d) > 7 * 86400 { return Self.shown.string(from: d) }
        return Self.relative.localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder
    private func row(_ proj: String, _ w: AgentWorker) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    if expanded.contains(w.id) { expanded.remove(w.id) } else { expanded.insert(w.id) }
                } label: {
                    Image(systemName: expanded.contains(w.id) ? "chevron.down" : "chevron.right")
                        .agentFont(.caption)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .help(L("Show details"))
                Circle()
                    .fill(w.dotColor)
                    .frame(width: 7, height: 7)
                Text(w.name).agentFont(.body, weight: .semibold).lineLimit(1)
                if project == nil {
                    Text(proj).agentFont(.caption).foregroundColor(.accentColor)
                }
                Spacer()
                Text(w.localizedState).agentFont(.caption2)
                    .foregroundColor(w.isDone ? .secondary : w.dotColor)
                Text(when(w.updatedAt)).agentFont(.caption2, monoDigits: true).foregroundColor(.secondary)
            }
            if !w.detail.isEmpty {
                Text(w.detail)
                    .agentFont(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(expanded.contains(w.id) ? nil : 1)
                    .truncationMode(.tail)
            }
            if expanded.contains(w.id) {
                VStack(alignment: .leading, spacing: 2) {
                    if !w.intent.isEmpty { Text(L("Started with: %@", w.intent)) }
                    if !w.branch.isEmpty { Text(L("Branch: %@", w.branch)) }
                    Text(w.cwd)
                }
                .agentFont(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button {
                    ask(proj, w)
                } label: {
                    Label(asked == w.id ? L("Asked") : L("Ask the assistant"), systemImage: "sparkles")
                }
                .buttonStyle(.borderless)
                .agentFont(.caption)
                .help(L("Have the assistant read this conversation and sum it up"))
                .disabled(asked == w.id)
            }
        }
        .padding(.vertical, 3)
    }

    private func ask(_ proj: String, _ w: AgentWorker) {
        asked = w.id
        onAsk(proj, w)
    }
}

private struct SectionTitle: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack {
            Text(title).agentFont(.headline)
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
    @State private var historyFailed = false
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
                    .agentFont(.caption)
                    .help(L("Also list the L0/L1 requests the rules allowed by themselves"))
            }
            if historyFailed {
                Label(records.isEmpty ? L("Couldn't load the decision history.")
                                      : L("Couldn't refresh — showing what was loaded before. Retrying…"),
                      systemImage: "exclamationmark.triangle")
                    .agentFont(.caption).foregroundColor(.orange)
            }
            if shown.isEmpty {
                if !historyFailed {
                    Text(L("No decisions yet."))
                        .agentFont(.callout).foregroundColor(.secondary)
                }
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
                    // Each decision is its own card, with room between them.
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 2, bottom: 5, trailing: 2))
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(10)
        .task(id: "\(project ?? "*")-\(client.changeCount)") {
            let wanted = project
            let fresh = await client.decisions(project: wanted)
            // A late answer for a project we've since left is dropped.
            guard wanted == project else { return }
            if let fresh {
                records = fresh
                historyFailed = false
            } else {
                historyFailed = true
            }
        }
        .onChange(of: project) { _ in
            records = []
            closed = []
            expanded = []
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
        if record.reply != nil {
            return record.outcome == "send" ? ("paperplane.circle.fill", .green) : ("minus.circle.fill", .secondary)
        }
        if record.by == "superseded" {
            return ("arrow.triangle.2.circlepath.circle.fill", .secondary)
        }
        if record.by == "answered" {
            return ("text.bubble.fill", .green)
        }
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
        case "superseded": return L("Handled by a newer decision card")
        case "answered": return L("Answered in words")
        default: return record.byRule ? L("Rule %@", record.level) : record.by
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon.0).foregroundColor(icon.1)
                Text(Self.time.string(from: record.date))
                    .agentFont(.caption, monoDigits: true).foregroundColor(.secondary)
                AgentCardTag(tag: record.tag, day: record.serialDay)
                Text(record.level).agentFont(.caption, weight: .bold).foregroundColor(.secondary)
                if showProject {
                    Text(record.project).agentFont(.caption).foregroundColor(.accentColor)
                }
                Spacer()
                Button(action: onJump) {
                    Label(record.tab?.isEmpty == false ? record.tab! : L("Conversation"),
                          systemImage: "arrow.up.forward.square")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .agentFont(.caption)
                .help(L("Show the conversation this request came from"))
                .disabled((record.tmuxSession ?? "").isEmpty)
            }
            if let r = record.reply {
                replyRecord(r)
            } else {
                Text(record.summary)
                    .agentFont(.caption, design: .monospaced)
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.middle)
                    .onTapGesture(perform: onToggle)
                if let chosen = record.chosen {
                    Text(L("Chose: %@", chosen)).agentFont(.caption, weight: .semibold)
                }
            }
            if isClosed {
                Label(L("That conversation has been closed; it can't be shown."),
                      systemImage: "exclamationmark.triangle")
                    .agentFont(.caption).foregroundColor(.orange)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let reason = record.reason { Text(reason) }
                    Text(L("Decided by %@", source))
                    if let msg = record.denyMessage, !msg.isEmpty { Text(msg) }
                    if let rule = record.alwaysAdded { Text(L("Always allow in this project: %@", rule)) }
                    if record.discussed == true { Text(L("Was discussed before deciding")) }
                }
                .agentFont(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.22)))
        // A strip in the outcome's colour down the left edge.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(icon.1.opacity(0.85))
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 4)
        }
    }

    /// A work-account reply: who wrote what, the reply in full, and whether
    /// it went out.
    private func replyRecord(_ r: AgentReplyDraft) -> some View {
        let sent = record.outcome == "send"
        let outcome: String = {
            switch record.outcome {
            case "send": return L("Sent as %@", r.account)
            case "revise": return L("Not sent: asked for changes")
            case "self_reply": return L("Not sent: you replied in Telegram yourself")
            case "replaced": return L("Not sent: replaced by a newer draft")
            case "superseded": return L("Not sent: handled by a newer decision card")
            case "answered": return L("Not sent: answered in words")
            default: return L("Not sent: no reply needed")
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(r.isPrivate == false ? L("%@ in %@ wrote", r.sender, r.chat) : L("%@ wrote", r.sender))
                .agentFont(.caption).foregroundColor(.secondary)
            if let original = r.original, !original.isEmpty {
                Text(original)
                    .agentFont(.callout)
                    .lineLimit(isExpanded ? nil : 3)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            Label(outcome, systemImage: sent ? "paperplane.fill" : "xmark")
                .agentFont(.caption, weight: .semibold)
                .foregroundColor(sent ? .green : .secondary)
            Text(r.text)
                .agentFont(.callout)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(sent ? Color.green.opacity(0.10) : Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(sent ? Color.green.opacity(0.4) : Color.secondary.opacity(0.25)))
            if let note = r.note, !note.isEmpty, isExpanded {
                Label(note, systemImage: "lightbulb").agentFont(.caption).foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

// MARK: - A Claude Code conversation in the right column

/// One of the project's Claude Code conversations: scroll through it and
/// type into it (sent the way `claude attach` would take it).
private struct AgentWorkerConversationView: View {
    let project: String
    let workerID: String
    let onClose: () -> Void
    @EnvironmentObject private var client: AgentDaemonClient
    @State private var worker: AgentWorker?
    @State private var messages: [AgentWorkerMessage] = []
    @State private var draft: String
    @State private var sending = false
    @State private var note: String?
    @State private var loaded = false
    /// Scrolled to the newest message once they first came in.
    @State private var landed = false
    /// The last refresh failed (what's shown is from before).
    @State private var failed = false
    @StateObject private var follow = AgentFollow()
    @ObservedObject private var tray: AgentAttachmentTray
    private let storeKey: String

    init(project: String, workerID: String, hostKey: String, onClose: @escaping () -> Void) {
        self.project = project
        self.workerID = workerID
        self.onClose = onClose
        storeKey = "\(hostKey)|\(project)|w:\(workerID)"
        tray = AgentAttachmentTray.tray(storeKey, project: project, target: workerID)
        _draft = State(initialValue: AgentDraftStore.shared.draft(storeKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(worker?.dotColor ?? .secondary)
                    .frame(width: 7, height: 7)
                Text(worker?.name ?? "…").agentFont(.headline).lineLimit(1)
                if let w = worker {
                    Text(w.localizedState).agentFont(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L("Back to decisions"))
            }
            .padding(10)
            Divider()
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !loaded {
                            ProgressView().controlSize(.small)
                        } else if failed && messages.isEmpty {
                            loadFailed
                        } else if messages.isEmpty {
                            Text(L("Nothing to show for this conversation."))
                                .agentFont(.callout).foregroundColor(.secondary)
                        }
                        ForEach(messages) { m in
                            switch m.role {
                            case "user":
                                AgentBubble(text: m.text, mine: true)
                            case "tool":
                                Label(m.text, systemImage: "wrench.and.screwdriver")
                                    .agentFont(.caption, design: .monospaced)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            default:
                                AgentBubble(text: m.text, mine: false)
                            }
                        }
                        AgentScrollEndMarker()
                    }
                    .agentScrollFrame()
                    .padding(10)
                }
                .coordinateSpace(name: AgentFollow.space)
                .onPreferenceChange(AgentScrollFrameKey.self) { frame in
                    follow.frameMoved(frame, viewport: viewport.size.height)
                }
                .onChange(of: messages.last?.id) { _ in
                    if follow.shouldFollow() { follow.toEnd(proxy) }
                }
                .onAppear { follow.toEnd(proxy) }
                // The messages arrive after the view does: open at the newest.
                .onChange(of: messages.isEmpty) { empty in
                    if !empty && !landed {
                        landed = true
                        follow.toEnd(proxy)
                    }
                }
                .overlay(alignment: .bottom) {
                    AgentNewMessagesButton(follow: follow) {
                        follow.toEnd(proxy, animated: true)
                    }
                }
            }
            }
            if failed && !messages.isEmpty {
                Text(L("Couldn't refresh — showing what was loaded before. Retrying…"))
                    .agentFont(.caption).foregroundColor(.orange)
                    .padding(.horizontal, 10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                AgentAttachmentStrip(tray: tray)
                HStack(alignment: .bottom, spacing: 6) {
                    AgentAttachButton(tray: tray)
                        .padding(.bottom, 7)
                    AgentInputField(text: $draft, placeholder: L("Type into this conversation… (Return sends)"),
                                    onSubmit: send, tray: tray)
                        .frame(minHeight: 34, maxHeight: 120)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
                    Button(action: send) { Image(systemName: "paperplane.fill") }
                        .buttonStyle(.borderless)
                        .disabled(!canSend)
                }
                if let note {
                    Text(note).agentFont(.caption).foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
        .modifier(AgentDropTarget(tray: tray, client: client))
        .task { await poll() }
        .onChange(of: draft) { AgentDraftStore.shared.setDraft(storeKey, $0) }
    }

    private var canSend: Bool {
        !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tray.isEmpty)
            && !tray.blocking
    }

    private var loadFailed: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Couldn't load this conversation."), systemImage: "exclamationmark.triangle")
                .agentFont(.callout).foregroundColor(.orange)
            Button(L("Retry")) { Task { await refresh() } }
                .controlSize(.small)
        }
    }

    @discardableResult
    private func refresh() async -> Bool {
        if let log = await client.workerLog(project: project, id: workerID) {
            worker = log.worker
            if log.messages != messages { messages = log.messages }
            failed = false
        } else {
            failed = true
        }
        loaded = true
        return !failed
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: (worker?.isWorking == true ? 2 : 4) * 1_000_000_000)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        sending = true
        follow.followNext = true
        note = L("Sending…")
        let sent = tray.files
        let files = tray.payload
        Task {
            if let err = await client.workerSend(project: project, id: workerID, text: text, files: files) {
                note = err
            } else {
                // Text typed while this one was on its way stays.
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                tray.discard(sent.map(\.id))
                note = L("Sent. The reply shows up here when it comes.")
            }
            sending = false
        }
    }
}
