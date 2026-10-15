import AppKit
import Combine
import SwiftUI

/// The bottom-right decision cards: one per permission request ghost-agentd
/// is holding. A non-activating panel, so a card appearing never steals focus
/// from the terminal being typed in, and it stays up while another app is in
/// front — the request is blocked until someone answers it somewhere.
extension Notification.Name {
    /// A window's sidebar switched mode (terminal / files / editor / assistant).
    static let sidebarModeChanged = Notification.Name("MyGhostSidebarModeChanged")
}

@MainActor
final class AgentDecisionPanel {
    static let shared = AgentDecisionPanel()

    private var panel: NSPanel?
    private var contentSize = CGSize(width: 360, height: 160)
    private var cancellables = Set<AnyCancellable>()
    private var seenIDs = Set<String>()
    private var pending: [AgentHostPending] = []

    private init() {}

    func start() {
        let hub = AgentHub.shared
        hub.start()
        hub.$allPending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in self?.update(pending) }
            .store(in: &cancellables)
        // Re-check whether the assistant chat is in front.
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .sidebarModeChanged, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification, NSWindow.didBecomeMainNotification,
        ]
        for name in names {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.update(self.pending)
                }
                .store(in: &cancellables)
        }
    }

    /// MyGhost is in front showing the ✦ assistant page, whose chat already
    /// carries these cards — the floating copy would only cover the screen.
    private var assistantInFront: Bool {
        guard NSApp.isActive,
              let win = NSApp.orderedWindows.first(where: {
                  $0.isVisible && !$0.isMiniaturized && $0.windowController is SidebarTerminalController
              }),
              let controller = win.windowController as? SidebarTerminalController else { return false }
        return controller.sidebarUIState.sidebarMode == .assistant
    }

    private func update(_ pending: [AgentHostPending]) {
        self.pending = pending
        guard !pending.isEmpty else {
            panel?.orderOut(nil)
            seenIDs.removeAll()
            return
        }
        let fresh = pending.contains { !seenIDs.contains($0.id) }
        seenIDs = Set(pending.map(\.id))
        // Cards that arrive while the chat is in front count as seen there.
        guard !assistantInFront else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Let SwiftUI settle the new card count before measuring.
        DispatchQueue.main.async { [weak self] in
            self?.layout(panel)
            panel.orderFrontRegardless()
            if fresh { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: AgentDecisionStack())
        host.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = host
        // The hosting view sizes the panel to its cards, growing it downward
        // from the top — past the screen's bottom edge for a tall card. Put
        // it back at the bottom-right every time its size changes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                if let self, let panel { self.layout(panel) }
            }
        }
        return panel
    }

    /// The cards grew or shrank (a reason field opened, a card was answered).
    func contentSizeChanged(_ size: CGSize) {
        guard size != contentSize, size.height > 0 else { return }
        contentSize = size
        if let panel, panel.isVisible { layout(panel) }
    }

    /// Bottom-right of the frontmost MyGhost window, else of the screen.
    private func layout(_ panel: NSPanel) {
        let anchor: NSRect
        if let win = NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is SidebarTerminalController }) {
            anchor = win.frame
        } else {
            anchor = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        }
        // Keep it on the screen the window is on, above the Dock.
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? anchor
        let area = anchor.intersection(screen).isEmpty ? screen : anchor.intersection(screen)
        let maxHeight = area.height - 32
        panel.maxSize = NSSize(width: 420, height: maxHeight)
        // As tall as its cards are (SwiftUI's own measure), within the screen.
        let fit = (panel.contentView as? NSHostingView<AgentDecisionStack>)?.fittingSize ?? panel.frame.size
        let width = min(max(fit.width, 340), 420)
        let height = min(max(fit.height, 1), maxHeight)
        let target = NSRect(x: area.maxX - width - 16, y: area.minY + 16, width: width, height: height)
        if panel.frame != target { panel.setFrame(target, display: true) }
    }

    /// Bring the tab a request came from to the front. False when no open tab
    /// runs that session any more (the conversation was closed).
    @discardableResult
    static func reveal(tmuxSession: String) -> Bool {
        guard !tmuxSession.isEmpty else { return false }
        for window in NSApp.windows {
            guard let controller = window.windowController as? SidebarTerminalController else { continue }
            for tab in controller.tabs {
                let hit = tab.screenSessionName == tmuxSession
                    || tab.children.contains { $0.screenSessionName == tmuxSession }
                guard hit else { continue }
                controller.selectTab(tab)
                if let child = tab.children.first(where: { $0.screenSessionName == tmuxSession }),
                   tab.isFullMode {
                    controller.switchFullModeChild(to: child, in: tab)
                }
                controller.sidebarUIState.sidebarMode = .terminal
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return true
            }
        }
        return false
    }
}

private struct AgentDecisionStack: View {
    @ObservedObject private var hub = AgentHub.shared
    @ObservedObject private var lang = LanguageManager.shared

    /// The cards' natural height, measured inside the scroll view.
    @State private var cardsHeight: CGFloat = 0

    /// Tallest the card area may be: the screen, less room for the rest.
    private var maxCardsHeight: CGFloat {
        ((NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800) - 120
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Tall cards (long choices, an open reason field) scroll rather
            // than run off the screen.
            ScrollView(.vertical) {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(hub.allPending.suffix(3)) { hp in
                        AgentDecisionCard(p: hp.pending, showHost: hub.clients.count > 1 || !hp.client.isLocal)
                            .environmentObject(hp.client)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardsHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(max(cardsHeight, 1), maxCardsHeight))
            .onPreferenceChange(CardsHeightKey.self) { cardsHeight = $0 }
            if hub.allPending.count > 3 {
                Text(L("%d more waiting", hub.allPending.count - 3))
                    .agentFont(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
            }
        }
        .padding(8)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: StackSizeKey.self, value: g.size)
        })
        .onPreferenceChange(StackSizeKey.self) { size in
            AgentDecisionPanel.shared.contentSizeChanged(size)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        // The panel never becomes the key window, which greys out tinted
        // buttons; draw them as active, as everywhere else.
        .environment(\.controlActiveState, .key)
    }
}

private struct StackSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Borderless panels can't become key by default, which would leave the
/// deny-reason field unable to take typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A pending request with its buttons; used by the bottom-right stack and the
/// assistant window.
struct AgentDecisionCard: View {
    let p: AgentPending
    /// nil: fill the space given (the assistant's right column).
    var width: CGFloat? = 344
    /// Label the card with its host (cards from several Macs share the stack).
    var showHost = false
    @EnvironmentObject private var client: AgentDaemonClient
    @State private var closedNotice = false
    @State private var busy = false
    @State private var error: String?
    @State private var reason = ""
    @State private var askingReason = false
    @State private var now = Date()
    @State private var deadline: Date?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var minutesLeft: Int {
        let end = client.deadlines[p.id] ?? deadline ?? Date().addingTimeInterval(TimeInterval(p.remaining))
        return max(0, Int(end.timeIntervalSince(now)) / 60)
    }

    private var accent: Color {
        if p.reply != nil { return .orange }
        if p.dispatch != nil { return .green }
        return p.isChoice ? .accentColor : (p.isHighRisk ? .red : (p.level >= 2 ? .orange : .green))
    }

    var body: some View {
        Group {
            if let r = p.reply {
                replyBody(r)
            } else if let d = p.dispatch, d.task != nil {
                dispatchBody(d)
            } else if p.isChoice {
                choiceBody
            } else {
                permissionBody
            }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.6), lineWidth: 1))
        )
        .onReceive(tick) { now = $0 }
        .onAppear { deadline = Date().addingTimeInterval(TimeInterval(p.remaining)) }
    }

    /// A reply the assistant drafted for the work account: what they said,
    /// what would be sent, and one clear button that sends it.
    private func replyBody(_ r: AgentReplyDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.circle.fill").foregroundColor(.orange)
                Text(L("Reply to %@ as %@?", r.isPrivate == false ? r.chat : r.sender, r.account))
                    .agentFont(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    AgentAssistantNav.show(project: p.project, hostKey: client.hostKey, focusCard: p.id)
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderless)
                .help(L("Open the assistant conversation"))
            }
            if let original = r.original, !original.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.isPrivate == false ? L("%@ in %@ wrote", r.sender, r.chat) : L("%@ wrote", r.sender))
                        .agentFont(.caption).foregroundColor(.secondary)
                    Text(original)
                        .agentFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Will be sent as %@", r.account))
                    .agentFont(.caption, weight: .semibold).foregroundColor(.orange)
                Text(r.text)
                    .agentFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5)))
            }
            if let note = r.note, !note.isEmpty {
                Label(note, systemImage: "lightbulb")
                    .agentFont(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showHost { hostLabel }
            Button { pickReply("o0") } label: {
                Label(L("Send as %@", r.account), systemImage: "paperplane.fill")
                    .agentFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(busy)
            HStack(spacing: 8) {
                Button { pickReply("o1") } label: {
                    Label(L("Change it"), systemImage: "pencil").frame(maxWidth: .infinity)
                }
                Button { pickReply("o2") } label: {
                    Label(L("No reply needed"), systemImage: "xmark").frame(maxWidth: .infinity)
                }
                Button { pickReply("deny") } label: {
                    Label(L("Skip"), systemImage: "arrow.uturn.right").frame(maxWidth: .infinity)
                }
                .help(L("Not sure yet: set it aside without answering"))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(busy)
            if let error {
                Text(error).agentFont(.caption).foregroundColor(.red)
            }
        }
    }

    /// Work the assistant proposes: what, where, and one clear 開工 button.
    private func dispatchBody(_ d: AgentDispatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.circle.fill").foregroundColor(.green)
                Text(L("%@ assistant proposes work", p.project))
                    .agentFont(.headline)
                Spacer(minLength: 4)
                Button {
                    AgentAssistantNav.show(project: p.project, hostKey: client.hostKey, focusCard: p.id)
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderless)
                .help(L("Open the assistant conversation"))
            }
            Text(d.title ?? "").agentFont(.title3, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Label(d.repo ?? "", systemImage: "folder").agentFont(.callout)
                Label(L("New branch %@ from %@", d.branch ?? "", d.base ?? ""), systemImage: "arrow.triangle.branch")
                    .agentFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let place = d.place {
                    Label(place, systemImage: "mappin.and.ellipse").agentFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(d.permNote ?? L("Asks you before push, merge, deleting, installing or touching a database"),
                      systemImage: "lock.shield")
                    .agentFont(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Task for the new conversation"))
                    .agentFont(.caption, weight: .semibold).foregroundColor(.green)
                ScrollView {
                    Text(d.task ?? "")
                        .agentFont(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.45)))
            }
            if showHost { hostLabel }
            Button { pickReply("o0") } label: {
                Label(L("Start work"), systemImage: "play.fill")
                    .agentFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(busy)
            HStack(spacing: 8) {
                Button { pickReply("o1") } label: {
                    Label(L("Change it"), systemImage: "pencil").frame(maxWidth: .infinity)
                }
                Button { pickReply("o2") } label: {
                    Label(L("Don't do it"), systemImage: "xmark").frame(maxWidth: .infinity)
                }
                Button { pickReply("deny") } label: {
                    Label(L("Skip"), systemImage: "arrow.uturn.right").frame(maxWidth: .infinity)
                }
                .help(L("Not sure yet: set it aside without answering"))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(busy)
            if let error {
                Text(error).agentFont(.caption).foregroundColor(.red)
            }
        }
    }

    private func pickReply(_ action: String) {
        busy = true
        Task {
            error = await client.decide(id: p.id, action: action)
            busy = false
        }
    }

    /// An assistant's multiple-choice question: one button per option.
    private var choiceBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundColor(.accentColor)
                Text(L("%@ assistant asks", p.project))
                    .agentFont(.callout, weight: .semibold)
                Spacer(minLength: 4)
                Button {
                    AgentAssistantNav.show(project: p.project, hostKey: client.hostKey, focusCard: p.id)
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderless)
                .help(L("Open the assistant conversation"))
            }
            Text(p.summary)
                .agentFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if showHost { hostLabel }
            AgentChoiceButtons(choiceId: p.id, options: p.options ?? [], busy: $busy, error: $error)
            if let error {
                Text(error).agentFont(.caption).foregroundColor(.red)
            }
        }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: p.isHighRisk ? "exclamationmark.shield.fill" : "lock.shield")
                    .foregroundColor(accent)
                Text(L("%@ · %@ needs permission", p.project, p.tabTitle.isEmpty ? String(p.sessionId.prefix(8)) : p.tabTitle))
                    .agentFont(.callout, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    closedNotice = !AgentDecisionPanel.reveal(tmuxSession: p.tmuxSession)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help(L("Show this tab"))
                .disabled(p.tmuxSession.isEmpty)
            }

            if showHost { hostLabel }
            Text(p.summary)
                .agentFont(.caption, design: .monospaced)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 4) {
                Text(p.levelName).agentFont(.caption, weight: .bold).foregroundColor(accent)
                Text("·").agentFont(.caption).foregroundColor(.secondary)
                Text(p.reason).agentFont(.caption)
                if p.isHighRisk {
                    Text(L("· needs a second confirmation")).agentFont(.caption).foregroundColor(.red)
                }
            }

            if p.isDiscussing {
                Label(L("Under discussion — will not time out"), systemImage: "bubble.left.and.bubble.right")
                    .agentFont(.caption2)
                    .foregroundColor(.blue)
            } else {
                Text(L("Denied automatically in %d min", minutesLeft))
                    .agentFont(.caption2)
                    .foregroundColor(.secondary)
            }
            if closedNotice {
                Text(L("That conversation has been closed; it can't be shown."))
                    .agentFont(.caption2)
                    .foregroundColor(.orange)
            }

            if askingReason {
                HStack {
                    TextField(L("Reason (sent to the conversation)"), text: $reason)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send("deny", reason) }
                    Button(L("Deny")) { send("deny", reason) }
                }
            }

            HStack(spacing: 6) {
                if p.isConfirming {
                    Button(L("Yes, allow")) { send("confirm") }
                        .keyboardShortcut(.defaultAction)
                        .tint(.red)
                    Button(L("Cancel")) { send("cancel") }
                } else {
                    Button(p.isHighRisk ? L("Allow…") : L("Allow")) { send("allow") }
                        .tint(.green)
                }
                Button(L("Deny")) { send("deny") }
                Button(L("Deny with reason…")) { askingReason.toggle() }
                    .buttonStyle(.borderless)
                    .agentFont(.caption)
                if !p.isDiscussing {
                    Button {
                        send("discuss")
                    } label: {
                        Label(L("Discuss"), systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderless)
                    .agentFont(.caption)
                    .help(L("Keep this request open without a time limit while you talk it over"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy)

            if p.canAlways, let pattern = p.alwaysPattern {
                Button {
                    send("always")
                } label: {
                    Text(L("Always allow in this project: %@", pattern))
                        .agentFont(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .disabled(busy)
            }

            if let error {
                Text(error).agentFont(.caption).foregroundColor(.red)
            }
        }
    }

    private var hostLabel: some View {
        Label(client.hostName, systemImage: client.isLocal ? "laptopcomputer" : "server.rack")
            .agentFont(.caption2)
            .foregroundColor(.secondary)
    }

    private func send(_ action: String, _ message: String = "") {
        busy = true
        error = nil
        Task {
            let err = await client.decide(p, action: action, message: message)
            busy = false
            error = err
            // Discussing happens in the project's assistant conversation.
            if action == "discuss", err == nil {
                AgentAssistantNav.show(project: p.project, hostKey: client.hostKey)
            }
        }
    }
}

private struct CardsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
