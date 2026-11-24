import Foundation
import OSLog
import SwiftUI

struct ShipTokAnalyticsSubject: Sendable, Hashable {
    let kind: ShipTokPost.Kind
    let postID: String
    let number: Int

    init(post: ShipTokPost) {
        kind = post.kind
        postID = post.id
        number = post.githubIssueNumber
    }
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
    let videoTagStatus: VideoTagStatus

    init(subject: ShipTokAnalyticsSubject, surface: Surface, mediaItem: ShipTokPostMedia, mediaPosition: Int) {
        self.subject = subject
        self.surface = surface
        self.mediaPosition = mediaPosition
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
    enum SignInEndReason: String, Sendable {
        case signedOut = "signed_out"
        case revylSignInRequired = "revyl_sign_in_required"
        case revylOrganizationRequired = "revyl_organization_required"
        case revylAccountDeleted = "revyl_account_deleted"
        case revylAccountChanged = "revyl_account_changed"
    }
    // An account in no organization closes Revyl's page without a callback, which iOS reports as cancelled too.
    enum RevylSignInFailureReason: String, Sendable {
        case cancelled
        case stateMismatch = "state_mismatch"
        case codeMissing = "code_missing"
        case signInExpired = "sign_in_expired"
        case organizationRequired = "organization_required"
        case keychainFailed = "keychain_failed"
        case unavailable
    }
    enum FirstScreenShowReason: String, Sendable {
        case noSignIn = "no_sign_in"
        case githubSignInRetired = "github_sign_in_retired"
        case signedOut = "signed_out"
        case revylSignInRequired = "revyl_sign_in_required"
        case revylOrganizationRequired = "revyl_organization_required"
        case revylAccountDeleted = "revyl_account_deleted"
        case failure
    }
    enum JoinOrganizationShowReason: String, Sendable {
        case chosenOnFirstScreen = "chosen_on_first_screen"
        case revylOrganizationRequired = "revyl_organization_required"
    }
    enum OrganizationJoinRequestFailureReason: String, Sendable {
        case emailInvalid = "email_invalid"
        case rateLimited = "rate_limited"
        case unavailable
    }
    enum RevylAccountDeletionFailureReason: String, Sendable {
        case ownsOrganization = "owns_organization"
        case unavailable
    }

    struct MutationAttempt: Sendable {
        let id: UUID
        let subject: ShipTokAnalyticsSubject
        let mutation: Mutation
        let change: Change
        var reaction: ShipTokReaction? = nil
        var vibe: ShipTokVibe? = nil
        var commentID: String? = nil
        var vibeID: String? = nil
        var isReply: Bool? = nil
        var selectionID: UUID? = nil
    }

    case watchStarted(ShipTokAnalyticsMedia, watchID: UUID)
    case watchCompleted(ShipTokAnalyticsMedia, watchID: UUID, playbackSeconds: Double, mediaSeconds: Double, durationSeconds: Double?, reason: WatchEndReason)
    case playbackFailed(ShipTokAnalyticsMedia)
    case mediaZoomed(ShipTokAnalyticsMedia)
    case vibeSelected(ShipTokAnalyticsSubject, selectionID: UUID, vibe: ShipTokVibe)
    case vibeCancelled(ShipTokAnalyticsSubject, selectionID: UUID, vibe: ShipTokVibe)
    case mutationRequested(MutationAttempt)
    case mutationCompleted(MutationAttempt, outcome: Outcome, commentID: String?)
    case speedChanged(ShipTokAnalyticsSubject?, control: SpeedControl, previousRate: Float, playbackRate: Float)
    case feedModeChanged(previousMode: FeedMode, mode: FeedMode)
    case olderPostsLoaded(FeedMode, addedPostCount: Int, addedVisiblePostCount: Int)
    case showsOnlyPostsWithVideosChanged(Bool)
    case showsFeedModeTabChanged(FeedMode, showsFeedModeTab: Bool)
    case commentsOpened(ShipTokAnalyticsSubject)
    case likeSelected(ShipTokAnalyticsSubject, control: LikeControl, wasLiked: Bool)
    case firstScreenShown(reason: FirstScreenShowReason)
    case revylSignInStarted(attemptID: UUID)
    case revylSignInFailed(attemptID: UUID, reason: RevylSignInFailureReason)
    case revylSignInCompleted(attemptID: UUID)
    case joinOrganizationShown(reason: JoinOrganizationShowReason)
    case organizationJoinRequestFailed(reason: OrganizationJoinRequestFailureReason)
    case revylAccountDeletionRequested
    case revylAccountDeletionFailed(reason: RevylAccountDeletionFailureReason)
    case signInEnded(reason: SignInEndReason)
    case contentReportOpened(ReportableContent, control: ModerationControl)
    case contentReported(ReportableContent, control: ModerationControl)
    case personHidden(ReportableContent, control: ModerationControl)
    case personUnhidden
    case inboxOpened(unreadCount: Int)

    var name: String {
        switch self {
        case .watchStarted: "shiptok_video_watch_started"
        case .watchCompleted: "shiptok_video_watch_completed"
        case .playbackFailed: "shiptok_video_playback_failed"
        case .mediaZoomed: "shiptok_media_zoomed"
        case .vibeSelected: "shiptok_vibe_selected"
        case .vibeCancelled: "shiptok_vibe_cancelled"
        case .mutationRequested(let attempt): "shiptok_\(attempt.mutation.rawValue)_change_requested"
        case .mutationCompleted(let attempt, _, _): "shiptok_\(attempt.mutation.rawValue)_change_completed"
        case .speedChanged: "shiptok_playback_speed_changed"
        case .feedModeChanged: "shiptok_feed_mode_changed"
        case .olderPostsLoaded: "shiptok_older_posts_loaded"
        case .showsOnlyPostsWithVideosChanged: "shiptok_shows_only_posts_with_videos_changed"
        case .showsFeedModeTabChanged: "shiptok_shows_feed_mode_tab_changed"
        case .commentsOpened: "shiptok_comments_opened"
        case .likeSelected: "shiptok_like_selected"
        case .firstScreenShown: "shiptok_first_screen_shown"
        case .revylSignInStarted: "shiptok_revyl_sign_in_started"
        case .revylSignInFailed: "shiptok_revyl_sign_in_failed"
        case .revylSignInCompleted: "shiptok_revyl_sign_in_completed"
        case .joinOrganizationShown: "shiptok_join_organization_shown"
        case .organizationJoinRequestFailed: "shiptok_organization_join_request_failed"
        case .revylAccountDeletionRequested: "shiptok_revyl_account_deletion_requested"
        case .revylAccountDeletionFailed: "shiptok_revyl_account_deletion_failed"
        case .signInEnded: "shiptok_sign_in_ended"
        case .contentReportOpened: "shiptok_content_report_opened"
        case .contentReported: "shiptok_content_reported"
        case .personHidden: "shiptok_person_hidden"
        case .personUnhidden: "shiptok_person_unhidden"
        case .inboxOpened: "shiptok_inbox_opened"
        }
    }

    fileprivate var properties: [String: Property] {
        var properties: [String: Property] = [:]
        func addSubject(_ subject: ShipTokAnalyticsSubject) {
            properties["subject_kind"] = .string(subject.kind.rawValue)
            properties["subject_id"] = .string(subject.postID)
            properties["subject_number"] = .integer(subject.number)
        }
        func addMedia(_ media: ShipTokAnalyticsMedia) {
            addSubject(media.subject)
            properties["surface"] = .string(media.surface.rawValue)
            properties["media_position"] = .integer(media.mediaPosition)
            properties["video_tag_status"] = .string(media.videoTagStatus.rawValue)
        }
        func addMutation(_ attempt: MutationAttempt) {
            addSubject(attempt.subject)
            properties["action_id"] = .string(attempt.id.uuidString)
            properties["change"] = .string(attempt.change.rawValue)
            properties["reaction"] = attempt.reaction.map { .string($0.rawValue) }
            properties["vibe"] = attempt.vibe.map { .string($0.rawValue) }
            properties["comment_id"] = attempt.commentID.map(Property.string)
            properties["vibe_id"] = attempt.vibeID.map(Property.string)
            properties["is_reply"] = attempt.isReply.map(Property.boolean)
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
        case .playbackFailed(let media), .mediaZoomed(let media):
            addMedia(media)
        case .vibeSelected(let subject, let selectionID, let vibe), .vibeCancelled(let subject, let selectionID, let vibe):
            addSubject(subject)
            properties["selection_id"] = .string(selectionID.uuidString)
            properties["vibe"] = .string(vibe.rawValue)
        case .mutationRequested(let attempt):
            addMutation(attempt)
        case .mutationCompleted(let attempt, let outcome, let commentID):
            addMutation(attempt)
            properties["outcome"] = .string(outcome.rawValue)
            if let commentID { properties["comment_id"] = .string(commentID) }
        case .speedChanged(let subject, let control, let previousRate, let playbackRate):
            if let subject { addSubject(subject) }
            properties["control"] = .string(control.rawValue)
            properties["previous_playback_rate"] = .number(Double(previousRate))
            properties["playback_rate"] = .number(Double(playbackRate))
        case .feedModeChanged(let previousMode, let mode):
            properties["previous_feed_mode"] = .string(previousMode.rawValue)
            properties["feed_mode"] = .string(mode.rawValue)
        case .olderPostsLoaded(let feedMode, let addedPostCount, let addedVisiblePostCount):
            properties["feed_mode"] = .string(feedMode.rawValue)
            properties["added_post_count"] = .integer(addedPostCount)
            properties["added_visible_post_count"] = .integer(addedVisiblePostCount)
        case .showsOnlyPostsWithVideosChanged(let showsOnlyPostsWithVideos):
            properties["shows_only_posts_with_videos"] = .boolean(showsOnlyPostsWithVideos)
        case .showsFeedModeTabChanged(let feedMode, let showsFeedModeTab):
            properties["feed_mode"] = .string(feedMode.rawValue)
            properties["shows_feed_mode_tab"] = .boolean(showsFeedModeTab)
        case .commentsOpened(let subject):
            addSubject(subject)
        case .likeSelected(let subject, let control, let wasLiked):
            addSubject(subject)
            properties["control"] = .string(control.rawValue)
            properties["was_liked"] = .boolean(wasLiked)
        case .firstScreenShown(let reason):
            properties["show_reason"] = .string(reason.rawValue)
        case .joinOrganizationShown(let reason):
            properties["show_reason"] = .string(reason.rawValue)
        case .revylSignInStarted(let attemptID), .revylSignInCompleted(let attemptID):
            properties["sign_in_attempt_id"] = .string(attemptID.uuidString)
        case .revylSignInFailed(let attemptID, let reason):
            properties["sign_in_attempt_id"] = .string(attemptID.uuidString)
            properties["failure_reason"] = .string(reason.rawValue)
        case .organizationJoinRequestFailed(let reason):
            properties["failure_reason"] = .string(reason.rawValue)
        case .revylAccountDeletionFailed(let reason):
            properties["failure_reason"] = .string(reason.rawValue)
        case .signInEnded(let reason):
            properties["end_reason"] = .string(reason.rawValue)
        case .contentReportOpened(let reportableContent, let control),
             .contentReported(let reportableContent, let control),
             .personHidden(let reportableContent, let control):
            switch reportableContent.kind {
            case .post(let postKind):
                properties["content_kind"] = .string("post")
                properties["subject_kind"] = .string(postKind.rawValue)
            case .comment:
                properties["content_kind"] = .string("comment")
            case .reply:
                properties["content_kind"] = .string("reply")
            case .vibe:
                properties["content_kind"] = .string("vibe")
            case .reaction:
                properties["content_kind"] = .string("reaction")
            }
            properties["control"] = .string(control.rawValue)
        case .inboxOpened(let unreadCount):
            properties["unread_count"] = .integer(unreadCount)
        case .personUnhidden, .revylAccountDeletionRequested:
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
    private let visitProperty: (name: String, visitID: UUID)?

    convenience init(revylUserID: String) {
        self.init(distinctID: "revyl:\(revylUserID)")
    }

    // Nobody is signed in on the first screen, so one showing of it and what it leads to share its own id, and a sign-in that starts there carries its attempt id to the completion the signed-in person captures (AGENTS.md, "Product Analytics").
    convenience init(firstScreenVisitID: UUID) {
        self.init(distinctID: "shiptok-first-screen-visit:\(firstScreenVisitID.uuidString)", visitProperty: ("first_screen_visit_id", firstScreenVisitID))
    }

    private init(distinctID: String, visitProperty: (name: String, visitID: UUID)? = nil) {
        self.distinctID = distinctID
        self.visitProperty = visitProperty
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        urlSession = URLSession(configuration: configuration)
    }

    deinit { urlSession.finishTasksAndInvalidate() }

    func requestMutation(_ mutation: ShipTokAnalyticsEvent.Mutation, change: ShipTokAnalyticsEvent.Change,
                         subject: ShipTokAnalyticsSubject, reaction: ShipTokReaction? = nil,
                         vibe: ShipTokVibe? = nil, commentID: String? = nil, vibeID: String? = nil, isReply: Bool? = nil,
                         selectionID: UUID? = nil) -> ShipTokAnalyticsEvent.MutationAttempt {
        let attempt = ShipTokAnalyticsEvent.MutationAttempt(id: UUID(), subject: subject, mutation: mutation,
                                                           change: change, reaction: reaction, vibe: vibe,
                                                           commentID: commentID, vibeID: vibeID, isReply: isReply, selectionID: selectionID)
        capture(.mutationRequested(attempt))
        return attempt
    }

    func capture(_ event: ShipTokAnalyticsEvent) {
        var properties = event.properties
        properties["$process_person_profile"] = .boolean(false)
        properties["$geoip_disable"] = .boolean(true)
        properties["actor_type"] = .string("human")
        properties["identity_provider"] = .string("revyl")
        properties["source"] = .string("shiptok_ios")
        if let visitProperty {
            properties[visitProperty.name] = .string(visitProperty.visitID.uuidString)
        }
        properties["schema_version"] = .integer(8)
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
