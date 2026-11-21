import Foundation
import OSLog

// GitHub App user access tokens expire after 8 hours and each refresh token works once, so one refresh at a time renews the pair and saves it before anyone uses it; two at once would retire each other's tokens and sign the person out. A sign-in ends only when GitHub refuses the refresh (AGENTS.md, "iOS App"). Revyl's App Review account holds a token Revyl lends it instead, which only Revyl renews and which is never saved; each renewal retires the token before it, so those also run one at a time (AGENTS.md, "Revyl Sign-In").
actor GitHubAccessTokenVault {
    private static let refreshMarginSeconds: TimeInterval = 5 * 60
    private static let appReviewRenewalMarginSeconds: TimeInterval = 30 * 60
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")

    private struct TokenRotation {
        let rotatedTokens: GitHubUserAccessTokens
        let spentRefreshToken: String
    }

    private var tokens: GitHubUserAccessTokens
    private var inFlightRenewal: Task<GitHubUserAccessTokens, Error>?
    // GitHub honors only this pair's refresh token once it's issued, so a pair the Keychain failed to save is saved again instead of refreshing anew.
    private var unsavedRotation: TokenRotation?
    private nonisolated let appReviewRevylAPIKey: String?
    private let shipTokAPI = RevylShipTokAPI()

    nonisolated var isAppReview: Bool { appReviewRevylAPIKey != nil }

    init(tokens: GitHubUserAccessTokens) {
        self.tokens = tokens
        appReviewRevylAPIKey = nil
    }

    init(appReviewTokens: GitHubUserAccessTokens, revylAPIKey: String) {
        tokens = appReviewTokens
        appReviewRevylAPIKey = revylAPIKey
    }

    func validAccessToken() async throws -> String {
        guard isAppReview || tokens.refreshToken != nil,
              let accessTokenExpiresAt = tokens.accessTokenExpiresAt,
              accessTokenExpiresAt.timeIntervalSinceNow <= (isAppReview ? Self.appReviewRenewalMarginSeconds : Self.refreshMarginSeconds)
        else {
            return tokens.accessToken
        }
        return try await renewedTokens(rejectedAccessToken: nil).accessToken
    }

    func accessTokenReplacing(rejectedAccessToken: String) async throws -> String {
        if tokens.accessToken != rejectedAccessToken {
            return tokens.accessToken
        }
        guard isAppReview || tokens.refreshToken != nil else {
            throw GitHubAPIError.accessTokenRejected
        }
        return try await renewedTokens(rejectedAccessToken: rejectedAccessToken).accessToken
    }

    // Revyl checks the GitHub token on every request, so a token another refresh just retired is renewed once and the request tried again.
    func sendRevylRequest<Response: Sendable>(_ request: @Sendable (String) async throws -> Response) async throws -> Response {
        let accessToken = try await validAccessToken()
        do {
            return try await request(accessToken)
        } catch RevylShipTokAPIError.githubSignInRejected {
            return try await request(accessTokenReplacing(rejectedAccessToken: accessToken))
        }
    }

    // Saved inside the task, so every caller waits for the save and the rotated pair reaches the Keychain even if they've all gone away.
    private func renewedTokens(rejectedAccessToken: String?) async throws -> GitHubUserAccessTokens {
        if let inFlightRenewal {
            return try await inFlightRenewal.value
        }
        let renewalTask = Task {
            guard let appReviewRevylAPIKey else { return try await rotateAndSaveTokens() }
            return try await requestAppReviewTokens(revylAPIKey: appReviewRevylAPIKey, rejectedAccessToken: rejectedAccessToken)
        }
        inFlightRenewal = renewalTask
        defer { inFlightRenewal = nil }
        let newTokens = try await renewalTask.value
        tokens = newTokens
        return newTokens
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
            } catch RevylShipTokAPIError.githubSignInRejected {
                Self.logger.error("GitHub refused to refresh the sign-in")
                throw GitHubAPIError.accessTokenRejected
            }
            unsavedRotation = rotation
        }
        let saveOutcome = try ShipTokSignInKeychainStore.saveRotatedGitHubTokens(rotation.rotatedTokens, rotatedFromRefreshToken: rotation.spentRefreshToken)
        unsavedRotation = nil
        switch saveOutcome {
        case .saved:
            Self.logger.info("Refreshed the GitHub sign-in")
            return rotation.rotatedTokens
        case .signInEnded:
            throw CancellationError()
        }
    }

    // Revyl stops lending the token once the account is no longer its App Review account, which ends this GitHub sign-in as GitHub refusing it would.
    private func requestAppReviewTokens(revylAPIKey: String, rejectedAccessToken: String?) async throws -> GitHubUserAccessTokens {
        do {
            let appReviewTokens = try await shipTokAPI.requestAppReviewGitHubAccessTokens(revylAPIKey: revylAPIKey, rejectedAccessToken: rejectedAccessToken)
            Self.logger.info("Renewed the App Review GitHub access")
            return appReviewTokens
        } catch RevylShipTokAPIError.appReviewAccountRequired {
            Self.logger.error("Revyl no longer lends this Revyl account App Review GitHub access")
            throw GitHubAPIError.accessTokenRejected
        }
    }
}
