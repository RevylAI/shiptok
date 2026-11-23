import Foundation
import Observation

struct UserSettings: Codable, Equatable, Sendable {
    var showsGoodVibesFeedbackBox: Bool
    var showsBadVibesFeedbackBox: Bool
    var showsOnlyPullRequestsWithVideos: Bool
    var showsOpenFeedModeTab: Bool
    var showsMergedFeedModeTab: Bool
    var showsWeeklyFeedModeTab: Bool
    var showsFeaturesFeedModeTab: Bool

    static let defaults = UserSettings(
        showsGoodVibesFeedbackBox: false,
        showsBadVibesFeedbackBox: true,
        showsOnlyPullRequestsWithVideos: true,
        showsOpenFeedModeTab: true,
        showsMergedFeedModeTab: true,
        showsWeeklyFeedModeTab: true,
        showsFeaturesFeedModeTab: true
    )

    enum CodingKeys: String, CodingKey {
        case showsGoodVibesFeedbackBox = "shows_good_vibes_feedback_box"
        case showsBadVibesFeedbackBox = "shows_bad_vibes_feedback_box"
        case showsOnlyPullRequestsWithVideos = "shows_only_pull_requests_with_videos"
        case showsOpenFeedModeTab = "shows_open_feed_mode_tab"
        case showsMergedFeedModeTab = "shows_merged_feed_mode_tab"
        case showsWeeklyFeedModeTab = "shows_weekly_feed_mode_tab"
        case showsFeaturesFeedModeTab = "shows_features_feed_mode_tab"
    }
}

extension UserSettings {
    // Revyl's backend may not return Videos only or the feed tabs yet, and each is on until the person turns it off (AGENTS.md, "Feed Order" and "Feed Modes").
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsGoodVibesFeedbackBox = try container.decode(Bool.self, forKey: .showsGoodVibesFeedbackBox)
        showsBadVibesFeedbackBox = try container.decode(Bool.self, forKey: .showsBadVibesFeedbackBox)
        showsOnlyPullRequestsWithVideos = try container.decodeIfPresent(Bool.self, forKey: .showsOnlyPullRequestsWithVideos)
            ?? Self.defaults.showsOnlyPullRequestsWithVideos
        showsOpenFeedModeTab = try container.decodeIfPresent(Bool.self, forKey: .showsOpenFeedModeTab) ?? Self.defaults.showsOpenFeedModeTab
        showsMergedFeedModeTab = try container.decodeIfPresent(Bool.self, forKey: .showsMergedFeedModeTab) ?? Self.defaults.showsMergedFeedModeTab
        showsWeeklyFeedModeTab = try container.decodeIfPresent(Bool.self, forKey: .showsWeeklyFeedModeTab) ?? Self.defaults.showsWeeklyFeedModeTab
        showsFeaturesFeedModeTab = try container.decodeIfPresent(Bool.self, forKey: .showsFeaturesFeedModeTab) ?? Self.defaults.showsFeaturesFeedModeTab
    }
}

@Observable
@MainActor
final class UserSettingsStore {
    private(set) var refreshFailureMessage: String?
    var saveFailureMessage: String?
    // What Revyl's backend last confirmed, by a read or a save. The settings shown are these with each setting's newest change still saving on top, so a read never shows an old value over a toggle, and a failed save puts the setting back to what's saved (AGENTS.md, "Feed Order").
    private var confirmedUserSettings = UserSettings.defaults
    private var pendingChangeBySetting: [WritableKeyPath<UserSettings, Bool>: PendingSettingChange] = [:]
    private var latestChangeRevision = 0
    private var confirmedSaveCount = 0
    private var latestSave: Task<Void, Error>?
    private let accessTokenVault: GitHubAccessTokenVault
    private let shipTokAPI = RevylShipTokAPI()

    init(accessTokenVault: GitHubAccessTokenVault) {
        self.accessTokenVault = accessTokenVault
    }

    var userSettings: UserSettings {
        var shownUserSettings = confirmedUserSettings
        for (setting, pendingChange) in pendingChangeBySetting {
            shownUserSettings[keyPath: setting] = pendingChange.value
        }
        return shownUserSettings
    }

    func showsFeedbackBox(for vibe: PullRequestVibe) -> Bool {
        userSettings[keyPath: Self.feedbackBoxSetting(for: vibe)]
    }

    var feedModesWithShownTabs: [FeedMode] {
        let shownUserSettings = userSettings
        return FeedMode.allCases.filter { shownUserSettings[keyPath: Self.feedModeTabSetting(for: $0)] }
    }

    // A read that a save overtook holds settings older than that save, so it's dropped.
    func refresh() async {
        let confirmedSaveCountAtFetchStart = confirmedSaveCount
        do {
            let savedUserSettings = try await accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
                try await shipTokAPI.fetchUserSettings(gitHubAccessToken: accessToken)
            }
            refreshFailureMessage = nil
            guard confirmedSaveCount == confirmedSaveCountAtFetchStart else { return }
            confirmedUserSettings = savedUserSettings
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

    // At least one tab stays on, which Revyl's backend refuses to break as well (AGENTS.md, "Feed Modes").
    func setShowsFeedModeTab(_ showsFeedModeTab: Bool, for feedMode: FeedMode) async {
        guard showsFeedModeTab || feedModesWithShownTabs != [feedMode] else { return }
        await setSetting(Self.feedModeTabSetting(for: feedMode), to: showsFeedModeTab)
    }

    private func setSetting(_ setting: WritableKeyPath<UserSettings, Bool>, to newValue: Bool) async {
        guard newValue != userSettings[keyPath: setting] else { return }
        latestChangeRevision += 1
        let changeRevision = latestChangeRevision
        pendingChangeBySetting[setting] = PendingSettingChange(revision: changeRevision, value: newValue)
        // Saves replace every setting, so they run one at a time and each sends the settings as they stand when its turn comes; a quick second toggle can't be overwritten by the first one's older copy.
        let previousSave = latestSave
        let save = Task {
            _ = await previousSave?.result
            let userSettingsToSave = userSettings
            _ = try await accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
                try await shipTokAPI.replaceUserSettings(userSettingsToSave, gitHubAccessToken: accessToken)
            }
            confirmedUserSettings = userSettingsToSave
            confirmedSaveCount += 1
        }
        latestSave = save
        let saveResult = await save.result
        // Only the setting's newest change settles it, so an older tap's failure never undoes a newer one.
        if pendingChangeBySetting[setting]?.revision == changeRevision {
            pendingChangeBySetting[setting] = nil
        }
        if case .failure(let error) = saveResult {
            saveFailureMessage = "The setting is back to its saved value. \(error.localizedDescription)"
        }
    }

    private struct PendingSettingChange {
        let revision: Int
        let value: Bool
    }

    private static func feedbackBoxSetting(for vibe: PullRequestVibe) -> WritableKeyPath<UserSettings, Bool> {
        switch vibe {
        case .good: \.showsGoodVibesFeedbackBox
        case .bad: \.showsBadVibesFeedbackBox
        }
    }

    private static func feedModeTabSetting(for feedMode: FeedMode) -> WritableKeyPath<UserSettings, Bool> {
        switch feedMode {
        case .open: \.showsOpenFeedModeTab
        case .merged: \.showsMergedFeedModeTab
        case .weekly: \.showsWeeklyFeedModeTab
        case .features: \.showsFeaturesFeedModeTab
        }
    }
}
