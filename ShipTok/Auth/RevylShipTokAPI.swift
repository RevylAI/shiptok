import Foundation
import OSLog

// Every build talks to the Revyl backend its SHIPTOK_REVYL_BACKEND_URL build setting names, production by default (AGENTS.md, "iOS App").
enum RevylBackendConfiguration {
    static let backendURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "RevylBackendURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    static let requestTimeoutSeconds: TimeInterval = 60
}

enum RevylShipTokAPIError: LocalizedError {
    case backendNotConfigured
    case revylSignInRequired
    case revylPersonRequired
    case revylOrganizationRequired
    case revylSignInExpired
    case revylAccountOwnsOrganization(revylMessage: String)
    case explainedByRevyl(revylMessage: String)
    case organizationJoinRequestEmailInvalid
    case rateLimited
    case repositoryNotFound
    case githubAppNotInstalled
    case githubUnavailable
    case postNotFound
    case feedModeTabRequired
    case organizationAdminRequired
    case unavailable(operationName: String)
    case unexpectedResponse(operationName: String, statusCode: Int)
    case responseUnreadable(operationName: String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "This build names no Revyl backend. Build it with SHIPTOK_REVYL_BACKEND_URL set to a Revyl backend URL."
        case .revylSignInRequired:
            "Your Revyl sign-in has ended. Sign in to Revyl again."
        case .revylPersonRequired:
            "ShipTok needs a person's Revyl sign-in. Sign in to Revyl again."
        case .revylOrganizationRequired:
            "Your Revyl account isn't in an organization. Ask your organization's owner or an admin to invite you, then sign in again."
        case .revylSignInExpired:
            "That Revyl sign-in expired before ShipTok could finish it. Sign in to Revyl again."
        case .revylAccountOwnsOrganization(let revylMessage), .explainedByRevyl(let revylMessage):
            revylMessage
        case .organizationJoinRequestEmailInvalid:
            "That doesn't look like an email address. Check it and try again."
        case .rateLimited:
            "Too many requests from here. Try again in a minute."
        case .repositoryNotFound:
            "Revyl's GitHub App doesn't cover that repository any more. Choose another one."
        case .githubAppNotInstalled:
            "Your organization hasn't installed Revyl's GitHub App. Ask an admin to install it."
        case .githubUnavailable:
            "GitHub didn't answer Revyl just now. Try again in a minute."
        case .postNotFound:
            "That post isn't on ShipTok any more."
        case .feedModeTabRequired:
            "Keep at least one feed tab on."
        case .organizationAdminRequired:
            "Only your organization's owners and admins can change that."
        case .unavailable(let operationName):
            "Revyl couldn't finish \(operationName) just now. Try again in a minute."
        case .unexpectedResponse(let operationName, let statusCode):
            "Revyl answered \(statusCode) to \(operationName)."
        case .responseUnreadable(let operationName):
            "Revyl's answer to \(operationName) couldn't be read."
        }
    }

    // A refusal of the sign-in itself, which no retry changes: the person signs in again or joins an organization (AGENTS.md, "Revyl Sign-In").
    var refusesSignIn: Bool {
        switch self {
        case .revylSignInRequired, .revylPersonRequired, .revylOrganizationRequired: true
        default: false
        }
    }
}

struct ShipTokPostPage: Decodable, Sendable {
    let posts: [ShipTokPost]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case posts
        case nextCursor = "next_cursor"
    }
}

struct ShipTokCommentPage: Decodable, Sendable {
    let comments: [ShipTokPostComment]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case comments
        case nextCursor = "next_cursor"
    }
}

struct ShipTokVibePage: Decodable, Sendable {
    let vibes: [ShipTokPostVibe]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case vibes
        case nextCursor = "next_cursor"
    }
}

struct ShipTokInboxPage: Decodable, Sendable {
    let items: [ShipTokInboxItem]
    let unreadCount: Int
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case unreadCount = "unread_count"
        case nextCursor = "next_cursor"
    }
}

struct OrganizationSettings: Codable, Equatable, Sendable {
    var postsFeedbackSummaryCommentsOnGitHub: Bool
    let viewerCanChange: Bool

    private enum CodingKeys: String, CodingKey {
        case postsFeedbackSummaryCommentsOnGitHub = "posts_feedback_summary_comments_on_github"
        case viewerCanChange = "viewer_can_change"
    }
}

struct GitHubAccount: Codable, Equatable, Sendable {
    let githubUserID: Int64
    let login: String
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case githubUserID = "github_user_id"
        case login
        case avatarURL = "avatar_url"
    }
}

// The GitHub account a person set in their organization, or none.
struct GitHubAccountSetting: Codable, Equatable, Sendable {
    let githubAccount: GitHubAccount?

    private enum CodingKeys: String, CodingKey {
        case githubAccount = "github_account"
    }
}

// Revyl's backend signs people in to Revyl and serves everything ShipTok shows: the organization's repositories, their posts read from GitHub through Revyl's GitHub App, and the feedback people give them. The app calls no GitHub API (AGENTS.md, "Ownership And Boundaries").
struct RevylShipTokAPI: Sendable {
    // Nil before sign-in; every route past sign-in takes the person's ShipTok key.
    let revylAPIKey: String?
    // Told when Revyl refuses the sign-in itself, so the person goes back to the first screen or to joining an organization.
    var onSignInRefused: (@MainActor @Sendable (RevylShipTokAPIError) -> Void)?

    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "revyl-backend")
    private static let urlSession: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        return URLSession(configuration: sessionConfiguration, delegate: RevylAPIRedirectRefusingDelegate(), delegateQueue: nil)
    }()

    // MARK: Sign-in

    func revylSignInAuthorizationURL(state: String, codeChallenge: String) async throws -> URL {
        let operationName = "the Revyl sign-in link"
        let response: AuthorizationURLResponse = try await send(
            "GET",
            path: "revyl-sign-in/authorization-url",
            queryItems: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: codeChallenge)],
            operationName: operationName
        )
        guard let authorizationURL = URL(string: response.authorizationURLString) else {
            throw RevylShipTokAPIError.responseUnreadable(operationName: operationName)
        }
        return authorizationURL
    }

    func exchangeRevylSignInCode(_ code: String, codeVerifier: String, deviceLabel: String) async throws -> String {
        let response: RevylAPIKeyResponse = try await send(
            "POST",
            path: "revyl-sign-in/api-keys",
            jsonBody: ["code": code, "code_verifier": codeVerifier, "device_label": deviceLabel],
            operationName: "the Revyl sign-in"
        )
        return response.revylAPIKey
    }

    // Revokes the presented ShipTok key, and Revyl deletes the push notification devices it registered.
    func revokeRevylAPIKey() async throws {
        _ = try await sendRequest("DELETE", path: "revyl-sign-in/api-key", operationName: "signing out of Revyl")
    }

    // Deletes the Revyl account and everything ShipTok holds for it. Throws revylAccountOwnsOrganization, with Revyl's own explanation, for an Owner of any organization, since deleting from a phone would strand it (AGENTS.md, "Revyl Sign-In").
    func deleteRevylAccount() async throws {
        _ = try await sendRequest("DELETE", path: "revyl-account", operationName: "deleting your Revyl account")
    }

    func fetchRevylAccount() async throws -> RevylAccount {
        try await send("GET", path: "revyl-account", operationName: "your Revyl account")
    }

    // Revyl answers the same whatever it found, so the app never learns whether an organization matched.
    func submitOrganizationJoinRequest(email: String) async throws {
        do {
            _ = try await sendRequest("POST", path: "organization-join-requests", jsonBody: ["email": email], sendsRevylAPIKey: false, operationName: "your request")
        } catch RevylShipTokAPIError.unexpectedResponse(_, 422) {
            throw RevylShipTokAPIError.organizationJoinRequestEmailInvalid
        }
    }

    // MARK: Posts

    func fetchRepositories() async throws -> [ShipTokRepository] {
        let response: RepositoriesResponse = try await send("GET", path: "repositories", operationName: "your organization's repositories")
        return response.repositories
    }

    func fetchFeedPage(repositoryID: Int64, feedMode: FeedMode, cursor: String?) async throws -> ShipTokPostPage {
        try await send(
            "GET",
            path: "repositories/\(repositoryID)/feeds/\(feedMode.rawValue)",
            queryItems: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [],
            operationName: "the \(feedMode.tabTitle) feed"
        )
    }

    func fetchPost(postID: String) async throws -> ShipTokPost {
        try await send("GET", path: "posts/\(postID)", operationName: "the post")
    }

    func fetchDeck(postID: String) async throws -> [ShipTokPost] {
        let response: DeckResponse = try await send("GET", path: "posts/\(postID)/deck", operationName: "the pull requests")
        return response.posts
    }

    // MARK: Feedback

    func setPostReaction(_ reaction: ShipTokReaction, isReacting: Bool, postID: String) async throws {
        _ = try await sendRequest(isReacting ? "PUT" : "DELETE", path: "posts/\(postID)/reactions/\(reaction.rawValue)", operationName: "your reaction")
    }

    func setCommentReaction(_ reaction: ShipTokReaction, isReacting: Bool, postID: String, commentID: String) async throws {
        _ = try await sendRequest(isReacting ? "PUT" : "DELETE", path: "posts/\(postID)/comments/\(commentID)/reactions/\(reaction.rawValue)", operationName: "your reaction")
    }

    // Replaces the viewer's earlier vibe on the post.
    func setVibe(_ vibe: ShipTokVibe, feedbackText: String?, postID: String) async throws -> ShipTokPostVibe {
        try await send("PUT", path: "posts/\(postID)/vibe", jsonBody: VibeRequestBody(vibe: vibe.rawValue, feedbackText: feedbackText), operationName: "your vibe")
    }

    // Its author clears their vibe this way, and an Owner or Admin can delete anyone's.
    func deleteVibe(vibeID: String, postID: String) async throws {
        _ = try await sendRequest("DELETE", path: "posts/\(postID)/vibes/\(vibeID)", operationName: "deleting the vibe")
    }

    func fetchVibes(postID: String, cursor: String?) async throws -> ShipTokVibePage {
        try await send(
            "GET",
            path: "posts/\(postID)/vibes",
            queryItems: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [],
            operationName: "the vibes"
        )
    }

    func reportVibe(vibeID: String, postID: String) async throws {
        _ = try await sendRequest("POST", path: "posts/\(postID)/vibes/\(vibeID)/reports", operationName: "your report")
    }

    func fetchComments(postID: String, cursor: String?) async throws -> ShipTokCommentPage {
        try await send(
            "GET",
            path: "posts/\(postID)/comments",
            queryItems: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [],
            operationName: "the comments"
        )
    }

    func postComment(body: String, parentCommentID: String?, postID: String) async throws -> ShipTokPostComment {
        try await send(
            "POST",
            path: "posts/\(postID)/comments",
            jsonBody: CommentRequestBody(body: body, parentCommentID: parentCommentID),
            operationName: parentCommentID == nil ? "your comment" : "your reply"
        )
    }

    func deleteComment(commentID: String, postID: String) async throws {
        _ = try await sendRequest("DELETE", path: "posts/\(postID)/comments/\(commentID)", operationName: "deleting the comment")
    }

    func reportComment(commentID: String, postID: String) async throws {
        _ = try await sendRequest("POST", path: "posts/\(postID)/comments/\(commentID)/reports", operationName: "your report")
    }

    // MARK: Inbox

    func fetchInboxPage(cursor: String?) async throws -> ShipTokInboxPage {
        try await send("GET", path: "inbox", queryItems: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [], operationName: "your inbox")
    }

    // Takes the backend's own spelling of the newest item's time, so the read mark lands on it exactly; answers the unread count left.
    func markInboxRead(throughCreatedAtText readThroughText: String) async throws -> Int {
        let response: InboxReadThroughResponse = try await send("PUT", path: "inbox/read-through", jsonBody: ["read_through": readThroughText], operationName: "your inbox")
        return response.unreadCount
    }

    // MARK: Settings

    func fetchUserSettings() async throws -> UserSettings {
        try await send("GET", path: "revyl-account/settings", operationName: "your settings")
    }

    func saveUserSettings(_ userSettings: UserSettings) async throws -> UserSettings {
        try await send("PUT", path: "revyl-account/settings", jsonBody: userSettings, operationName: "your settings")
    }

    func fetchOrganizationSettings() async throws -> OrganizationSettings {
        try await send("GET", path: "organization-settings", operationName: "your organization's settings")
    }

    func saveOrganizationSettings(postsFeedbackSummaryCommentsOnGitHub: Bool) async throws -> OrganizationSettings {
        try await send(
            "PUT",
            path: "organization-settings",
            jsonBody: ["posts_feedback_summary_comments_on_github": postsFeedbackSummaryCommentsOnGitHub],
            operationName: "your organization's settings"
        )
    }

    // Revyl makes the person the developer of the posts by the GitHub account they set (AGENTS.md, "Settings").
    func fetchGitHubAccountSetting() async throws -> GitHubAccountSetting {
        try await send("GET", path: "revyl-account/github-account", operationName: "your GitHub username")
    }

    // Revyl trims the login, drops one leading @ and looks it up on GitHub, so it answers with GitHub's own casing.
    func saveGitHubAccount(login: String) async throws -> GitHubAccountSetting {
        try await send(
            "PUT",
            path: "revyl-account/github-account",
            jsonBody: ["login": login],
            refusalKeysExplainedByRevyl: Self.githubAccountRefusalKeys,
            operationName: "your GitHub username"
        )
    }

    func removeGitHubAccount() async throws {
        _ = try await sendRequest("DELETE", path: "revyl-account/github-account", operationName: "your GitHub username")
    }

    // Revyl's own words say what was wrong with the username, and who already set it.
    private static let githubAccountRefusalKeys: Set<String> = [
        "github_login_invalid",
        "github_account_not_found",
        "github_account_not_a_person",
        "github_account_set_by_another_person",
        "github_app_not_installed",
        "github_unavailable",
    ]

    // MARK: Push notifications

    func registerPushNotificationDevice(apnsDeviceTokenHex: String, apnsEnvironment: String) async throws {
        _ = try await sendRequest(
            "POST",
            path: "push-notification-devices",
            jsonBody: ["apns_device_token": apnsDeviceTokenHex, "apns_environment": apnsEnvironment],
            operationName: "notifications"
        )
    }

    // MARK: Requests

    private func send<ResponseBody: Decodable>(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: (any Encodable & Sendable)? = nil,
        refusalKeysExplainedByRevyl: Set<String> = [],
        operationName: String
    ) async throws -> ResponseBody {
        let responseData = try await sendRequest(
            method,
            path: path,
            queryItems: queryItems,
            jsonBody: jsonBody,
            refusalKeysExplainedByRevyl: refusalKeysExplainedByRevyl,
            operationName: operationName
        )
        do {
            return try JSONDecoder.shipTokBackend.decode(ResponseBody.self, from: responseData)
        } catch {
            Self.logger.error("Revyl's answer to \(method, privacy: .public) \(path, privacy: .public) couldn't be read: \(String(describing: error), privacy: .public)")
            throw RevylShipTokAPIError.responseUnreadable(operationName: operationName)
        }
    }

    // Revyl's refusals carry {"detail": {"error", "key"}}, and the key, never the status alone, says which refusal it is (AGENTS.md, "Revyl Sign-In").
    private func sendRequest(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: (any Encodable & Sendable)? = nil,
        sendsRevylAPIKey: Bool = true,
        refusalKeysExplainedByRevyl: Set<String> = [],
        operationName: String
    ) async throws -> Data {
        guard let backendURL = RevylBackendConfiguration.backendURL else {
            throw RevylShipTokAPIError.backendNotConfigured
        }
        var request = URLRequest(
            url: backendURL.appending(path: "api/v1/shiptok/\(path)").appending(queryItems: queryItems),
            timeoutInterval: RevylBackendConfiguration.requestTimeoutSeconds
        )
        request.httpMethod = method
        if let jsonBody {
            request.httpBody = try JSONEncoder().encode(jsonBody)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if sendsRevylAPIKey, let revylAPIKey {
            request.setValue("Bearer \(revylAPIKey)", forHTTPHeaderField: "Authorization")
        }
        let (responseData, response) = try await Self.urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(statusCode) {
            return responseData
        }
        let refusal = RevylRefusal.decode(from: responseData)
        Self.logger.notice("Revyl answered \(statusCode) \(refusal?.key ?? "without a key", privacy: .public) to \(method, privacy: .public) \(path, privacy: .public)")
        let refusalError: RevylShipTokAPIError = switch (statusCode, refusal?.key) {
        case (_, let key?) where refusalKeysExplainedByRevyl.contains(key):
            refusal?.error.map { .explainedByRevyl(revylMessage: $0) } ?? .unexpectedResponse(operationName: operationName, statusCode: statusCode)
        case (_, "revyl_sign_in_required"?): .revylSignInRequired
        case (_, "revyl_person_required"?): .revylPersonRequired
        case (_, "revyl_organization_required"?): .revylOrganizationRequired
        case (_, "revyl_sign_in_expired"?): .revylSignInExpired
        case (_, "repository_not_found"?): .repositoryNotFound
        case (_, "github_app_not_installed"?): .githubAppNotInstalled
        case (_, "github_unavailable"?): .githubUnavailable
        case (_, "post_not_found"?): .postNotFound
        case (_, "feed_mode_tab_required"?): .feedModeTabRequired
        case (_, "organization_admin_required"?): .organizationAdminRequired
        case (_, "unavailable"?): .unavailable(operationName: operationName)
        case (_, "revyl_account_owns_organization"?):
            refusal?.error.map { .revylAccountOwnsOrganization(revylMessage: $0) } ?? .unexpectedResponse(operationName: operationName, statusCode: statusCode)
        case (429, _): .rateLimited
        default: .unexpectedResponse(operationName: operationName, statusCode: statusCode)
        }
        if refusalError.refusesSignIn, sendsRevylAPIKey, revylAPIKey != nil, let onSignInRefused {
            await onSignInRefused(refusalError)
        }
        throw refusalError
    }
}

// A refusal's body. Validation errors and 429s carry other details, so a body that doesn't read as one is no refusal key at all.
private struct RevylRefusal: Decodable {
    let error: String?
    let key: String?

    private struct Body: Decodable {
        let detail: RevylRefusal
    }

    static func decode(from responseData: Data) -> RevylRefusal? {
        try? JSONDecoder().decode(Body.self, from: responseData).detail
    }
}

// None of these routes redirects, and a followed redirect would carry the Revyl key or a sign-in code wherever it pointed, so a 3xx comes back as an unexpected answer instead (AGENTS.md, "iOS App").
private final class RevylAPIRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct AuthorizationURLResponse: Decodable {
    let authorizationURLString: String

    enum CodingKeys: String, CodingKey {
        case authorizationURLString = "authorization_url"
    }
}

private struct RevylAPIKeyResponse: Decodable {
    let revylAPIKey: String

    enum CodingKeys: String, CodingKey {
        case revylAPIKey = "revyl_api_key"
    }
}

private struct RepositoriesResponse: Decodable {
    let repositories: [ShipTokRepository]
}

private struct DeckResponse: Decodable {
    let posts: [ShipTokPost]
}

private struct InboxReadThroughResponse: Decodable {
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
    }
}

private struct VibeRequestBody: Encodable, Sendable {
    let vibe: String
    let feedbackText: String?

    enum CodingKeys: String, CodingKey {
        case vibe
        case feedbackText = "feedback_text"
    }
}

private struct CommentRequestBody: Encodable, Sendable {
    let body: String
    let parentCommentID: String?

    enum CodingKeys: String, CodingKey {
        case body
        case parentCommentID = "parent_comment_id"
    }
}
