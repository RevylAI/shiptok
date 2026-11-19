import Foundation
import Observation

struct UserSettings: Codable, Equatable, Sendable {
    var showsGoodVibesFeedbackBox: Bool
    var showsBadVibesFeedbackBox: Bool
    var showsOnlyPullRequestsWithVideos: Bool

    static let defaults = UserSettings(showsGoodVibesFeedbackBox: false, showsBadVibesFeedbackBox: true, showsOnlyPullRequestsWithVideos: true)

    enum CodingKeys: String, CodingKey {
        case showsGoodVibesFeedbackBox = "shows_good_vibes_feedback_box"
        case showsBadVibesFeedbackBox = "shows_bad_vibes_feedback_box"
        case showsOnlyPullRequestsWithVideos = "shows_only_pull_requests_with_videos"
    }
}

extension UserSettings {
    // Revyl's backend may not return Videos only yet, and it's on until the person turns it off (AGENTS.md, "Feed Order").
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsGoodVibesFeedbackBox = try container.decode(Bool.self, forKey: .showsGoodVibesFeedbackBox)
        showsBadVibesFeedbackBox = try container.decode(Bool.self, forKey: .showsBadVibesFeedbackBox)
        showsOnlyPullRequestsWithVideos = try container.decodeIfPresent(Bool.self, forKey: .showsOnlyPullRequestsWithVideos)
            ?? Self.defaults.showsOnlyPullRequestsWithVideos
    }
}

@Observable
@MainActor
final class UserSettingsStore {
    private(set) var userSettings = UserSettings.defaults
    private(set) var refreshFailureMessage: String?
    var saveFailureMessage: String?
    // What Revyl's backend last confirmed, so a failed save puts a setting back to what's saved, not to what showed before a toggle whose own save may have failed too.
    private var lastConfirmedUserSettings = UserSettings.defaults
    private var localChangeGeneration = 0
    private var latestSave: Task<Void, Error>?
    private let accessTokenVault: GitHubAccessTokenVault
    private let shipTokAPI = RevylShipTokAPI()

    init(accessTokenVault: GitHubAccessTokenVault) {
        self.accessTokenVault = accessTokenVault
    }

    func showsFeedbackBox(for vibe: PullRequestVibe) -> Bool {
        userSettings[keyPath: Self.feedbackBoxSetting(for: vibe)]
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
            lastConfirmedUserSettings = savedUserSettings
        } catch {
            if Task.isCancelled { return }
            refreshFailureMessage = error.localizedDescription
        }
    }

    func setShowsFeedbackBox(_ showsFeedbackBox: Bool, for vibe: PullRequestVibe) async {
        await setSetting(Self.feedbackBoxSetting(for: vibe), to: showsFeedbackBox)
    }

    func setShowsOnlyPullRequestsWithVideos(_ showsOnlyPullRequestsWithVideos: Bool) async {
        await setSetting(\.showsOnlyPullRequestsWithVideos, to: showsOnlyPullRequestsWithVideos)
    }

    private func setSetting(_ setting: WritableKeyPath<UserSettings, Bool>, to newValue: Bool) async {
        guard newValue != userSettings[keyPath: setting] else { return }
        localChangeGeneration += 1
        userSettings[keyPath: setting] = newValue
        defer { localChangeGeneration += 1 }
        // Saves replace every setting, so they run one at a time and each sends the settings as they stand when its turn comes; a quick second toggle can't be overwritten by the first one's older copy.
        let previousSave = latestSave
        let save = Task {
            _ = await previousSave?.result
            let userSettingsToSave = userSettings
            _ = try await accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
                try await shipTokAPI.replaceUserSettings(userSettingsToSave, gitHubAccessToken: accessToken)
            }
            lastConfirmedUserSettings = userSettingsToSave
        }
        latestSave = save
        do {
            try await save.value
        } catch {
            if userSettings[keyPath: setting] == newValue {
                userSettings[keyPath: setting] = lastConfirmedUserSettings[keyPath: setting]
            }
            saveFailureMessage = "The setting is back to its saved value. \(error.localizedDescription)"
        }
    }

    private static func feedbackBoxSetting(for vibe: PullRequestVibe) -> WritableKeyPath<UserSettings, Bool> {
        switch vibe {
        case .good: \.showsGoodVibesFeedbackBox
        case .bad: \.showsBadVibesFeedbackBox
        }
    }
}
