import Foundation
import OSLog

// GitHub App user access tokens expire after 8 hours and each refresh token works once, so one refresh at a time renews the pair and saves it before anyone uses it; two at once would retire each other's tokens and sign the person out. A sign-in ends only when GitHub refuses the refresh (AGENTS.md, "iOS App").
actor GitHubAccessTokenVault {
    private static let refreshMarginSeconds: TimeInterval = 5 * 60
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")

    private struct TokenRotation {
        let rotatedTokens: GitHubUserAccessTokens
        let spentRefreshToken: String
    }

    private var tokens: GitHubUserAccessTokens
    private var inFlightRefresh: Task<GitHubUserAccessTokens, Error>?
    // GitHub honors only this pair's refresh token once it's issued, so a pair the Keychain failed to save is saved again instead of refreshing anew.
    private var unsavedRotation: TokenRotation?
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

    // Saved inside the task, so every caller waits for the save and the rotated pair reaches the Keychain even if they've all gone away.
    private func refreshedTokens() async throws -> GitHubUserAccessTokens {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }
        let refreshTask = Task { try await rotateAndSaveTokens() }
        inFlightRefresh = refreshTask
        defer { inFlightRefresh = nil }
        let savedTokens = try await refreshTask.value
        tokens = savedTokens
        return savedTokens
    }

    private func rotateAndSaveTokens() async throws -> GitHubUserAccessTokens {
        let rotation: TokenRotation
        if let unsavedRotation {
            rotation = unsavedRotation
        } else {
            guard let refreshToken = tokens.refreshToken else {
                throw GitHubAPIError.accessTokenRejected
            }
            do {
                rotation = TokenRotation(
                    rotatedTokens: try await shipTokAPI.refreshGitHubAccessToken(refreshToken: refreshToken),
                    spentRefreshToken: refreshToken
                )
            } catch RevylShipTokAPIError.signInRejected {
                Self.logger.error("GitHub refused to refresh the sign-in")
                throw GitHubAPIError.accessTokenRejected
            }
            unsavedRotation = rotation
        }
        let saveOutcome = try GitHubSignInKeychainStore.saveRotatedTokens(rotation.rotatedTokens, rotatedFromRefreshToken: rotation.spentRefreshToken)
        unsavedRotation = nil
        switch saveOutcome {
        case .saved:
            Self.logger.info("Refreshed the GitHub sign-in")
            return rotation.rotatedTokens
        case .signInEnded:
            throw CancellationError()
        }
    }
}
