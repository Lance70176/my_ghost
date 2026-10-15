import AppKit
import SwiftUI

/// The ✦ sidebar's "New assistant" form: a project folder, its own Telegram
/// bot and group, who may command it, and whether it runs all the time.
/// ghost-agentd writes the project.yaml and brings the bot up at once.
struct AgentNewAssistantSheet: View {
    @ObservedObject var client: AgentDaemonClient
    /// Called with the new project's name once it exists.
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var path = ""
    @State private var token = ""
    @State private var commanders = ""
    @State private var resident = true
    @State private var chatID = ""

    @State private var probing = false
    @State private var bot: String?
    @State private var privacy = false
    @State private var usedBy: [String] = []
    @State private var groups: [Group] = []
    @State private var probeNote: String?

    @State private var saving = false
    @State private var error: String?

    struct Group: Identifiable, Hashable {
        let id: Int64
        let title: String
        let members: Int?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("New project assistant"))
                .agentFont(.title3, weight: .semibold)

            field(L("Project name")) {
                TextField("claude", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text(L("Letters, digits, _ . - only. Used as its folder name."))
                    .agentFont(.caption).foregroundColor(.secondary)
            }

            field(L("Project folder")) {
                HStack {
                    TextField("/Users/…/projects/claude", text: $path)
                        .textFieldStyle(.roundedBorder)
                    if client.isLocal {
                        Button(L("Choose…")) { choose() }
                    }
                }
                Text(L("Every conversation under this folder belongs to this assistant."))
                    .agentFont(.caption).foregroundColor(.secondary)
            }

            field(L("Telegram bot token")) {
                HStack {
                    SecureField(L("From @BotFather (optional)"), text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: token) { _ in bot = nil; groups = []; probeNote = nil }
                    Button(L("Check")) { Task { await probe() } }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || probing)
                    if probing { ProgressView().controlSize(.small) }
                }
                if let bot {
                    Label(bot + (usedBy.isEmpty ? "" : " · " + L("also serves %@", usedBy.joined(separator: ", "))),
                          systemImage: "checkmark.seal.fill")
                        .agentFont(.caption).foregroundColor(.green)
                    if privacy {
                        Text(L("Privacy mode is on: make the bot an admin of the group, or it only sees /commands."))
                            .agentFont(.caption).foregroundColor(.orange)
                    }
                }
                if let probeNote {
                    Text(probeNote).agentFont(.caption).foregroundColor(.secondary)
                }
            }

            if bot != nil {
                field(L("Project group")) {
                    if !groups.isEmpty {
                        Picker("", selection: $chatID) {
                            ForEach(groups) { g in
                                Text(groupLabel(g)).tag(String(g.id))
                            }
                            Text(L("Bind it later with /chatid")).tag("")
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    } else {
                        TextField(L("chat_id (blank: send /chatid in the group later)"), text: $chatID)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let g = groups.first(where: { String($0.id) == chatID }), let n = g.members, n > 2 {
                        Text(L("This group has %d members. Everyone in it reads what the assistant says there.", n))
                            .agentFont(.caption).foregroundColor(.orange)
                    }
                }

                field(L("Members besides you")) {
                    TextField(L("Telegram user ids, comma separated (optional)"),
                              text: $commanders)
                        .textFieldStyle(.roundedBorder)
                    Text(L("You can always command it. Members may talk to it and press the cards from their own requests; add more later by replying to their message with /addmember in the group. Anyone else is ignored."))
                        .agentFont(.caption).foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $resident) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Watch all the time (resident)"))
                    Text(L("Off: it wakes on events and sleeps after 30 idle minutes."))
                        .agentFont(.caption).foregroundColor(.secondary)
                }
            }

            if let error {
                Text(error).agentFont(.callout).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Create")) { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.isEmpty || path.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).agentFont(.callout, weight: .semibold)
            content()
        }
    }

    private func groupLabel(_ g: Group) -> String {
        var s = g.title.isEmpty ? String(g.id) : "\(g.title)  (\(g.id))"
        if let n = g.members { s += " · " + L("%d members", n) }
        return s
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("projects")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        if name.isEmpty {
            name = url.lastPathComponent.filter { $0.isLetter || $0.isNumber || "_.-".contains($0) }
        }
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        error = nil
        guard let r = await client.postJSON("api/projects/probe", ["token": token.trimmingCharacters(in: .whitespaces)]) else {
            error = L("ghost-agentd is not reachable")
            return
        }
        guard r["ok"] as? Bool == true else {
            bot = nil
            error = r["message"] as? String
            return
        }
        bot = r["bot"] as? String
        privacy = r["privacy"] as? Bool ?? false
        usedBy = r["used_by"] as? [String] ?? []
        probeNote = r["message"] as? String
        groups = (r["groups"] as? [[String: Any]] ?? []).compactMap { g in
            guard let id = (g["id"] as? NSNumber)?.int64Value else { return nil }
            return Group(id: id, title: g["title"] as? String ?? "", members: (g["members"] as? NSNumber)?.intValue)
        }
        if groups.count == 1 { chatID = String(groups[0].id) }
        if groups.isEmpty && probeNote == nil {
            probeNote = L("No group found yet. Add the bot to the project group (or send a message there) and check again, or leave it blank and send /chatid in the group later.")
        }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        error = nil
        let ids = commanders.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "，" })
            .map { String($0) }
        var body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "path": path.trimmingCharacters(in: .whitespaces),
            "token": token.trimmingCharacters(in: .whitespaces),
            "resident": resident,
            "commanders": ids,
        ]
        let chat = chatID.trimmingCharacters(in: .whitespaces)
        if !chat.isEmpty { body["chat_id"] = chat }
        guard let r = await client.postJSON("api/projects", body) else {
            error = L("ghost-agentd is not reachable")
            return
        }
        guard r["ok"] as? Bool == true else {
            error = r["message"] as? String ?? L("Couldn't create it")
            return
        }
        await client.refreshProjects()
        onCreated(r["project"] as? String ?? name)
        dismiss()
    }
}
