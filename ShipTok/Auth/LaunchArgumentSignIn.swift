import Foundation
import OSLog

// A Revyl session profile signs a session's app in through `-KEY value` launch arguments (scripts/revyl/signed-in-session-profile.py). Only whoever launches the app (Revyl, Xcode or devicectl) can pass them, never a link or another app, and a launch from the Home Screen carries none, so an ordinary launch never signs in this way (AGENTS.md, "Revyl").
enum LaunchArgumentSignIn {
    private static let gitHubUserAccessTokenArgumentName = "SHIPTOK_LAUNCH_SIGN_IN_GITHUB_USER_ACCESS_TOKEN"
    private static let feedRepositoryFullNameArgumentName = "SHIPTOK_LAUNCH_SIGN_IN_FEED_REPOSITORY_FULL_NAME"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")

    static var gitHubUserAccessToken: String? { launchArgumentValue(named: gitHubUserAccessTokenArgumentName) }

    // The token comes without a refresh token, so the app never rotates the grant the profile keeps, and the sign-in ends once GitHub stops taking the token.
    static func signIn(gitHubUserAccessToken: String) async throws -> StoredGitHubSignIn {
        let tokens = GitHubUserAccessTokens(accessToken: gitHubUserAccessToken, accessTokenExpiresAt: nil, refreshToken: nil)
        let user = try await GitHubAccountAPI(accessTokenVault: GitHubAccessTokenVault(tokens: tokens)).fetchSignedInUserIdentity()
        let storedSignIn = StoredGitHubSignIn(tokens: tokens, user: user)
        try GitHubSignInKeychainStore.saveStoredSignIn(storedSignIn)
        if let feedRepositoryFullName = launchArgumentValue(named: feedRepositoryFullNameArgumentName) {
            UserDefaults.standard.set(feedRepositoryFullName, forKey: FeedRepositoryChoice.defaultsKey(githubUserID: user.githubUserID))
        }
        logger.info("Signed in from the launch arguments")
        return storedSignIn
    }

    private static func launchArgumentValue(named argumentName: String) -> String? {
        let launchArguments = ProcessInfo.processInfo.arguments
        guard let nameIndex = launchArguments.lastIndex(of: "-\(argumentName)"), nameIndex + 1 < launchArguments.endIndex else { return nil }
        let value = launchArguments[nameIndex + 1]
        return value.isEmpty ? nil : value
    }
}
