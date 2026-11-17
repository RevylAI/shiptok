import Foundation
import OSLog

// GitHub App user access tokens expire after 8 hours and each refresh token works once, so one refresh at a time renews the pair and saves it before anyone uses it; two at once would retire each other's tokens and sign the person out. A sign-in ends only when GitHub refuses the refresh (shiptok/AGENTS.md, "iOS App").
actor GitHubAccessTokenVault {
    private static let refreshMarginSeconds: TimeInterval = 5 * 60
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")

    private var tokens: GitHubUserAccessTokens
    private var inFlightRefresh: Task<GitHubUserAccessTokens, Error>?
    private let shipTokAPI = RevylShipTokAPI()

    init(tokens: GitHubUserAccessTokens) {
        self.tokens = tokens
    }

    func validAccessToken() async throws -> String {
        guard tokens.refreshToken != nil,
              let accessTokenExpiresAt = tokens.accessTokenExpiresAt,
              accessTokenExpiresAt.timeIntervalSinceNow <= Self.refreshMarginSeconds
        else {
            return tokens.accessToken
        }
        return try await refreshedTokens().accessToken
    }

    func accessTokenReplacing(rejectedAccessToken: String) async throws -> String {
        if tokens.accessToken != rejectedAccessToken {
            return tokens.accessToken
        }
        guard tokens.refreshToken != nil else {
            throw GitHubAPIError.accessTokenRejected
        }
        return try await refreshedTokens().accessToken
    }

    // Revyl checks the GitHub token on every request, so a token another refresh just retired is renewed once and the request tried again.
    func sendRevylRequest<Response: Sendable>(_ request: @Sendable (String) async throws -> Response) async throws -> Response {
        let accessToken = try await validAccessToken()
        do {
            return try await request(accessToken)
        } catch RevylShipTokAPIError.signInRejected {
            return try await request(accessTokenReplacing(rejectedAccessToken: accessToken))
        }
    }

    private func refreshedTokens() async throws -> GitHubUserAccessTokens {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }
        guard let refreshToken = tokens.refreshToken else {
            throw GitHubAPIError.accessTokenRejected
        }
        // Saved inside the task, so the rotated pair reaches the Keychain even if every caller has gone away.
        let refreshTask = Task { [shipTokAPI] in
            do {
                let rotatedTokens = try await shipTokAPI.refreshGitHubAccessToken(refreshToken: refreshToken)
                GitHubSignInKeychainStore.saveRotatedTokens(rotatedTokens, rotatedFromRefreshToken: refreshToken)
                Self.logger.info("Refreshed the GitHub sign-in")
                return rotatedTokens
            } catch RevylShipTokAPIError.signInRejected {
                Self.logger.error("GitHub refused to refresh the sign-in")
                throw GitHubAPIError.accessTokenRejected
            }
        }
        inFlightRefresh = refreshTask
        defer { inFlightRefresh = nil }
        let rotatedTokens = try await refreshTask.value
        tokens = rotatedTokens
        return rotatedTokens
    }
}
