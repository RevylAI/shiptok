import Foundation
import OSLog

// Every build signs in through the Revyl backend its SHIPTOK_REVYL_BACKEND_URL build setting names, production by default; device tests that sign in point it at a development backend (AGENTS.md, "iOS App").
enum RevylBackendConfiguration {
    static let backendURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "RevylBackendURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    static let requestTimeoutSeconds: TimeInterval = 60
    private static let defaultPortByScheme = ["https": 443, "http": 80]

    // Only a hosted video's canonical link on this build's own backend may carry the person's Revyl key: never another host a pull request names, and never a link whose userinfo, escapes or dot segments could make it mean another place, so its path must read exactly as the backend's hosted video route and the upload (AGENTS.md, "Signed Media URLs").
    static func servesHostedShipTokVideo(at url: URL) -> Bool {
        guard PullRequestMediaItem.isHostedShipTokVideoURL(url), url.user() == nil, url.password() == nil,
              let backendURL, let scheme = url.scheme?.lowercased(), scheme == backendURL.scheme?.lowercased(),
              let host = url.host()?.lowercased(), host == backendURL.host()?.lowercased(),
              (url.port ?? defaultPortByScheme[scheme]) == (backendURL.port ?? defaultPortByScheme[scheme])
        else { return false }
        let canonicalVideoURL = backendURL.appending(path: "api/v1/shiptok/videos").appending(path: url.lastPathComponent)
        return url.path(percentEncoded: true) == canonicalVideoURL.path(percentEncoded: true)
    }
}

struct GitHubUserAccessTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var accessTokenExpiresAt: Date?
    var refreshToken: String?
}

enum RevylShipTokAPIError: LocalizedError {
    case backendNotConfigured
    case demoUnavailable
    // Revyl, asking GitHub, refused the GitHub token a request carried.
    case githubSignInRejected(operationName: String)
    case revylSignInRequired
    case revylOrganizationRequired
    case revylSignInExpired
    case githubAccountNotConnected
    case revylAccountOwnsOrganization(revylMessage: String)
    case organizationJoinRequestEmailInvalid
    case organizationJoinRequestRateLimited
    case unexpectedResponse(operationName: String, statusCode: Int)
    case responseUnreadable(operationName: String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "This build names no Revyl backend. Build it with SHIPTOK_REVYL_BACKEND_URL set to a Revyl backend URL."
        case .demoUnavailable:
            "The demo isn't available right now. Try again in a minute, or connect GitHub."
        case .githubSignInRejected:
            "GitHub didn't accept your GitHub sign-in. Connect GitHub again."
        case .revylSignInRequired:
            "Your Revyl sign-in has ended. Sign in to Revyl again."
        case .revylOrganizationRequired:
            "Your Revyl account isn't in an organization any more. Ask your organization's owner or an admin to invite you, then sign in again."
        case .revylSignInExpired:
            "That Revyl sign-in expired before ShipTok could finish it. Sign in to Revyl again."
        case .githubAccountNotConnected:
            "Your GitHub account isn't connected to your Revyl account. Connect GitHub to see your team's repositories."
        case .revylAccountOwnsOrganization(let revylMessage):
            revylMessage
        case .organizationJoinRequestEmailInvalid:
            "That doesn't look like an email address. Check it and try again."
        case .organizationJoinRequestRateLimited:
            "Too many requests from here. Try again in a minute."
        case .unexpectedResponse(let operationName, let statusCode):
            "Revyl answered \(statusCode) to \(operationName)."
        case .responseUnreadable(let operationName):
            "Revyl's answer to \(operationName) couldn't be read."
        }
    }
}

// Revyl's backend signs people in to Revyl, connects their GitHub account to their Revyl account, redeems and refreshes GitHub sign-ins, since both need its GitHub App's client secret, keeps each person's settings, takes requests to join an organization, and serves the demo feed someone sees before they connect GitHub. It never sees a person's GitHub reads or writes: the app calls GitHub directly.
struct RevylShipTokAPI: Sendable {
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "revyl-backend")
    private static let urlSession: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        return URLSession(configuration: sessionConfiguration)
    }()

    func revylSignInAuthorizationURL(state: String, codeChallenge: String) async throws -> URL {
        try await authorizationURL(path: "revyl-sign-in/authorization-url", state: state, codeChallenge: codeChallenge, operationName: "the Revyl sign-in link")
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

    func revokeRevylAPIKey(_ revylAPIKey: String) async throws {
        _ = try await sendRequest("DELETE", path: "revyl-sign-in/api-key", bearerToken: revylAPIKey, operationName: "signing out of Revyl")
    }

    // Throws githubAccountNotConnected when the Revyl account has no GitHub account connected.
    func fetchConnectedGitHubUserID(revylAPIKey: String) async throws -> Int64 {
        let response: GitHubAccountResponse = try await send("GET", path: "github-account", bearerToken: revylAPIKey, operationName: "your GitHub connection")
        return response.githubUserID
    }

    // Revyl reads the GitHub account from the token and connects it to the Revyl account; the latest connection wins.
    func connectGitHubAccount(githubAccessToken: String, revylAPIKey: String) async throws -> Int64 {
        let response: GitHubAccountResponse = try await send(
            "PUT",
            path: "github-account",
            jsonBody: ["github_access_token": githubAccessToken],
            bearerToken: revylAPIKey,
            operationName: "connecting your GitHub account"
        )
        return response.githubUserID
    }

    // Revyl answers the same whatever it found, so the app never learns whether an organization matched.
    func submitOrganizationJoinRequest(email: String) async throws {
        do {
            _ = try await sendRequest("POST", path: "organization-join-requests", jsonBody: ["email": email], operationName: "your request")
        } catch RevylShipTokAPIError.unexpectedResponse(_, 422) {
            throw RevylShipTokAPIError.organizationJoinRequestEmailInvalid
        } catch RevylShipTokAPIError.unexpectedResponse(_, 429) {
            throw RevylShipTokAPIError.organizationJoinRequestRateLimited
        }
    }

    func gitHubSignInAuthorizationURL(state: String, codeChallenge: String) async throws -> URL {
        try await authorizationURL(path: "github-sign-in/authorization-url", state: state, codeChallenge: codeChallenge, operationName: "the GitHub sign-in link")
    }

    func exchangeGitHubSignInCode(_ code: String, codeVerifier: String) async throws -> GitHubUserAccessTokens {
        let response: UserAccessTokensResponse = try await send(
            "POST",
            path: "github-sign-in/user-access-tokens",
            jsonBody: ["code": code, "code_verifier": codeVerifier],
            operationName: "the GitHub sign-in"
        )
        return response.tokens(receivedAt: Date())
    }

    func refreshGitHubAccessToken(refreshToken: String) async throws -> GitHubUserAccessTokens {
        let response: UserAccessTokensResponse = try await send(
            "POST",
            path: "github-sign-in/user-access-token-refreshes",
            jsonBody: ["refresh_token": refreshToken],
            operationName: "the GitHub sign-in refresh"
        )
        return response.tokens(receivedAt: Date())
    }

    func fetchUserSettings(gitHubAccessToken: String) async throws -> UserSettings {
        try await send("GET", path: "user-settings", bearerToken: gitHubAccessToken, operationName: "your settings")
    }

    func replaceUserSettings(_ userSettings: UserSettings, gitHubAccessToken: String) async throws -> UserSettings {
        try await send("PUT", path: "user-settings", jsonBody: userSettings, bearerToken: gitHubAccessToken, operationName: "your settings")
    }

    // The raw snapshot, since only the GitHub client reads its GitHub-shaped nodes.
    func fetchDemoFeed() async throws -> Data {
        do {
            return try await sendRequest("GET", path: "demo-feed", operationName: "the demo")
        } catch RevylShipTokAPIError.unexpectedResponse(_, 503) {
            throw RevylShipTokAPIError.demoUnavailable
        }
    }

    func deleteUserData(gitHubAccessToken: String) async throws {
        _ = try await sendRequest("DELETE", path: "user-data", bearerToken: gitHubAccessToken, operationName: "deleting your ShipTok data")
    }

    private func authorizationURL(path: String, state: String, codeChallenge: String, operationName: String) async throws -> URL {
        let response: AuthorizationURLResponse = try await send(
            "GET",
            path: path,
            queryItems: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: codeChallenge)],
            operationName: operationName
        )
        guard let authorizationURL = URL(string: response.authorizationURLString) else {
            throw RevylShipTokAPIError.responseUnreadable(operationName: operationName)
        }
        return authorizationURL
    }

    private func send<ResponseBody: Decodable>(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: (any Encodable & Sendable)? = nil,
        bearerToken: String? = nil,
        operationName: String
    ) async throws -> ResponseBody {
        let responseData = try await sendRequest(method, path: path, queryItems: queryItems, jsonBody: jsonBody, bearerToken: bearerToken, operationName: operationName)
        do {
            return try JSONDecoder().decode(ResponseBody.self, from: responseData)
        } catch {
            Self.logger.error("Revyl's answer to \(method, privacy: .public) \(path, privacy: .public) couldn't be read")
            throw RevylShipTokAPIError.responseUnreadable(operationName: operationName)
        }
    }

    // Revyl's refusals carry {"detail": {"error", "key"}}, and the key, never the status alone, says which refusal it is (AGENTS.md, "Revyl Sign-In").
    private func sendRequest(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: (any Encodable & Sendable)? = nil,
        bearerToken: String? = nil,
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
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (responseData, response) = try await Self.urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(statusCode) {
            return responseData
        }
        let refusal = RevylRefusal.decode(from: responseData)
        Self.logger.notice("Revyl answered \(statusCode) \(refusal?.key ?? "without a key", privacy: .public) to \(method, privacy: .public) \(path, privacy: .public)")
        switch (statusCode, refusal?.key) {
        case (_, RevylRefusal.revylSignInRequiredKey):
            throw RevylShipTokAPIError.revylSignInRequired
        case (_, RevylRefusal.revylOrganizationRequiredKey):
            throw RevylShipTokAPIError.revylOrganizationRequired
        case (_, "revyl_sign_in_expired"):
            throw RevylShipTokAPIError.revylSignInExpired
        case (_, "github_account_not_connected"):
            throw RevylShipTokAPIError.githubAccountNotConnected
        case (_, "revyl_account_owns_organization"):
            guard let revylMessage = refusal?.error else {
                throw RevylShipTokAPIError.unexpectedResponse(operationName: operationName, statusCode: statusCode)
            }
            throw RevylShipTokAPIError.revylAccountOwnsOrganization(revylMessage: revylMessage)
        case (401, _):
            throw RevylShipTokAPIError.githubSignInRejected(operationName: operationName)
        default:
            throw RevylShipTokAPIError.unexpectedResponse(operationName: operationName, statusCode: statusCode)
        }
    }
}

// A refusal's body. Validation errors carry a list as their detail, so a body that doesn't read as one is no refusal key at all.
struct RevylRefusal: Decodable {
    static let revylSignInRequiredKey = "revyl_sign_in_required"
    static let revylOrganizationRequiredKey = "revyl_organization_required"
    static let githubAccountRequiredKey = "github_account_required"

    let error: String?
    let key: String?

    private struct Body: Decodable {
        let detail: RevylRefusal
    }

    static func decode(from responseData: Data) -> RevylRefusal? {
        try? JSONDecoder().decode(Body.self, from: responseData).detail
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

private struct GitHubAccountResponse: Decodable {
    let githubUserID: Int64

    enum CodingKeys: String, CodingKey {
        case githubUserID = "github_user_id"
    }
}

private struct UserAccessTokensResponse: Decodable {
    let accessToken: String
    let accessTokenExpiresInSeconds: Double?
    let refreshToken: String?

    func tokens(receivedAt: Date) -> GitHubUserAccessTokens {
        GitHubUserAccessTokens(
            accessToken: accessToken,
            accessTokenExpiresAt: accessTokenExpiresInSeconds.map { receivedAt.addingTimeInterval($0) },
            refreshToken: refreshToken
        )
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenExpiresInSeconds = "access_token_expires_in_seconds"
        case refreshToken = "refresh_token"
    }
}
