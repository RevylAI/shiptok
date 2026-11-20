import Foundation
import OSLog
import SwiftUI

struct ShipTokAnalyticsSubject: Sendable, Hashable {
    enum Kind: String, Sendable {
        case pullRequest = "pull_request"
        case weeklyEdition = "weekly_edition"
    }

    let kind: Kind
    let nodeID: String
    let number: Int
}

struct ShipTokAnalyticsMedia: Sendable {
    enum Surface: String, Sendable {
        case feed
        case mediaDeck = "media_deck"
    }
    enum VideoTagStatus: String, Sendable { case tagged, other }

    let subject: ShipTokAnalyticsSubject
    let surface: Surface
    let mediaPosition: Int
    let sourceCommentID: String?
    let sourceCommentDatabaseID: Int?
    let videoTagStatus: VideoTagStatus

    init(subject: ShipTokAnalyticsSubject, surface: Surface, mediaItem: PullRequestMediaItem, mediaPosition: Int) {
        self.subject = subject
        self.surface = surface
        self.mediaPosition = mediaPosition
        sourceCommentID = mediaItem.sourceCommentID
        sourceCommentDatabaseID = mediaItem.sourceCommentDatabaseID
        videoTagStatus = mediaItem.isShipTokVideo ? .tagged : .other
    }
}

enum ShipTokAnalyticsEvent: Sendable {
    enum Mutation: String, Sendable { case reaction, comment, vibe }
    enum Change: String, Sendable { case add, remove }
    enum Outcome: String, Sendable { case succeeded, failed, cancelled }
    enum SpeedControl: String, Sendable { case feedRail = "feed_rail", mediaDeck = "media_deck", hold }
    enum LikeControl: String, Sendable { case doubleTap = "double_tap", feedRail = "feed_rail" }
    enum WatchEndReason: String, Sendable { case hidden, background, playbackFailed = "playback_failed" }
    enum ModerationControl: String, Sendable {
        case feedRail = "feed_rail"
        case commentActions = "comment_actions"
        case inboxRow = "inbox_row"
        case detailSheet = "detail_sheet"
        case mediaDeck = "media_deck"
    }
    enum SignInEndReason: String, Sendable { case signedOut = "signed_out", githubRejected = "github_rejected", dataDeleted = "data_deleted" }
    enum SignInFailureReason: String, Sendable {
        case cancelled
        case stateMismatch = "state_mismatch"
        case githubRefused = "github_refused"
        case revylRejected = "revyl_rejected"
        case keychainFailed = "keychain_failed"
        case unavailable
    }

    struct MutationAttempt: Sendable {
        let id: UUID
        let subject: ShipTokAnalyticsSubject
        let mutation: Mutation
        let change: Change
        var reaction: GitHubReaction? = nil
        var vibe: PullRequestVibe? = nil
        var commentID: String? = nil
        var selectionID: UUID? = nil
    }

    case watchStarted(ShipTokAnalyticsMedia, watchID: UUID)
    case watchCompleted(ShipTokAnalyticsMedia, watchID: UUID, playbackSeconds: Double, mediaSeconds: Double, durationSeconds: Double?, reason: WatchEndReason)
    case playbackFailed(ShipTokAnalyticsMedia)
    case vibeSelected(ShipTokAnalyticsSubject, selectionID: UUID, vibe: PullRequestVibe)
    case vibeCancelled(ShipTokAnalyticsSubject, selectionID: UUID, vibe: PullRequestVibe)
    case mutationRequested(MutationAttempt)
    case mutationCompleted(MutationAttempt, outcome: Outcome, commentID: String?, commentDatabaseID: Int?)
    case speedChanged(ShipTokAnalyticsSubject?, control: SpeedControl, previousRate: Float, playbackRate: Float)
    case feedModeChanged(previousMode: FeedMode, mode: FeedMode)
    case olderPullRequestsLoaded(PullRequestFeed, addedPullRequestCount: Int, addedVisiblePullRequestCount: Int)
    case showsOnlyPullRequestsWithVideosChanged(Bool)
    case commentsOpened(ShipTokAnalyticsSubject)
    case likeSelected(ShipTokAnalyticsSubject, control: LikeControl, wasLiked: Bool)
    case signInStarted(attemptID: UUID)
    case signInFailed(attemptID: UUID, reason: SignInFailureReason)
    case signInCompleted(attemptID: UUID)
    case signInEnded(reason: SignInEndReason)
    case contentReportOpened(GitHubPostedContent, control: ModerationControl)
    case personHidden(GitHubPostedContent, control: ModerationControl)
    case personUnhidden

    var name: String {
        switch self {
        case .watchStarted: "shiptok_video_watch_started"
        case .watchCompleted: "shiptok_video_watch_completed"
        case .playbackFailed: "shiptok_video_playback_failed"
        case .vibeSelected: "shiptok_vibe_selected"
        case .vibeCancelled: "shiptok_vibe_cancelled"
        case .mutationRequested(let attempt): "shiptok_\(attempt.mutation.rawValue)_change_requested"
        case .mutationCompleted(let attempt, _, _, _): "shiptok_\(attempt.mutation.rawValue)_change_completed"
        case .speedChanged: "shiptok_playback_speed_changed"
        case .feedModeChanged: "shiptok_feed_mode_changed"
        case .olderPullRequestsLoaded: "shiptok_older_pull_requests_loaded"
        case .showsOnlyPullRequestsWithVideosChanged: "shiptok_shows_only_pull_requests_with_videos_changed"
        case .commentsOpened: "shiptok_comments_opened"
        case .likeSelected: "shiptok_like_selected"
        case .signInStarted: "shiptok_sign_in_started"
        case .signInFailed: "shiptok_sign_in_failed"
        case .signInCompleted: "shiptok_sign_in_completed"
        case .signInEnded: "shiptok_sign_in_ended"
        case .contentReportOpened: "shiptok_content_report_opened"
        case .personHidden: "shiptok_person_hidden"
        case .personUnhidden: "shiptok_person_unhidden"
        }
    }

    fileprivate var properties: [String: Property] {
        var properties: [String: Property] = [:]
        func addSubject(_ subject: ShipTokAnalyticsSubject) {
            properties["subject_kind"] = .string(subject.kind.rawValue)
            properties["subject_id"] = .string(subject.nodeID)
            properties["subject_number"] = .integer(subject.number)
        }
        func addMedia(_ media: ShipTokAnalyticsMedia) {
            addSubject(media.subject)
            properties["surface"] = .string(media.surface.rawValue)
            properties["media_position"] = .integer(media.mediaPosition)
            properties["video_tag_status"] = .string(media.videoTagStatus.rawValue)
            properties["source_comment_id"] = media.sourceCommentID.map(Property.string)
            properties["source_comment_database_id"] = media.sourceCommentDatabaseID.map(Property.integer)
        }
        func addMutation(_ attempt: MutationAttempt) {
            addSubject(attempt.subject)
            properties["action_id"] = .string(attempt.id.uuidString)
            properties["change"] = .string(attempt.change.rawValue)
            properties["reaction"] = attempt.reaction.map { .string($0.rawValue) }
            properties["vibe"] = attempt.vibe.map { .string($0.rawValue) }
            properties["comment_id"] = attempt.commentID.map(Property.string)
            properties["selection_id"] = attempt.selectionID.map { .string($0.uuidString) }
        }
        switch self {
        case .watchStarted(let media, let watchID):
            addMedia(media)
            properties["watch_id"] = .string(watchID.uuidString)
        case .watchCompleted(let media, let watchID, let playbackSeconds, let mediaSeconds, let durationSeconds, let reason):
            addMedia(media)
            properties["watch_id"] = .string(watchID.uuidString)
            properties["playback_seconds"] = .number(playbackSeconds)
            properties["played_media_seconds"] = .number(mediaSeconds)
            properties["video_duration_seconds"] = durationSeconds.map(Property.number)
            properties["end_reason"] = .string(reason.rawValue)
        case .playbackFailed(let media):
            addMedia(media)
        case .vibeSelected(let subject, let selectionID, let vibe), .vibeCancelled(let subject, let selectionID, let vibe):
            addSubject(subject)
            properties["selection_id"] = .string(selectionID.uuidString)
            properties["vibe"] = .string(vibe.rawValue)
        case .mutationRequested(let attempt):
            addMutation(attempt)
        case .mutationCompleted(let attempt, let outcome, let commentID, let commentDatabaseID):
            addMutation(attempt)
            properties["outcome"] = .string(outcome.rawValue)
            if let commentID { properties["comment_id"] = .string(commentID) }
            properties["comment_database_id"] = commentDatabaseID.map(Property.integer)
        case .speedChanged(let subject, let control, let previousRate, let playbackRate):
            if let subject { addSubject(subject) }
            properties["control"] = .string(control.rawValue)
            properties["previous_playback_rate"] = .number(Double(previousRate))
            properties["playback_rate"] = .number(Double(playbackRate))
        case .feedModeChanged(let previousMode, let mode):
            properties["previous_feed_mode"] = .string(previousMode.rawValue)
            properties["feed_mode"] = .string(mode.rawValue)
        case .olderPullRequestsLoaded(let feed, let addedPullRequestCount, let addedVisiblePullRequestCount):
            properties["feed_mode"] = .string(feed.rawValue)
            properties["added_pull_request_count"] = .integer(addedPullRequestCount)
            properties["added_visible_pull_request_count"] = .integer(addedVisiblePullRequestCount)
        case .showsOnlyPullRequestsWithVideosChanged(let showsOnlyPullRequestsWithVideos):
            properties["shows_only_pull_requests_with_videos"] = .boolean(showsOnlyPullRequestsWithVideos)
        case .commentsOpened(let subject):
            addSubject(subject)
        case .likeSelected(let subject, let control, let wasLiked):
            addSubject(subject)
            properties["control"] = .string(control.rawValue)
            properties["was_liked"] = .boolean(wasLiked)
        case .signInStarted(let attemptID), .signInCompleted(let attemptID):
            properties["sign_in_attempt_id"] = .string(attemptID.uuidString)
        case .signInFailed(let attemptID, let reason):
            properties["sign_in_attempt_id"] = .string(attemptID.uuidString)
            properties["failure_reason"] = .string(reason.rawValue)
        case .signInEnded(let reason):
            properties["end_reason"] = .string(reason.rawValue)
        case .contentReportOpened(let postedContent, let control), .personHidden(let postedContent, let control):
            if let subject = postedContent.postedOn { addSubject(subject) }
            properties["content_kind"] = .string(postedContent.kind.rawValue)
            properties["control"] = .string(control.rawValue)
        case .personUnhidden:
            break
        }
        return properties
    }

    fileprivate enum Property: Encodable, Sendable {
        case string(String), integer(Int), number(Double), boolean(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            }
        }
    }
}

@MainActor
final class ShipTokAnalytics {
    private struct Capture: Encodable {
        let api_key: String
        let distinct_id: String
        let event: String
        let uuid: UUID
        let timestamp: Date
        let properties: [String: ShipTokAnalyticsEvent.Property]
    }

    private nonisolated static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "analytics")
    private static let projectIngestionKey = "phc_5J0lU7F9qmS7yt8ElfHnCmhxXJM8I5B8PeayaMGaXEZ"
    private static let captureURL = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    private let urlSession: URLSession
    private let distinctID: String

    convenience init(githubUserID: Int64) {
        self.init(distinctID: "github:\(githubUserID)")
    }

    // Before GitHub says who is signing in there is no person to attribute to, so an attempt's events share its own id and only its completion carries the person.
    convenience init(signInAttemptID: UUID) {
        self.init(distinctID: "shiptok-sign-in-attempt:\(signInAttemptID.uuidString)")
    }

    private init(distinctID: String) {
        self.distinctID = distinctID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        urlSession = URLSession(configuration: configuration)
    }

    deinit { urlSession.finishTasksAndInvalidate() }

    func requestMutation(_ mutation: ShipTokAnalyticsEvent.Mutation, change: ShipTokAnalyticsEvent.Change,
                         subject: ShipTokAnalyticsSubject, reaction: GitHubReaction? = nil,
                         vibe: PullRequestVibe? = nil, commentID: String? = nil,
                         selectionID: UUID? = nil) -> ShipTokAnalyticsEvent.MutationAttempt {
        let attempt = ShipTokAnalyticsEvent.MutationAttempt(id: UUID(), subject: subject, mutation: mutation,
                                                           change: change, reaction: reaction, vibe: vibe,
                                                           commentID: commentID, selectionID: selectionID)
        capture(.mutationRequested(attempt))
        return attempt
    }

    func capture(_ event: ShipTokAnalyticsEvent) {
        var properties = event.properties
        properties["$process_person_profile"] = .boolean(false)
        properties["$geoip_disable"] = .boolean(true)
        properties["actor_type"] = .string("human")
        properties["identity_provider"] = .string("github")
        properties["source"] = .string("shiptok_ios")
        properties["schema_version"] = .integer(4)
        properties["app_version"] = .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        properties["app_build"] = .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        #if DEBUG
        properties["environment"] = .string("development")
        #else
        properties["environment"] = .string("production")
        #endif
        let payload = Capture(api_key: Self.projectIngestionKey, distinct_id: distinctID,
                              event: event.name, uuid: UUID(),
                              timestamp: .now, properties: properties)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            var request = URLRequest(url: Self.captureURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            urlSession.dataTask(with: request) { _, response, error in
                if error != nil || !(200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                    Self.logger.debug("Analytics delivery failed")
                }
            }.resume()
        } catch {
            Self.logger.error("Analytics event could not be encoded")
        }
    }
}

private struct ShipTokAnalyticsEnvironmentKey: EnvironmentKey {
    static let defaultValue: ShipTokAnalytics? = nil
}

extension EnvironmentValues {
    var shipTokAnalytics: ShipTokAnalytics? {
        get { self[ShipTokAnalyticsEnvironmentKey.self] }
        set { self[ShipTokAnalyticsEnvironmentKey.self] = newValue }
    }
}
