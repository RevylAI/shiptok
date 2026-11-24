import Foundation
import Observation

// The GitHub account whose pull requests Revyl makes this person the developer of, in their organization. One member sets each account, and owners and admins can change anyone's on the web, so Settings reads it each time it opens (AGENTS.md, "Settings").
@Observable
@MainActor
final class GitHubAccountStore: RevylSettingsStore {
    // Nil until Revyl's first answer.
    private(set) var githubAccountSetting: GitHubAccountSetting?
    private(set) var refreshFailureMessage: String?
    private(set) var isChanging = false
    var changeFailureMessage: String?
    private var confirmedChangeCount = 0
    private var readAfterFailedChange: Task<Void, Never>?
    private let api: RevylShipTokAPI

    init(api: RevylShipTokAPI) {
        self.api = api
    }

    // A read that a change overtook holds the account from before it, so it's dropped.
    func refresh() async {
        let confirmedChangeCountAtFetchStart = confirmedChangeCount
        do {
            let fetchedGitHubAccountSetting = try await api.fetchGitHubAccountSetting()
            refreshFailureMessage = nil
            guard confirmedChangeCount == confirmedChangeCountAtFetchStart else { return }
            githubAccountSetting = fetchedGitHubAccountSetting
        } catch {
            if Task.isCancelled { return }
            refreshFailureMessage = error.localizedDescription
        }
    }

    func saveGitHubAccount(username: String) async -> Bool {
        await changeGitHubAccount { [api] in
            try await api.saveGitHubAccount(username: username)
        }
    }

    func removeGitHubAccount() async -> Bool {
        await changeGitHubAccount { [api] in
            try await api.removeGitHubAccount()
            return GitHubAccountSetting(githubAccount: nil)
        }
    }

    private func changeGitHubAccount(_ changeOnRevyl: @Sendable () async throws -> GitHubAccountSetting) async -> Bool {
        guard !isChanging else { return false }
        readAfterFailedChange?.cancel()
        isChanging = true
        defer { isChanging = false }
        changeFailureMessage = nil
        do {
            githubAccountSetting = try await changeOnRevyl()
            confirmedChangeCount += 1
            return true
        } catch {
            changeFailureMessage = error.localizedDescription
            readAfterFailedChange = Task { await readSavedSettingsAfterFailedSave() }
            return false
        }
    }
}
