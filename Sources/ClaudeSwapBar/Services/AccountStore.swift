import Foundation
import SwiftUI

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeNumber: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var lastAction: String?

    private let client = CSwapClient()

    var activeAccount: Account? {
        accounts.first { $0.active }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let client = client
        do {
            let list = try await runOffMain { try client.list() }
            accounts = list.accounts
            activeNumber = list.activeAccountNumber
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func switchTo(_ account: Account) async {
        guard !account.active else { return }
        let client = client
        let number = account.number
        await perform("Switched to \(account.shortName)") {
            try client.switchTo(number: number)
        }
    }

    func rotate(strategy: CSwapClient.Strategy?) async {
        let label = strategy.map { "Rotated (\($0.rawValue))" } ?? "Rotated to next account"
        let client = client
        await perform(label) {
            try client.rotate(strategy: strategy)
        }
    }

    // MARK: - Helpers

    private func perform(_ successMessage: String, _ work: @escaping @Sendable () throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await runOffMain(work)
            lastAction = successMessage
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Run a blocking call off the main actor and return its result.
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }
}
