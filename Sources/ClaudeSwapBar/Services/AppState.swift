import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var usage: [UUID: UsageSnapshot] = [:]
    @Published private(set) var usageProblems: [UUID: UsageProblem] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshingUsage = false
    @Published var errorMessage: String?
    @Published var lastAction: String?
    @Published var claudeRestartPending = false

    @AppStorage("refreshIntervalMinutes") var refreshIntervalMinutes = 5
    @AppStorage("didImportFromCSwap") private var didImportFromCSwap = false

    private let vault = Vault()
    private let bridge = ClaudeCodeBridge()
    private let oauth = OAuthService()
    private let usageService = UsageService()
    private var refreshTimer: Timer?

    var activeAccount: Account? {
        accounts.first { $0.id == activeAccountID }
    }

    init() {
        importFromCSwapIfNeeded()
        reload()
        restartUsageTimer()
    }

    // MARK: - Loading

    func reload() {
        accounts = vault.loadAccounts()
        detectActiveAccount()
    }

    /// Matches the vault against what Claude Code is logged in as right now.
    private func detectActiveAccount() {
        guard let profile = try? bridge.currentProfileJSON() else {
            activeAccountID = nil
            return
        }
        activeAccountID = accounts.first {
            $0.email.caseInsensitiveCompare(profile.email) == .orderedSame
        }?.id
    }

    private func importFromCSwapIfNeeded() {
        guard !didImportFromCSwap else { return }
        didImportFromCSwap = true

        let importer = CSwapImporter()
        guard importer.isAvailable, vault.loadAccounts().isEmpty else { return }
        let imported = importer.importAccounts()
        for entry in imported {
            try? vault.upsert(entry.account, credentials: entry.credentials)
        }
        if !imported.isEmpty {
            lastAction = "Imported \(imported.count) account\(imported.count == 1 ? "" : "s") from cswap"
        }
    }

    // MARK: - Usage

    func refreshUsage(force: Bool = false) async {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }

        // The active account's credential is owned by Claude Code while it
        // runs: read the freshest token from the live store, never refresh it
        // ourselves. Inactive accounts are ours to refresh freely.
        let claudeRunning = bridge.isClaudeCodeRunning()
        let activeID = activeAccountID

        let work: [(Account, OAuthCredentials?)] = accounts.map { account in
            if account.id == activeID, let live = try? bridge.currentCredentials() {
                // Opportunistically sync Claude Code's rotations back into our vault.
                try? vault.storeCredentials(live, for: account.id)
                return (account, live)
            }
            return (account, try? vault.credentials(for: account.id))
        }

        await withTaskGroup(of: (UUID, Result<UsageSnapshot, UsageProblem>).self) { group in
            for (account, storedCredentials) in work {
                guard force || usage[account.id]?.isStale != false else { continue }
                guard var credentials = storedCredentials else {
                    usageProblems[account.id] = .tokenExpired
                    continue
                }
                let isActive = account.id == activeID
                group.addTask { [vault, oauth, usageService] in
                    do {
                        if credentials.isAccessTokenExpired {
                            if isActive && claudeRunning {
                                // Claude Code will refresh its own token on next use.
                                return (account.id, .failure(.tokenExpired))
                            }
                            credentials = try await oauth.refresh(credentials)
                            try? vault.storeCredentials(credentials, for: account.id)
                        }
                        let snapshot = try await usageService.fetchUsage(accessToken: credentials.accessToken)
                        return (account.id, .success(snapshot))
                    } catch let error as OAuthService.RefreshError {
                        switch error {
                        case .invalidGrant: return (account.id, .failure(.tokenExpired))
                        case let .transient(message): return (account.id, .failure(.network(message)))
                        }
                    } catch let error as UsageService.UsageError {
                        return (account.id, .failure(error.asProblem))
                    } catch {
                        return (account.id, .failure(.network(error.localizedDescription)))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case let .success(snapshot):
                    usage[id] = snapshot
                    usageProblems[id] = nil
                case let .failure(problem):
                    usageProblems[id] = problem
                }
            }
        }
    }

    func restartUsageTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(3, refreshIntervalMinutes)) * 60
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshUsage()
            }
        }
    }

    // MARK: - Switching

    func switchTo(_ account: Account) async {
        guard account.id != activeAccountID else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // Sync back whatever Claude Code holds right now, so the account
            // we're leaving keeps its freshest refresh-token lineage.
            syncActiveCredentialsIntoVault()

            var credentials = try vault.credentials(for: account.id)
            if credentials.isAccessTokenExpired {
                credentials = try await oauth.refresh(credentials)
                try vault.storeCredentials(credentials, for: account.id)
            }
            try bridge.activate(credentials: credentials, profileJSON: account.oauthAccountJSON)
            activeAccountID = account.id
            lastAction = "Switched to \(account.displayName)"
            claudeRestartPending = true
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func rotate(smart: Bool) async {
        guard accounts.count > 1 else { return }
        let candidates = accounts.filter { $0.id != activeAccountID }

        let target: Account?
        if smart {
            // Most 5h headroom wins; accounts with unknown usage sort last.
            target = candidates.max { headroom($0) < headroom($1) }
        } else {
            let currentIndex = accounts.firstIndex { $0.id == activeAccountID } ?? 0
            target = accounts[(currentIndex + 1) % accounts.count]
        }
        if let target { await switchTo(target) }
    }

    private func headroom(_ account: Account) -> Double {
        guard let five = usage[account.id]?.fiveHour else { return -1 }
        return 100 - five.utilization
    }

    private func syncActiveCredentialsIntoVault() {
        guard let active = activeAccount,
              let current = try? bridge.currentCredentials() else { return }
        try? vault.storeCredentials(current, for: active.id)
    }

    // MARK: - Account management

    /// Adds whatever account Claude Code is currently logged in as.
    func addCurrentClaudeAccount() {
        do {
            let credentials = try bridge.currentCredentials()
            let profile = try bridge.currentProfileJSON()
            let account = Account(
                id: UUID(),
                email: profile.email,
                organizationName: profile.organizationName,
                accountUuid: profile.accountUuid,
                subscriptionType: credentials.subscriptionType,
                addedAt: Date(),
                oauthAccountJSON: profile.json
            )
            try vault.upsert(account, credentials: credentials)
            reload()
            lastAction = "Added \(profile.email)"
            errorMessage = nil
            Task { await refreshUsage(force: true) }
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func remove(_ account: Account) {
        do {
            try vault.remove(account)
            usage[account.id] = nil
            usageProblems[account.id] = nil
            reload()
            lastAction = "Removed \(account.displayName)"
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    // MARK: - Helpers

    private func friendlyMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
