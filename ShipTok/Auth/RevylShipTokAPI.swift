import Foundation
import OSLog

// Every build signs in through the Revyl backend its SHIPTOK_REVYL_BACKEND_URL build setting names, production by default; device tests that sign in point it at a development backend (AGENTS.md, "iOS App").
enum RevylBackendConfiguration {
    static let backendURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "RevylBackendURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    static let requestTimeoutSeconds: TimeInterval = 60
}

struct GitHubUserAccessTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var accessTokenExpiresAt: Date?
    var refreshToken: String?
}

enum RevylShipTokAPIError: LocalizedError {
    case backendNotConfigured
    case demoUnavailable
    case signInRejected(operationName: String)
    case unexpectedResponse(operationName: String, statusCode: Int)
    case responseUnreadable(operationName: String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "This build names no Revyl backend. Build it with SHIPTOK_REVYL_BACKEND_URL set to a Revyl backend URL."
        case .demoUnavailable:
            "The demo isn't available right now. Try again in a minute, or sign in with Revyl."
        case .signInRejected:
            "GitHub didn't accept this sign-in. Sign in with Revyl again."
        case .unexpectedResponse(let operationName, let statusCode):
            "Revyl answered \(statusCode) to \(operationName)."
        case .responseUnreadable(let operationName):
            "Revyl's answer to \(operationName) couldn't be read."
        }
    }
}

// Revyl's backend redeems and refreshes GitHub sign-ins, since both need its GitHub App's client secret, keeps each person's settings, and serves the demo feed someone sees before signing in. It never sees a signed-in person's GitHub reads or writes: the app calls GitHub directly.
struct RevylShipTokAPI: Sendable {
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "revyl-backend")
    private static let urlSession: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        return URLSession(configuration: sessionConfiguration)
    }()

    func gitHubSignInAuthorizationURL(state: String, codeChallenge: String) async throws -> URL {
        let response: AuthorizationURLResponse = try await send(
            "GET",
            path: "github-sign-in/authorization-url",
            queryItems: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: codeChallenge)],
            operationName: "the sign-in link"
        )
        guard let authorizationURL = URL(string: response.authorizationURLString) else {
            throw RevylShipTokAPIError.responseUnreadable(operationName: "the sign-in link")
        }
        return authorizationURL
    }

    func exchangeGitHubSignInCode(_ code: String, codeVerifier: String) async throws -> GitHubUserAccessTokens {
        let response: UserAccessTokensResponse = try await send(
            "POST",
            path: "github-sign-in/user-access-tokens",
            jsonBody: ["code": code, "code_verifier": codeVerifier],
            operationName: "the sign-in"
        )
        return response.tokens(receivedAt: Date())
    }

    func refreshGitHubAccessToken(refreshToken: String) async throws -> GitHubUserAccessTokens {
        let response: UserAccessTokensResponse = try await send(
            "POST",
            path: "github-sign-in/user-access-token-refreshes",
            jsonBody: ["refresh_token": refreshToken],
            operationName: "the sign-in refresh"
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
        if statusCode == 401 {
            Self.logger.notice("Revyl answered 401 to \(method, privacy: .public) \(path, privacy: .public)")
            throw RevylShipTokAPIError.signInRejected(operationName: operationName)
        }
        guard (200..<300).contains(statusCode) else {
            Self.logger.error("Revyl answered \(statusCode) to \(method, privacy: .public) \(path, privacy: .public)")
            throw RevylShipTokAPIError.unexpectedResponse(operationName: operationName, statusCode: statusCode)
        }
        return responseData
    }
}

private struct AuthorizationURLResponse: Decodable {
    let authorizationURLString: String

    enum CodingKeys: String, CodingKey {
        case authorizationURLString = "authorization_url"
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
