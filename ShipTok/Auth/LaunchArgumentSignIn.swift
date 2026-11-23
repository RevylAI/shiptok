import Foundation
import OSLog

// A Revyl session profile signs a session's app in through `-KEY value` launch arguments (scripts/revyl/signed-in-session-profile.py): a ShipTok key for a Revyl test account, and the feed's repository. Only whoever launches the app (Revyl, Xcode or devicectl) can pass them, never a link or another app, and a launch from the Home Screen carries none, so an ordinary launch never signs in this way (AGENTS.md, "Revyl").
enum LaunchArgumentSignIn {
    private static let revylAPIKeyArgumentName = "SHIPTOK_LAUNCH_SIGN_IN_REVYL_API_KEY"
    private static let feedRepositoryFullNameArgumentName = "SHIPTOK_LAUNCH_SIGN_IN_FEED_REPOSITORY_FULL_NAME"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")

    static var passedRevylAPIKey: String? {
        launchArgumentValue(named: revylAPIKeyArgumentName)
    }

    // Saves the sign-in with the account Revyl says the key belongs to, and the feed's repository when one is passed and the organization's GitHub App covers it.
    static func save(revylAPIKey: String) async throws -> StoredRevylSignIn {
        let api = RevylShipTokAPI(revylAPIKey: revylAPIKey)
        let revylSignIn = StoredRevylSignIn(revylAPIKey: revylAPIKey, revylAccount: try await api.fetchRevylAccount())
        try ShipTokSignInKeychainStore.saveStoredRevylSignIn(revylSignIn)
        if let feedRepositoryFullName = launchArgumentValue(named: feedRepositoryFullNameArgumentName) {
            let repositories = try await api.fetchRepositories()
            if let feedRepository = repositories.first(where: { $0.fullName.caseInsensitiveCompare(feedRepositoryFullName) == .orderedSame }) {
                FeedRepositoryChoice(repository: feedRepository).save(revylUserID: revylSignIn.revylAccount.revylUserID)
            } else {
                logger.error("The launch arguments' feed repository isn't one Revyl's GitHub App covers for this organization")
            }
        }
        logger.info("Signed in from the launch arguments")
        return revylSignIn
    }

    private static func launchArgumentValue(named argumentName: String) -> String? {
        let launchArguments = ProcessInfo.processInfo.arguments
        guard let nameIndex = launchArguments.lastIndex(of: "-\(argumentName)"), nameIndex + 1 < launchArguments.endIndex else { return nil }
        let value = launchArguments[nameIndex + 1]
        return value.isEmpty ? nil : value
    }
}
