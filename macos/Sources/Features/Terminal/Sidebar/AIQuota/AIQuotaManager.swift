import Foundation
import SwiftUI

/// Manages the configured AI quota accounts, their persisted settings, and
/// the latest usage snapshot per account. Accounts (including any manually
/// entered tokens) are stored in Application Support/MyGhost with owner-only
/// permissions, matching how the CLIs store their own credentials.
@MainActor
class AIQuotaManager: ObservableObject {
    static let shared = AIQuotaManager()

    @Published var accounts: [AIQuotaAccount] = [] {
        didSet { save() }
    }

    /// Master toggle for the sidebar section.
    @Published var showInSidebar: Bool = true {
        didSet { save() }
    }

    /// Latest usage per account ID.
    @Published var snapshots: [UUID: AIUsageSnapshot] = [:]

    /// Account IDs with a fetch in flight.
    @Published var refreshing: Set<UUID> = []

    /// Accounts shown in the sidebar section.
    var visibleAccounts: [AIQuotaAccount] {
        accounts.filter(\.isVisible)
    }

    private struct PersistedState: Codable {
        var accounts: [AIQuotaAccount]
        var showInSidebar: Bool
    }

    private var stateFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MyGhost/ai_quota_accounts.json")
    }

    private var loading = false

    /// Auto-refresh interval for visible accounts.
    private static let refreshInterval: TimeInterval = 3 * 60

    private var refreshTimer: Timer?

    private init() {
        load()
        // Refresh the sidebar stats every 3 minutes so the bars track usage
        // without manual clicks. Manual refresh (row click / ⟳) still works.
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                let manager = AIQuotaManager.shared
                guard manager.showInSidebar else { return }
                manager.refreshAllVisible()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Refresh

    /// Fetch fresh usage for one account.
    func refresh(_ account: AIQuotaAccount) {
        guard !refreshing.contains(account.id) else { return }
        refreshing.insert(account.id)
        Task {
            let snapshot = await AIUsageFetcher.fetch(for: account)
            self.snapshots[account.id] = snapshot
            self.refreshing.remove(account.id)
        }
    }

    /// Fetch fresh usage for every visible account.
    func refreshAllVisible() {
        for account in visibleAccounts {
            refresh(account)
        }
    }

    // MARK: - Persistence

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        accounts = state.accounts
        showInSidebar = state.showInSidebar
    }

    private func save() {
        guard !loading else { return }
        let state = PersistedState(accounts: accounts, showInSidebar: showInSidebar)
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = stateFileURL
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // The file can contain pasted tokens — keep it owner-readable only.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
