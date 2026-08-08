import Foundation

/// The AI service a quota account belongs to.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude_code"
    case chatGPT = "chatgpt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .chatGPT: return "ChatGPT"
        }
    }

    /// SF Symbol used in the sidebar row.
    var symbolName: String {
        switch self {
        case .claudeCode: return "asterisk"
        case .chatGPT: return "sparkles"
        }
    }
}

/// How the account's credential is obtained.
enum AIQuotaAuthMode: String, Codable, CaseIterable, Identifiable {
    /// Read the credential from the locally logged-in CLI
    /// (Claude Code keychain / ~/.claude, Codex ~/.codex/auth.json).
    case localLogin = "local"
    /// Use a token the user pasted in settings.
    case manualToken = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localLogin: return "Local login"
        case .manualToken: return "Manual token"
        }
    }
}

/// One configured account whose usage/quota can be queried.
struct AIQuotaAccount: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var provider: AIProvider
    var authMode: AIQuotaAuthMode = .localLogin
    /// OAuth access token (manual mode). Claude: sk-ant-oat01-…;
    /// ChatGPT: the access_token JWT from ~/.codex/auth.json.
    var token: String = ""
    /// ChatGPT only: the chatgpt-account-id header value. Optional for
    /// personal accounts (derived from the JWT when possible).
    var accountID: String = ""
    /// Whether this account's row is shown in the sidebar section.
    var isVisible: Bool = true
    /// Window labels switched off for this account. Labels come from the API
    /// response, so an entry can outlive the window that produced it.
    var hiddenWindows: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, authMode, token, accountID, isVisible, hiddenWindows
    }
}

// Decoding is hand-written so a settings file written by an older build still
// loads: the synthesized decoder throws on a key that didn't exist when the
// file was saved, which would drop every configured account rather than just
// the new field.
extension AIQuotaAccount {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        provider = try container.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .claudeCode
        authMode = try container.decodeIfPresent(
            AIQuotaAuthMode.self, forKey: .authMode) ?? .localLogin
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        hiddenWindows = try container.decodeIfPresent(
            Set<String>.self, forKey: .hiddenWindows) ?? []
    }
}

/// A single rate-limit window (e.g. the 5-hour or weekly window).
struct AIUsageWindow: Equatable {
    var label: String
    /// 0…100 percent used.
    var usedPercent: Double
    /// When the window resets, if known.
    var resetsAt: Date?
}

/// The result of the most recent usage query for an account.
struct AIUsageSnapshot: Equatable {
    var windows: [AIUsageWindow] = []
    var fetchedAt: Date
    var errorMessage: String?

    var isError: Bool { errorMessage != nil }
}
