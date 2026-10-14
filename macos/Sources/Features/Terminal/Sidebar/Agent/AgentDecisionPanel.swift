import AppKit
import Combine
import SwiftUI

/// The bottom-right decision cards: one per permission request ghost-agentd
/// is holding. A non-activating panel, so a card appearing never steals focus
/// from the terminal being typed in, and it stays up while another app is in
/// front — the request is blocked until someone answers it somewhere.
@MainActor
final class AgentDecisionPanel {
    static let shared = AgentDecisionPanel()

    private var panel: NSPanel?
    private var contentSize = CGSize(width: 360, height: 160)
    private var cancellables = Set<AnyCancellable>()
    private var seenIDs = Set<String>()

    private init() {}

    func start() {
        let hub = AgentHub.shared
        hub.start()
        hub.$allPending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in self?.update(pending) }
            .store(in: &cancellables)
    }

    private func update(_ pending: [AgentHostPending]) {
        guard !pending.isEmpty else {
            panel?.orderOut(nil)
            seenIDs.removeAll()
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let fresh = pending.contains { !seenIDs.contains($0.id) }
        seenIDs = Set(pending.map(\.id))
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
        let size = contentSize
        let anchor: NSRect
        if let win = NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is SidebarTerminalController }) {
            anchor = win.frame
        } else {
            anchor = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        }
        let width = min(max(size.width, 340), 420)
        let height = min(size.height, anchor.height - 40)
        panel.setFrame(NSRect(x: anchor.maxX - width - 16, y: anchor.minY + 16,
                              width: width, height: height), display: true)
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(hub.allPending.suffix(3)) { hp in
                AgentDecisionCard(p: hp.pending, showHost: hub.clients.count > 1 || !hp.client.isLocal)
                    .environmentObject(hp.client)
            }
            if hub.allPending.count > 3 {
                Text(L("%d more waiting", hub.allPending.count - 3))
                    .font(.caption)
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
    var width: CGFloat = 344
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
        let end = deadline ?? Date().addingTimeInterval(TimeInterval(p.remaining))
        return max(0, Int(end.timeIntervalSince(now)) / 60)
    }

    private var accent: Color {
        p.isChoice ? .accentColor : (p.isHighRisk ? .red : (p.level >= 2 ? .orange : .green))
    }

    var body: some View {
        Group {
            if p.isChoice { choiceBody } else { permissionBody }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.6), lineWidth: 1))
        )
        .onReceive(tick) { now = $0 }
        .onAppear { deadline = Date().addingTimeInterval(TimeInterval(p.remaining)) }
    }

    /// An assistant's multiple-choice question: one button per option.
    private var choiceBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundColor(.accentColor)
                Text(L("%@ assistant asks", p.project))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Button {
                    AgentAssistantNav.show(project: p.project, hostKey: client.hostKey)
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderless)
                .help(L("Open the assistant conversation"))
            }
            Text(p.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if showHost { hostLabel }
            AgentChoiceButtons(choiceId: p.id, options: p.options ?? [], busy: $busy, error: $error)
            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: p.isHighRisk ? "exclamationmark.shield.fill" : "lock.shield")
                    .foregroundColor(accent)
                Text(L("%@ · %@ needs permission", p.project, p.tabTitle.isEmpty ? String(p.sessionId.prefix(8)) : p.tabTitle))
                    .font(.callout.weight(.semibold))
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
                .font(.system(.caption, design: .monospaced))
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 4) {
                Text(p.levelName).font(.caption.weight(.bold)).foregroundColor(accent)
                Text("·").font(.caption).foregroundColor(.secondary)
                Text(p.reason).font(.caption)
                if p.isHighRisk {
                    Text(L("· needs a second confirmation")).font(.caption).foregroundColor(.red)
                }
            }

            if p.isDiscussing {
                Label(L("Under discussion — will not time out"), systemImage: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundColor(.blue)
            } else {
                Text(L("Denied automatically in %d min", minutesLeft))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if closedNotice {
                Text(L("That conversation has been closed; it can't be shown."))
                    .font(.caption2)
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
                    .font(.caption)
                if !p.isDiscussing {
                    Button {
                        send("discuss")
                    } label: {
                        Label(L("Discuss"), systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
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
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .disabled(busy)
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
    }

    private var hostLabel: some View {
        Label(client.hostName, systemImage: client.isLocal ? "laptopcomputer" : "server.rack")
            .font(.caption2)
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
