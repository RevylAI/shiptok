import Foundation
import OSLog

// A Revyl session profile signs a session's app in through `-KEY value` launch arguments (scripts/revyl/signed-in-session-profile.py): both parts of the sign-in, a Revyl key and a GitHub user access token, and the feed's repository. Only whoever launches the app (Revyl, Xcode or devicectl) can pass them, never a link or another app, and a launch from the Home Screen carries none, so an ordinary launch never signs in this way (AGENTS.md, "Revyl").
enum LaunchArgumentSignIn {
    struct PassedSignIn {
        let revylAPIKey: String
        let gitHubUserAccessToken: String
    }

    private static let revylAPIKeyArgumentName = "SHIPTOK_LAUNCH_SIGN_IN_REVYL_API_KEY"
    private static let gitHubUserAccessTokenArgumentName = "SHIPTOK_LAUNCH_SIGN_IN_GITHUB_USER_ACCESS_TOKEN"
    private static let feedRepositoryFullNameArgumentName = "SHIPTOK_LAUNCH_SIGN_IN_FEED_REPOSITORY_FULL_NAME"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")

    // Nothing works without the Revyl part, so a launch that passes only one part signs in no differently from an ordinary one.
    static var passedSignIn: PassedSignIn? {
        guard let revylAPIKey = launchArgumentValue(named: revylAPIKeyArgumentName),
              let gitHubUserAccessToken = launchArgumentValue(named: gitHubUserAccessTokenArgumentName)
        else { return nil }
        return PassedSignIn(revylAPIKey: revylAPIKey, gitHubUserAccessToken: gitHubUserAccessToken)
    }

    // The token comes without a refresh token, so the app never rotates the grant the profile keeps, and the GitHub part ends once GitHub stops taking the token.
    static func save(_ passedSignIn: PassedSignIn) async throws {
        let tokens = GitHubUserAccessTokens(accessToken: passedSignIn.gitHubUserAccessToken, accessTokenExpiresAt: nil, refreshToken: nil)
        let user = try await GitHubAccountAPI(accessTokenVault: GitHubAccessTokenVault(tokens: tokens)).fetchSignedInUserIdentity()
        try ShipTokSignInKeychainStore.saveStoredGitHubSignIn(StoredGitHubSignIn(tokens: tokens, user: user))
        try ShipTokSignInKeychainStore.saveRevylAPIKey(passedSignIn.revylAPIKey)
        if let feedRepositoryFullName = launchArgumentValue(named: feedRepositoryFullNameArgumentName) {
            UserDefaults.standard.set(feedRepositoryFullName, forKey: FeedRepositoryChoice.defaultsKey(githubUserID: user.githubUserID))
        }
        logger.info("Signed in from the launch arguments")
    }

    private static func launchArgumentValue(named argumentName: String) -> String? {
        let launchArguments = ProcessInfo.processInfo.arguments
        guard let nameIndex = launchArguments.lastIndex(of: "-\(argumentName)"), nameIndex + 1 < launchArguments.endIndex else { return nil }
        let value = launchArguments[nameIndex + 1]
        return value.isEmpty ? nil : value
    }
}
