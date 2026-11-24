import Foundation
import Observation

struct UserSettings: Codable, Equatable, Sendable {
    var showsGoodVibesFeedbackBox: Bool
    var showsBadVibesFeedbackBox: Bool
    var showsOnlyPostsWithVideos: Bool
    var showsOpenFeedModeTab: Bool
    var showsMergedFeedModeTab: Bool
    var showsWeeklyFeedModeTab: Bool
    var showsFeaturesFeedModeTab: Bool

    // What Revyl answers for a person who never changed a setting, shown until its first answer arrives.
    static let defaults = UserSettings(
        showsGoodVibesFeedbackBox: false,
        showsBadVibesFeedbackBox: true,
        showsOnlyPostsWithVideos: true,
        showsOpenFeedModeTab: true,
        showsMergedFeedModeTab: true,
        showsWeeklyFeedModeTab: true,
        showsFeaturesFeedModeTab: true
    )

    private enum CodingKeys: String, CodingKey {
        case showsGoodVibesFeedbackBox = "shows_good_vibes_feedback_box"
        case showsBadVibesFeedbackBox = "shows_bad_vibes_feedback_box"
        case showsOnlyPostsWithVideos = "shows_only_posts_with_videos"
        case showsOpenFeedModeTab = "shows_open_feed_mode_tab"
        case showsMergedFeedModeTab = "shows_merged_feed_mode_tab"
        case showsWeeklyFeedModeTab = "shows_weekly_feed_mode_tab"
        case showsFeaturesFeedModeTab = "shows_features_feed_mode_tab"
    }
}

@MainActor
protocol RevylSettingsStore: AnyObject {
    var refreshFailureMessage: String? { get }
    func refresh() async
}

extension RevylSettingsStore {
    // A failed save may still have landed, as when Revyl stores it and restarts before answering, so Revyl is read again, retrying while it's briefly unreachable (AGENTS.md, "Settings").
    func readSavedSettingsAfterFailedSave() async {
        for retryDelay: Duration in [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32)] {
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return
            }
            await refresh()
            if refreshFailureMessage == nil { return }
        }
    }
}

// A person's settings live in their Revyl account, so every device and the web share them (AGENTS.md, "Settings").
@Observable
@MainActor
final class UserSettingsStore: RevylSettingsStore {
    private(set) var refreshFailureMessage: String?
    var saveFailureMessage: String?
    // What Revyl's backend last confirmed, by a read or a save; nil until the first one. The settings shown are these with each setting's newest change still saving on top, so a read never shows an old value over a toggle, and a failed save shows what Revyl reads back (AGENTS.md, "Settings").
    private(set) var savedUserSettings: UserSettings?
    private var pendingChangeBySetting: [WritableKeyPath<UserSettings, Bool>: PendingSettingChange] = [:]
    private var latestChangeRevision = 0
    private var confirmedSaveCount = 0
    private var latestSave: Task<Void, Error>?
    private var readAfterFailedSave: Task<Void, Never>?
    private let api: RevylShipTokAPI

    init(api: RevylShipTokAPI) {
        self.api = api
    }

    var userSettings: UserSettings {
        var shownUserSettings = savedUserSettings ?? .defaults
        for (setting, pendingChange) in pendingChangeBySetting {
            shownUserSettings[keyPath: setting] = pendingChange.value
        }
        return shownUserSettings
    }

    func showsFeedbackBox(for vibe: ShipTokVibe) -> Bool {
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
            let fetchedUserSettings = try await api.fetchUserSettings()
            refreshFailureMessage = nil
            guard confirmedSaveCount == confirmedSaveCountAtFetchStart else { return }
            savedUserSettings = fetchedUserSettings
        } catch {
            if Task.isCancelled { return }
            refreshFailureMessage = error.localizedDescription
        }
    }

    func setShowsFeedbackBox(_ showsFeedbackBox: Bool, for vibe: ShipTokVibe) async {
        await setSetting(Self.feedbackBoxSetting(for: vibe), to: showsFeedbackBox)
    }

    func setShowsOnlyPostsWithVideos(_ showsOnlyPostsWithVideos: Bool) async {
        await setSetting(\.showsOnlyPostsWithVideos, to: showsOnlyPostsWithVideos)
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
        let save = Task { [api] in
            _ = await previousSave?.result
            savedUserSettings = try await api.saveUserSettings(userSettings)
            confirmedSaveCount += 1
        }
        latestSave = save
        let saveResult = await save.result
        // Only the setting's newest change settles it, so an older tap's failure never undoes a newer one.
        if pendingChangeBySetting[setting]?.revision == changeRevision {
            pendingChangeBySetting[setting] = nil
        }
        if case .failure(let error) = saveResult {
            saveFailureMessage = "Settings show what Revyl has saved. \(error.localizedDescription)"
            readAfterFailedSave?.cancel()
            readAfterFailedSave = Task { await readSavedSettingsAfterFailedSave() }
        }
    }

    private struct PendingSettingChange {
        let revision: Int
        let value: Bool
    }

    private static func feedbackBoxSetting(for vibe: ShipTokVibe) -> WritableKeyPath<UserSettings, Bool> {
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

// The organization's own ShipTok settings, which only its owners and admins change (AGENTS.md, "Settings").
@Observable
@MainActor
final class OrganizationSettingsStore: RevylSettingsStore {
    private(set) var organizationSettings: OrganizationSettings?
    private(set) var refreshFailureMessage: String?
    private(set) var isSaving = false
    var saveFailureMessage: String?
    private var readAfterFailedSave: Task<Void, Never>?
    private let api: RevylShipTokAPI

    init(api: RevylShipTokAPI) {
        self.api = api
    }

    func refresh() async {
        guard !isSaving else { return }
        do {
            organizationSettings = try await api.fetchOrganizationSettings()
            refreshFailureMessage = nil
        } catch {
            if Task.isCancelled { return }
            refreshFailureMessage = error.localizedDescription
        }
    }

    func setPostsFeedbackSummaryCommentsOnGitHub(_ postsFeedbackSummaryCommentsOnGitHub: Bool) async {
        guard let savedOrganizationSettings = organizationSettings, !isSaving,
              postsFeedbackSummaryCommentsOnGitHub != savedOrganizationSettings.postsFeedbackSummaryCommentsOnGitHub
        else { return }
        readAfterFailedSave?.cancel()
        isSaving = true
        defer { isSaving = false }
        organizationSettings?.postsFeedbackSummaryCommentsOnGitHub = postsFeedbackSummaryCommentsOnGitHub
        do {
            organizationSettings = try await api.saveOrganizationSettings(postsFeedbackSummaryCommentsOnGitHub: postsFeedbackSummaryCommentsOnGitHub)
        } catch {
            organizationSettings = savedOrganizationSettings
            saveFailureMessage = "Settings show what Revyl has saved. \(error.localizedDescription)"
            readAfterFailedSave = Task { await readSavedSettingsAfterFailedSave() }
        }
    }
}
