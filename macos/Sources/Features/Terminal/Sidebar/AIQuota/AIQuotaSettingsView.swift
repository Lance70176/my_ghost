import SwiftUI

/// Settings sheet for AI quota accounts: master visibility toggle, the list
/// of configured accounts (with per-account visibility), and add/edit/delete.
struct AIQuotaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: AIQuotaManager

    /// The account being edited in the form sheet.
    @State private var editingAccount: AIQuotaAccount?
    /// Whether the form sheet is creating a new account (vs. editing).
    @State private var isAddingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Usage Accounts")
                .font(.headline)

            Toggle("Show AI usage above the sidebar menu", isOn: $manager.showInSidebar)

            Divider()

            if manager.accounts.isEmpty {
                Text("No accounts yet. Add a Claude Code or ChatGPT account to track its quota.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.accounts) { account in
                            accountRow(account)
                        }
                    }
                }
                .frame(minHeight: 60, maxHeight: 220)
            }

            HStack {
                Button {
                    isAddingNew = true
                    editingAccount = AIQuotaAccount(name: "", provider: .claudeCode)
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheet(item: $editingAccount) { account in
            AIQuotaAccountForm(
                account: account,
                isNew: isAddingNew,
                onSave: { saved in
                    if let index = manager.accounts.firstIndex(where: { $0.id == saved.id }) {
                        manager.accounts[index] = saved
                    } else {
                        manager.accounts.append(saved)
                    }
                    manager.refresh(saved)
                })
        }
    }

    @ViewBuilder
    private func accountRow(_ account: AIQuotaAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.symbolName)
                .foregroundColor(account.provider == .claudeCode ? .orange : .green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                    .font(.body)
                Text("\(account.provider.displayName) · \(account.authMode.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: visibilityBinding(for: account.id))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Show in sidebar")

            Button {
                isAddingNew = false
                editingAccount = account
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit account")

            Button {
                manager.accounts.removeAll { $0.id == account.id }
                manager.snapshots.removeValue(forKey: account.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete account")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    private func visibilityBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { manager.accounts.first(where: { $0.id == id })?.isVisible ?? false },
            set: { newValue in
                guard let index = manager.accounts.firstIndex(where: { $0.id == id }) else { return }
                manager.accounts[index].isVisible = newValue
            })
    }
}

// MARK: - Add / edit form

/// Form for one account: provider, credential source, and (for manual mode)
/// the pasted token.
private struct AIQuotaAccountForm: View {
    @Environment(\.dismiss) private var dismiss

    @State var account: AIQuotaAccount
    let isNew: Bool
    let onSave: (AIQuotaAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Account" : "Edit Account")
                .font(.headline)

            Form {
                TextField("Name:", text: $account.name, prompt: Text(defaultName))

                Picker("Service:", selection: $account.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Picker("Credential:", selection: $account.authMode) {
                    ForEach(AIQuotaAuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if account.authMode == .manualToken {
                    SecureField("Token:", text: $account.token, prompt: Text(tokenPrompt))
                    if account.provider == .chatGPT {
                        TextField(
                            "Account ID:", text: $account.accountID,
                            prompt: Text("optional — read from token if empty"))
                    }
                }

                Toggle("Show in sidebar", isOn: $account.isVisible)
            }

            Text(credentialHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var saved = account
                    let trimmed = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.name = trimmed.isEmpty ? defaultName : trimmed
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var defaultName: String {
        account.provider.displayName
    }

    private var canSave: Bool {
        account.authMode == .localLogin
            || !account.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tokenPrompt: String {
        switch account.provider {
        case .claudeCode: return "sk-ant-oat01-…"
        case .chatGPT: return "eyJhbGciOi… (access token)"
        }
    }

    private var credentialHint: String {
        switch (account.provider, account.authMode) {
        case (.claudeCode, .localLogin):
            return "Uses the Claude Code CLI login on this Mac (keychain item "
                + "\"Claude Code-credentials\"). The first query may ask for keychain access."
        case (.claudeCode, .manualToken):
            return "Paste an OAuth access token (sk-ant-oat01-…), e.g. from another "
                + "machine's ~/.claude/.credentials.json. Tokens expire and may need re-pasting."
        case (.chatGPT, .localLogin):
            return "Uses the Codex CLI login on this Mac (~/.codex/auth.json)."
        case (.chatGPT, .manualToken):
            return "Paste the access_token from ~/.codex/auth.json of the account "
                + "to track. Tokens expire and may need re-pasting."
        }
    }
}
