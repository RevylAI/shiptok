import AuthenticationServices
import Observation
import OSLog
import SwiftUI

enum GitHubSignInCallbackError: LocalizedError {
    case stateMismatch
    case codeMissing(reason: String?)

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            "Sign-in came back from a different attempt. Try again."
        case .codeMissing(let reason):
            reason ?? "Sign-in didn't finish. Try again."
        }
    }
}

// Revyl's part of Delete my ShipTok data is done, and only this iPhone's is left to try again.
struct ShipTokDataDeletionUnfinishedError: LocalizedError {
    let keychainError: Error

    var errorDescription: String? {
        "Revyl deleted your ShipTok data. \(keychainError.localizedDescription) Try again to finish on this iPhone."
    }
}

@Observable
@MainActor
final class GitHubSignInSession {
    enum Phase {
        case restoring
        case signedOut(message: String?)
        case exploringDemo(DemoVisitor, signInFailureMessage: String?)
        case signedIn(SignedInTeammate)
    }

    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")
    private static let signedOutReasonDefaultsKey = "signed-out-reason"
    private static let signInCallbackURLScheme = "shiptok"

    private(set) var phase: Phase = .restoring
    private(set) var isSigningIn = false
    private(set) var isOpeningDemo = false
    private(set) var isDeletingShipTokData = false
    // Revyl's deletion revokes the sign-in's token, so it can't run twice, and trying again finishes only what's left on this iPhone.
    private var revylDataDeletedSignInID: UUID?
    private let shipTokAPI = RevylShipTokAPI()

    var demoSignInFailureMessage: String? {
        guard case .exploringDemo(_, let signInFailureMessage) = phase else { return nil }
        return signInFailureMessage
    }

    private var demoVisitor: DemoVisitor? {
        guard case .exploringDemo(let demoVisitor, _) = phase else { return nil }
        return demoVisitor
    }

    func restoreSavedSession() {
        let storedSignIn: StoredGitHubSignIn?
        do {
            storedSignIn = try GitHubSignInKeychainStore.loadStoredSignIn()
        } catch {
            phase = .signedOut(message: error.localizedDescription)
            return
        }
        guard let storedSignIn else {
            phase = .signedOut(message: UserDefaults.standard.string(forKey: Self.signedOutReasonDefaultsKey))
            return
        }
        activate(storedSignIn)
    }

    // The demo needs no account, so it opens on whatever the demo feed holds; a demo Revyl's backend can't serve leaves the person on the sign-in screen with why.
    func exploreDemo() async {
        isOpeningDemo = true
        defer { isOpeningDemo = false }
        let demoFeed = ShipTokDemoFeed()
        do {
            let repositoryFullName = try await demoFeed.repositoryFullName()
            let visitID = UUID()
            let demoVisitor = DemoVisitor(
                visitID: visitID,
                repositoryFullName: repositoryFullName,
                demoFeed: demoFeed,
                analytics: ShipTokAnalytics(demoVisitID: visitID),
                hiddenPeopleStore: .forDemoVisit()
            )
            demoVisitor.analytics.capture(.demoEntered)
            Self.logger.info("Opened the demo feed")
            phase = .exploringDemo(demoVisitor, signInFailureMessage: nil)
        } catch {
            Self.logger.error("Opening the demo feed failed")
            phase = .signedOut(message: error.localizedDescription)
        }
    }

    // From the demo, a completed sign-in lands in the signed-in app and a failed one keeps the demo, saying why.
    func signIn(using webAuthenticationSession: WebAuthenticationSession) async {
        isSigningIn = true
        defer { isSigningIn = false }
        let demoVisitor = self.demoVisitor
        if let demoVisitor {
            phase = .exploringDemo(demoVisitor, signInFailureMessage: nil)
        }
        let signInAttemptID = UUID()
        let signInAttemptAnalytics = ShipTokAnalytics(signInAttemptID: signInAttemptID)
        signInAttemptAnalytics.capture(.signInStarted(attemptID: signInAttemptID, demoVisitID: demoVisitor?.visitID))
        let proofKey = ProofKeyForCodeExchange.generate()
        let signInState = randomURLSafeString(byteCount: 32)
        do {
            let authorizationURL = try await shipTokAPI.gitHubSignInAuthorizationURL(state: signInState, codeChallenge: proofKey.codeChallenge)
            // Ephemeral, since the shared session's prompt breaks sign-in on an unfolded iPhone Duo (AGENTS.md, "iOS App").
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: authorizationURL,
                callbackURLScheme: Self.signInCallbackURLScheme,
                preferredBrowserSession: .ephemeral
            )
            let callbackQueryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard callbackQueryItems.first(where: { $0.name == "state" })?.value == signInState else {
                throw GitHubSignInCallbackError.stateMismatch
            }
            guard let authorizationCode = callbackQueryItems.first(where: { $0.name == "code" })?.value else {
                throw GitHubSignInCallbackError.codeMissing(reason: callbackQueryItems.first(where: { $0.name == "error_description" })?.value)
            }
            let tokens = try await shipTokAPI.exchangeGitHubSignInCode(authorizationCode, codeVerifier: proofKey.codeVerifier)
            let user = try await GitHubAccountAPI(accessTokenVault: GitHubAccessTokenVault(tokens: tokens)).fetchSignedInUserIdentity()
            let storedSignIn = StoredGitHubSignIn(tokens: tokens, user: user)
            try GitHubSignInKeychainStore.saveStoredSignIn(storedSignIn)
            UserDefaults.standard.removeObject(forKey: Self.signedOutReasonDefaultsKey)
            Self.logger.info("Signed in with Revyl")
            activate(storedSignIn).analytics.capture(.signInCompleted(attemptID: signInAttemptID, demoVisitID: demoVisitor?.visitID))
        } catch {
            let failureReason = Self.signInFailureReason(for: error)
            signInAttemptAnalytics.capture(.signInFailed(attemptID: signInAttemptID, reason: failureReason, demoVisitID: demoVisitor?.visitID))
            if failureReason == .cancelled { return }
            if let demoVisitor {
                phase = .exploringDemo(demoVisitor, signInFailureMessage: error.localizedDescription)
            } else {
                phase = .signedOut(message: error.localizedDescription)
            }
        }
    }

    // GitHub keeps what the person wrote there, so this deletes what Revyl and this iPhone hold and revokes ShipTok's GitHub token (AGENTS.md, "Ownership And Boundaries").
    func deleteShipTokData() async throws {
        guard case .signedIn(let teammate) = phase, !isDeletingShipTokData else { return }
        isDeletingShipTokData = true
        defer { isDeletingShipTokData = false }
        if revylDataDeletedSignInID != teammate.signInID {
            try await teammate.accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
                try await shipTokAPI.deleteUserData(gitHubAccessToken: accessToken)
            }
            revylDataDeletedSignInID = teammate.signInID
        }
        do {
            try GitHubSignInKeychainStore.deleteStoredSignIn()
        } catch {
            throw ShipTokDataDeletionUnfinishedError(keychainError: error)
        }
        teammate.analytics.capture(.signInEnded(reason: .dataDeleted))
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        phase = .signedOut(message: "Your ShipTok data is deleted. Your comments, reactions and vibes stay on GitHub.")
        PullRequestMediaMemoryCache.removeAllLoadedMediaAndStopDownloads()
        await PullRequestMediaDiskCache.finishPendingSaves()
        Self.deleteCachedFiles()
        Self.logger.info("Deleted this person's ShipTok data")
    }

    // Deleting the data ends the sign-in itself, so it can't be signed out of meanwhile. A sign-in the Keychain still holds would come back on the next launch, so it stays until the Keychain lets it go.
    func signOut() throws {
        guard case .signedIn(let teammate) = phase, !isDeletingShipTokData else { return }
        try GitHubSignInKeychainStore.deleteStoredSignIn()
        end(teammate, reason: .signedOut, message: nil)
    }

    // A rejection ends only the sign-in its request ran for. Deleting the data revokes the sign-in's GitHub token, so rejections while it runs, or after only this iPhone's part is left, are its own doing.
    func handleRejectedGitHubAccess(_ githubAPIError: GitHubAPIError, endingSignInID signInID: UUID) {
        guard case .signedIn(let teammate) = phase, teammate.signInID == signInID, !isDeletingShipTokData,
              revylDataDeletedSignInID != signInID
        else { return }
        // GitHub no longer takes this sign-in, so one the Keychain fails to forget is only refused again on the next launch; the store logs the failure.
        try? GitHubSignInKeychainStore.deleteStoredSignIn()
        end(teammate, reason: .githubRejected, message: githubAPIError.localizedDescription)
    }

    private static func signInFailureReason(for error: Error) -> ShipTokAnalyticsEvent.SignInFailureReason {
        switch error {
        case let webAuthenticationError as ASWebAuthenticationSessionError where webAuthenticationError.code == .canceledLogin:
            .cancelled
        case GitHubSignInCallbackError.stateMismatch:
            .stateMismatch
        case GitHubSignInCallbackError.codeMissing:
            .githubRefused
        case RevylShipTokAPIError.signInRejected:
            .revylRejected
        case is GitHubSignInKeychainError:
            .keychainFailed
        default:
            .unavailable
        }
    }

    private static func deleteCachedFiles() {
        let cachedFileURLs: [URL]
        do {
            cachedFileURLs = try FileManager.default.contentsOfDirectory(at: .cachesDirectory, includingPropertiesForKeys: nil)
        } catch {
            logger.error("Listing ShipTok's cached files to delete failed")
            return
        }
        for cachedFileURL in cachedFileURLs {
            do {
                try FileManager.default.removeItem(at: cachedFileURL)
            } catch {
                logger.error("Deleting a cached ShipTok file failed")
            }
        }
    }

    @discardableResult
    private func activate(_ storedSignIn: StoredGitHubSignIn) -> SignedInTeammate {
        let accessTokenVault = GitHubAccessTokenVault(tokens: storedSignIn.tokens)
        let teammate = SignedInTeammate(
            user: storedSignIn.user,
            accountAPI: GitHubAccountAPI(accessTokenVault: accessTokenVault),
            accessTokenVault: accessTokenVault,
            analytics: ShipTokAnalytics(githubUserID: storedSignIn.user.githubUserID),
            hiddenPeopleStore: HiddenPeopleStore(githubUserID: storedSignIn.user.githubUserID)
        )
        phase = .signedIn(teammate)
        return teammate
    }

    // The reason outlives the process, so a sign-in GitHub rejected while the app was in the background still says why on the next launch.
    private func end(_ teammate: SignedInTeammate, reason: ShipTokAnalyticsEvent.SignInEndReason, message: String?) {
        teammate.analytics.capture(.signInEnded(reason: reason))
        UserDefaults.standard.set(message, forKey: Self.signedOutReasonDefaultsKey)
        phase = .signedOut(message: message)
    }
}
