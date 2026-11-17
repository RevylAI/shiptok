import Foundation
import Observation

struct UserSettings: Codable, Equatable, Sendable {
    var showsGoodVibesFeedbackBox: Bool
    var showsBadVibesFeedbackBox: Bool

    static let defaults = UserSettings(showsGoodVibesFeedbackBox: false, showsBadVibesFeedbackBox: true)

    enum CodingKeys: String, CodingKey {
        case showsGoodVibesFeedbackBox = "shows_good_vibes_feedback_box"
        case showsBadVibesFeedbackBox = "shows_bad_vibes_feedback_box"
    }
}

@Observable
@MainActor
final class UserSettingsStore {
    private(set) var userSettings = UserSettings.defaults
    private(set) var refreshFailureMessage: String?
    var saveFailureMessage: String?
    private var localChangeGeneration = 0
    private var latestSave: Task<Void, Error>?
    private let accessTokenVault: GitHubAccessTokenVault
    private let shipTokAPI = RevylShipTokAPI()

    init(accessTokenVault: GitHubAccessTokenVault) {
        self.accessTokenVault = accessTokenVault
    }

    func showsFeedbackBox(for vibe: PullRequestVibe) -> Bool {
        switch vibe {
        case .good: userSettings.showsGoodVibesFeedbackBox
        case .bad: userSettings.showsBadVibesFeedbackBox
        }
    }

    func refresh() async {
        let localChangeGenerationAtFetchStart = localChangeGeneration
        do {
            let savedUserSettings = try await accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
                try await shipTokAPI.fetchUserSettings(gitHubAccessToken: accessToken)
            }
            refreshFailureMessage = nil
            guard localChangeGeneration == localChangeGenerationAtFetchStart else { return }
            userSettings = savedUserSettings
        } catch {
            if Task.isCancelled { return }
            refreshFailureMessage = error.localizedDescription
        }
    }

    func setShowsFeedbackBox(_ showsFeedbackBox: Bool, for vibe: PullRequestVibe) async {
        let previousShowsFeedbackBox = self.showsFeedbackBox(for: vibe)
        guard showsFeedbackBox != previousShowsFeedbackBox else { return }
        localChangeGeneration += 1
        applyShowsFeedbackBox(showsFeedbackBox, for: vibe)
        defer { localChangeGeneration += 1 }
        // Saves replace every setting, so they run one at a time and each sends the settings as they stand when its turn comes; a quick second toggle can't be overwritten by the first one's older copy.
        let previousSave = latestSave
        let save = Task {
            _ = await previousSave?.result
            let userSettingsToSave = userSettings
            _ = try await accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
                try await shipTokAPI.replaceUserSettings(userSettingsToSave, gitHubAccessToken: accessToken)
            }
        }
        latestSave = save
        do {
            try await save.value
        } catch {
            if self.showsFeedbackBox(for: vibe) == showsFeedbackBox {
                applyShowsFeedbackBox(previousShowsFeedbackBox, for: vibe)
            }
            saveFailureMessage = "The setting is back to how it was. \(error.localizedDescription)"
        }
    }

    private func applyShowsFeedbackBox(_ showsFeedbackBox: Bool, for vibe: PullRequestVibe) {
        switch vibe {
        case .good: userSettings.showsGoodVibesFeedbackBox = showsFeedbackBox
        case .bad: userSettings.showsBadVibesFeedbackBox = showsFeedbackBox
        }
    }
}
