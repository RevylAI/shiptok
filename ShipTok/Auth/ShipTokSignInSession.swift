import AuthenticationServices
import Observation
import OSLog
import SwiftUI

enum SignInCallbackError: LocalizedError {
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

// A deletion Revyl has done its part of, which can't run twice, and what it still owes: the GitHub token revocation Delete my Revyl account leaves to the app, then this iPhone's part. It's saved in the defaults as soon as Revyl confirms, so a quit or a failure leaves it for the next launch or Revyl sign-in to finish, and this iPhone's part removes it last, with the rest of the defaults (AGENTS.md, "Ownership And Boundaries").
struct UnfinishedDeletion {
    enum Kind: String {
        case shipTokData = "shiptok_data"
        case revylAccount = "revyl_account"
    }

    enum GitHubTokenRevocation: String {
        case owed
        case failed
        case notOwed = "not_owed"
    }

    private static let defaultsKey = "unfinished-deletion"
    // Releases from before the Revyl sign-in saved only an unfinished Delete my ShipTok data, as the person's GitHub user ID.
    private static let earlierReleasesShipTokDataDeletionDefaultsKey = "unfinished-data-deletion-github-user-id"

    let kind: Kind
    var gitHubTokenRevocation: GitHubTokenRevocation

    static func loadSaved() -> UnfinishedDeletion? {
        if let savedDeletion = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
           let kind = savedDeletion["kind"].flatMap(Kind.init(rawValue:)),
           let gitHubTokenRevocation = savedDeletion["github_token_revocation"].flatMap(GitHubTokenRevocation.init(rawValue:)) {
            return UnfinishedDeletion(kind: kind, gitHubTokenRevocation: gitHubTokenRevocation)
        }
        guard UserDefaults.standard.object(forKey: earlierReleasesShipTokDataDeletionDefaultsKey) != nil else { return nil }
        return UnfinishedDeletion(kind: .shipTokData, gitHubTokenRevocation: .notOwed)
    }

    func save() {
        UserDefaults.standard.set(["kind": kind.rawValue, "github_token_revocation": gitHubTokenRevocation.rawValue], forKey: Self.defaultsKey)
    }

    var signInEndReason: ShipTokAnalyticsEvent.SignInEndReason {
        switch kind {
        case .shipTokData: .dataDeleted
        case .revylAccount: .revylAccountDeleted
        }
    }

    var firstScreenShowReason: ShipTokAnalyticsEvent.FirstScreenShowReason {
        switch kind {
        case .shipTokData: .dataDeleted
        case .revylAccount: .revylAccountDeleted
        }
    }

    var completionMessage: String {
        switch (kind, gitHubTokenRevocation) {
        case (.shipTokData, _):
            "Your ShipTok data is deleted. Your comments, reactions and vibes stay on GitHub."
        case (.revylAccount, .failed):
            "Your Revyl account is deleted, but ShipTok couldn't end its access to your GitHub account. Revoke Revyl's GitHub App under Applications in your GitHub settings. Your comments, reactions and vibes stay on GitHub."
        case (.revylAccount, .owed), (.revylAccount, .notOwed):
            "Your Revyl account is deleted. Your comments, reactions and vibes stay on GitHub."
        }
    }
}

// Revyl's part of a deletion is done, and only this iPhone's is left to try again.
struct UnfinishedDeletionError: LocalizedError {
    let kind: UnfinishedDeletion.Kind
    let cleanupError: any Error

    var errorDescription: String? {
        let revylPart = switch kind {
        case .shipTokData: "Revyl deleted your ShipTok data."
        case .revylAccount: "Revyl deleted your Revyl account."
        }
        return "\(revylPart) \(cleanupError.localizedDescription) Try again or open ShipTok again to finish on this iPhone."
    }
}

// One showing of the first screen. Nobody is signed in there, so it has an analytics identity of its own, and it opens on Join existing organization when Revyl said the account left every organization.
struct FirstScreenVisit {
    let visitID: UUID
    var message: String?
    let opensJoinOrganization: Bool
    let analytics: ShipTokAnalytics
}

// The sign-in has two parts: Revyl's, without which nothing but the first screen shows, and GitHub's, which the feed reads and writes GitHub with. Signed in to Revyl without a connected GitHub account, the person looks around the demo; with both, their own feed (AGENTS.md, "Revyl Sign-In").
@Observable
@MainActor
final class ShipTokSignInSession {
    enum Phase {
        case restoring
        case signedOut(FirstScreenVisit)
        case exploringDemo(DemoVisitor, githubConnectionFailureMessage: String?)
        // Signed in to Revyl without a connected GitHub account while the demo can't open.
        case connectingGitHub(message: String)
        case signedIn(SignedInTeammate)
    }

    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")
    private static let signedOutReasonDefaultsKey = "signed-out-reason"
    private static let signInCallbackURLScheme = "shiptok"

    private(set) var phase: Phase = .restoring
    private(set) var isSigningInToRevyl = false
    private(set) var isConnectingGitHub = false
    private(set) var isOpeningDemo = false
    private(set) var isSigningOut = false
    private(set) var isDeletingShipTokData = false
    private(set) var isDeletingRevylAccount = false
    // The Keychain's Revyl key, nil while the first screen shows. Work started for one Revyl sign-in checks its key is still the one held before it changes anything, so it never touches a later sign-in.
    private var revylAPIKey: String?
    private var isVerifyingRevylSignIn = false
    private let shipTokAPI = RevylShipTokAPI()

    var githubConnectionFailureMessage: String? {
        guard case .exploringDemo(_, let githubConnectionFailureMessage) = phase else { return nil }
        return githubConnectionFailureMessage
    }

    private var demoVisitor: DemoVisitor? {
        guard case .exploringDemo(let demoVisitor, _) = phase else { return nil }
        return demoVisitor
    }

    func restoreSavedSession() async {
        do {
            if let finishedDeletion = try await finishUnfinishedDeletion() {
                showFirstScreen(reason: finishedDeletion.firstScreenShowReason, message: finishedDeletion.completionMessage)
                return
            }
        } catch {
            showFirstScreen(reason: .failure, message: error.localizedDescription)
            return
        }
        let storedGitHubSignIn: StoredGitHubSignIn?
        let storedRevylAPIKey: String?
        do {
            storedGitHubSignIn = try ShipTokSignInKeychainStore.loadStoredGitHubSignIn()
            storedRevylAPIKey = try ShipTokSignInKeychainStore.loadRevylAPIKey()
        } catch {
            showFirstScreen(reason: .failure, message: error.localizedDescription)
            return
        }
        let signedOutReason = UserDefaults.standard.string(forKey: Self.signedOutReasonDefaultsKey)
        guard let storedRevylAPIKey else {
            // A GitHub sign-in without a Revyl one comes from an app that signed in with GitHub alone, or from a Revyl sign-in that ended; the next Revyl sign-in connects it.
            if let storedGitHubSignIn {
                showFirstScreen(
                    reason: .githubSignInWithoutRevylSignIn,
                    message: signedOutReason ?? "ShipTok now signs in with Revyl. Sign in to Revyl and ShipTok keeps using your GitHub account @\(storedGitHubSignIn.user.githubLogin)."
                )
            } else {
                showFirstScreen(reason: .noSignIn, message: signedOutReason)
            }
            return
        }
        revylAPIKey = storedRevylAPIKey
        guard let storedGitHubSignIn else {
            await exploreDemo(githubConnectionFailureMessage: signedOutReason)
            return
        }
        activate(user: storedGitHubSignIn.user, accessTokenVault: GitHubAccessTokenVault(tokens: storedGitHubSignIn.tokens), revylAPIKey: storedRevylAPIKey)
    }

    func signInToRevyl(using webAuthenticationSession: WebAuthenticationSession) async {
        guard case .signedOut(var firstScreenVisit) = phase, !isSigningInToRevyl else { return }
        isSigningInToRevyl = true
        defer { isSigningInToRevyl = false }
        let signInAttemptID = UUID()
        firstScreenVisit.analytics.capture(.revylSignInStarted(attemptID: signInAttemptID))
        let newRevylAPIKey: String
        do {
            // An unfinished deletion would take a new sign-in with it on the next launch, so it finishes before Revyl's sign-in opens.
            if let finishedDeletion = try await finishUnfinishedDeletion() {
                firstScreenVisit.message = finishedDeletion.completionMessage
                phase = .signedOut(firstScreenVisit)
            }
            let proofKey = ProofKeyForCodeExchange.generate()
            let signInState = randomURLSafeString(byteCount: 32)
            let authorizationURL = try await shipTokAPI.revylSignInAuthorizationURL(state: signInState, codeChallenge: proofKey.codeChallenge)
            let callbackURL = try await Self.authenticate(using: webAuthenticationSession, at: authorizationURL)
            let authorizationCode = try Self.authorizationCode(in: callbackURL, matchingState: signInState)
            newRevylAPIKey = try await shipTokAPI.exchangeRevylSignInCode(
                authorizationCode,
                codeVerifier: proofKey.codeVerifier,
                deviceLabel: "ShipTok on \(UIDevice.current.model)"
            )
            try ShipTokSignInKeychainStore.saveRevylAPIKey(newRevylAPIKey)
        } catch {
            let failureReason = Self.revylSignInFailureReason(for: error)
            firstScreenVisit.analytics.capture(.revylSignInFailed(attemptID: signInAttemptID, reason: failureReason))
            // An account in no organization gets the join choices on Revyl's page and closes it, which iOS reports as a cancel, so the first screen stays as it was.
            if failureReason == .cancelled { return }
            firstScreenVisit.message = error.localizedDescription
            phase = .signedOut(firstScreenVisit)
            return
        }
        revylAPIKey = newRevylAPIKey
        UserDefaults.standard.removeObject(forKey: Self.signedOutReasonDefaultsKey)
        Self.logger.info("Signed in to Revyl")
        await connectStoredGitHubSignInOrExploreDemo(revylAPIKey: newRevylAPIKey)
    }

    // Connects GitHub for a person signed in to Revyl: the GitHub sign-in this iPhone holds while GitHub still takes it, else GitHub's own sign-in, and once Revyl connects it the person lands in their own feed. A failed connection keeps them where they were, saying why.
    func connectGitHub(using webAuthenticationSession: WebAuthenticationSession) async {
        guard let revylAPIKey, !isConnectingGitHub, !isDeletingRevylAccount else { return }
        switch phase {
        case .exploringDemo, .connectingGitHub: break
        case .restoring, .signedOut, .signedIn: return
        }
        isConnectingGitHub = true
        defer { isConnectingGitHub = false }
        let demoVisitor = self.demoVisitor
        if let demoVisitor {
            phase = .exploringDemo(demoVisitor, githubConnectionFailureMessage: nil)
        }
        do {
            if let storedGitHubSignIn = try ShipTokSignInKeychainStore.loadStoredGitHubSignIn() {
                let accessTokenVault = GitHubAccessTokenVault(tokens: storedGitHubSignIn.tokens)
                do {
                    try await connectGitHubAccount(using: accessTokenVault, revylAPIKey: revylAPIKey)
                    finishConnectingGitHub(user: storedGitHubSignIn.user, accessTokenVault: accessTokenVault, revylAPIKey: revylAPIKey, leaving: demoVisitor)
                    return
                } catch where Self.isGitHubSignInRefusal(error) {
                    try ShipTokSignInKeychainStore.deleteStoredGitHubSignIn()
                }
            }
        } catch {
            failConnectingGitHub(error, revylAPIKey: revylAPIKey, demoVisitor: demoVisitor)
            return
        }
        let signInAttemptID = UUID()
        let signInAttemptAnalytics = ShipTokAnalytics(signInAttemptID: signInAttemptID)
        signInAttemptAnalytics.capture(.githubSignInStarted(attemptID: signInAttemptID, demoVisitID: demoVisitor?.visitID))
        do {
            let proofKey = ProofKeyForCodeExchange.generate()
            let signInState = randomURLSafeString(byteCount: 32)
            let authorizationURL = try await shipTokAPI.gitHubSignInAuthorizationURL(state: signInState, codeChallenge: proofKey.codeChallenge)
            let callbackURL = try await Self.authenticate(using: webAuthenticationSession, at: authorizationURL)
            let authorizationCode = try Self.authorizationCode(in: callbackURL, matchingState: signInState)
            let tokens = try await shipTokAPI.exchangeGitHubSignInCode(authorizationCode, codeVerifier: proofKey.codeVerifier)
            let accessTokenVault = GitHubAccessTokenVault(tokens: tokens)
            let user = try await GitHubAccountAPI(accessTokenVault: accessTokenVault).fetchSignedInUserIdentity()
            try ShipTokSignInKeychainStore.saveStoredGitHubSignIn(StoredGitHubSignIn(tokens: tokens, user: user))
            Self.logger.info("Signed in with GitHub")
            try await connectGitHubAccount(using: accessTokenVault, revylAPIKey: revylAPIKey)
            finishConnectingGitHub(user: user, accessTokenVault: accessTokenVault, revylAPIKey: revylAPIKey, leaving: demoVisitor)?
                .analytics.capture(.githubSignInCompleted(attemptID: signInAttemptID, demoVisitID: demoVisitor?.visitID))
        } catch {
            signInAttemptAnalytics.capture(.githubSignInFailed(attemptID: signInAttemptID, reason: Self.githubSignInFailureReason(for: error), demoVisitID: demoVisitor?.visitID))
            failConnectingGitHub(error, revylAPIKey: revylAPIKey, demoVisitor: demoVisitor)
        }
    }

    func openDemoAgain() async {
        guard case .connectingGitHub = phase, !isDeletingRevylAccount else { return }
        await exploreDemo()
    }

    // Revyl may end the sign-in, the account may leave every organization, or its GitHub connection may move to another Revyl account while ShipTok sleeps, so each launch and return to the foreground asks Revyl which GitHub account is connected (AGENTS.md, "Revyl Sign-In").
    func verifyRevylSignIn() async {
        guard let revylAPIKey, !isVerifyingRevylSignIn, !isSigningInToRevyl, !isConnectingGitHub, !isSigningOut, !isDeletingShipTokData, !isDeletingRevylAccount else { return }
        isVerifyingRevylSignIn = true
        defer { isVerifyingRevylSignIn = false }
        let connectedGitHubUserID: Int64?
        do {
            connectedGitHubUserID = try await shipTokAPI.fetchConnectedGitHubUserID(revylAPIKey: revylAPIKey)
        } catch RevylShipTokAPIError.githubAccountNotConnected {
            connectedGitHubUserID = nil
        } catch {
            if !endRevylSignInIfRefused(error, revylAPIKey: revylAPIKey) {
                Self.logger.notice("Checking the Revyl sign-in failed: \(error.publicLogDescription, privacy: .public)")
            }
            return
        }
        guard self.revylAPIKey == revylAPIKey, !isConnectingGitHub, !isSigningOut, !isDeletingShipTokData, !isDeletingRevylAccount else { return }
        switch phase {
        case .signedIn(let teammate) where connectedGitHubUserID != teammate.user.githubUserID:
            leaveFeedForDemo(teammate, reason: .githubAccountNotConnected, message: RevylShipTokAPIError.githubAccountNotConnected.localizedDescription)
        // A connection that went through while its answer was lost leaves the GitHub sign-in on the iPhone already connected.
        case .exploringDemo(let demoVisitor, _):
            guard let connectedGitHubUserID,
                  let storedGitHubSignIn = try? ShipTokSignInKeychainStore.loadStoredGitHubSignIn(),
                  storedGitHubSignIn.user.githubUserID == connectedGitHubUserID
            else { return }
            finishConnectingGitHub(
                user: storedGitHubSignIn.user,
                accessTokenVault: GitHubAccessTokenVault(tokens: storedGitHubSignIn.tokens),
                revylAPIKey: revylAPIKey,
                leaving: demoVisitor
            )
        case .restoring, .signedOut, .connectingGitHub, .signedIn:
            break
        }
    }

    // GitHub keeps what the person wrote there, so this deletes what Revyl and this iPhone hold, revokes ShipTok's GitHub token and the Revyl key, and signs out (AGENTS.md, "Ownership And Boundaries").
    func deleteShipTokData() async throws {
        guard case .signedIn(let teammate) = phase, let revylAPIKey, !isDeletingShipTokData, !isDeletingRevylAccount, !isSigningOut, !teammate.feedWork.hasStopped else { return }
        isDeletingShipTokData = true
        defer { isDeletingShipTokData = false }
        try await teammate.accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
            try await shipTokAPI.deleteUserData(gitHubAccessToken: accessToken)
        }
        // Revyl's part can't run again, so what's left is saved before anything else can stop it.
        let unfinishedDeletion = UnfinishedDeletion(kind: .shipTokData, gitHubTokenRevocation: .notOwed)
        unfinishedDeletion.save()
        await revokeRevylAPIKeyIfRevylCan(revylAPIKey)
        self.revylAPIKey = nil
        teammate.mediaCache.stopDownloadsAndRemoveAllMedia()
        // A feed read that finishes after the files go would save its feeds again, so the feed's work stops and drains first.
        await teammate.feedWork.stopAndWaitForRunningWork()
        // Revyl has revoked the sign-in's tokens, so its feed can't work any more: if this iPhone's part fails, the app leaves for the first screen saying the deletion is unfinished, as the next launch would.
        do {
            try await finishDeletingOnThisIPhone(unfinishedDeletion)
            showFirstScreen(reason: unfinishedDeletion.firstScreenShowReason, message: unfinishedDeletion.completionMessage)
        } catch {
            showFirstScreen(reason: .failure, message: error.localizedDescription)
        }
    }

    // Revyl deletes the account with its keys, its GitHub connection and that GitHub account's ShipTok settings; then the GitHub token this iPhone holds is revoked as Delete my ShipTok data revokes it, and the iPhone forgets everything ShipTok kept. Revyl's part can't run twice, since it revokes the key, so what's left is saved as soon as Revyl confirms, with or without a GitHub sign-in on this iPhone, and a failed revocation tells the person where to revoke it on GitHub (AGENTS.md, "Revyl Sign-In").
    func deleteRevylAccount() async throws {
        guard let revylAPIKey, !isDeletingRevylAccount, !isDeletingShipTokData, !isSigningOut else { return }
        let teammate: SignedInTeammate?
        switch phase {
        case .signedIn(let signedInTeammate):
            guard !signedInTeammate.feedWork.hasStopped else { return }
            teammate = signedInTeammate
        case .exploringDemo, .connectingGitHub:
            teammate = nil
        case .restoring, .signedOut:
            return
        }
        let demoVisitor = self.demoVisitor
        let viewerAnalytics = teammate?.analytics ?? demoVisitor?.analytics
        viewerAnalytics?.capture(.revylAccountDeletionRequested)
        isDeletingRevylAccount = true
        defer { isDeletingRevylAccount = false }
        do {
            try await shipTokAPI.deleteRevylAccount(revylAPIKey: revylAPIKey)
        } catch {
            let failureReason: ShipTokAnalyticsEvent.RevylAccountDeletionFailureReason = switch error {
            case RevylShipTokAPIError.revylAccountOwnsOrganization: .ownsOrganization
            default: .unavailable
            }
            viewerAnalytics?.capture(.revylAccountDeletionFailed(reason: failureReason))
            isDeletingRevylAccount = false
            guard !endRevylSignInIfRefused(error, revylAPIKey: revylAPIKey) else { return }
            throw error
        }
        var unfinishedDeletion = UnfinishedDeletion(kind: .revylAccount, gitHubTokenRevocation: .owed)
        unfinishedDeletion.save()
        self.revylAPIKey = nil
        Self.logger.info("Deleted the Revyl account")
        unfinishedDeletion.gitHubTokenRevocation = await revokeGitHubAccessToken(heldBy: teammate?.accessTokenVault)
        unfinishedDeletion.save()
        if let teammate {
            teammate.mediaCache.stopDownloadsAndRemoveAllMedia()
            await teammate.feedWork.stopAndWaitForRunningWork()
        } else if let demoVisitor {
            demoVisitor.analytics.capture(.signInEnded(reason: .revylAccountDeleted))
            demoVisitor.mediaCache.stopDownloadsAndRemoveAllMedia()
            demoVisitor.feedWork.stop()
        }
        do {
            try await finishDeletingOnThisIPhone(unfinishedDeletion)
            showFirstScreen(reason: unfinishedDeletion.firstScreenShowReason, message: unfinishedDeletion.completionMessage)
        } catch {
            showFirstScreen(reason: .failure, message: error.localizedDescription)
        }
    }

    // Signing out ends both parts of the sign-in. A sign-in the Keychain still holds would come back on the next launch, so nothing ends until the Keychain lets both go, and nobody can sign out while a deletion runs. The feed's reads and saves stop and drain before it ends, so nothing is saved for it afterwards.
    func signOut() async throws {
        guard let revylAPIKey, !isDeletingShipTokData, !isDeletingRevylAccount, !isSigningOut else { return }
        if case .signedIn(let teammate) = phase, teammate.feedWork.hasStopped { return }
        isSigningOut = true
        defer { isSigningOut = false }
        await revokeRevylAPIKeyIfRevylCan(revylAPIKey)
        try ShipTokSignInKeychainStore.deleteStoredGitHubSignIn()
        try ShipTokSignInKeychainStore.deleteRevylAPIKey()
        guard self.revylAPIKey == revylAPIKey else { return }
        self.revylAPIKey = nil
        if case .signedIn(let teammate) = phase {
            await teammate.feedWork.stopAndWaitForRunningWork()
        }
        stopShownViewer(reason: .signedOut, message: nil)
        showFirstScreen(reason: .signedOut, message: nil)
    }

    // GitHub refusing the sign-in ends only its GitHub part: the person stays signed in to Revyl and looks around the demo until they connect GitHub again. A rejection ends only the sign-in its request ran for, and deleting the data revokes the GitHub token, so rejections while it runs are its own doing.
    func handleRejectedGitHubAccess(_ githubAPIError: GitHubAPIError, endingSignInID signInID: UUID) {
        guard case .signedIn(let teammate) = phase, teammate.signInID == signInID, !isDeletingShipTokData, !isDeletingRevylAccount, !isSigningOut else { return }
        // GitHub no longer takes this sign-in, so one the Keychain fails to forget is only refused again on the next launch; the store logs the failure.
        try? ShipTokSignInKeychainStore.deleteStoredGitHubSignIn()
        leaveFeedForDemo(teammate, reason: .githubRejected, message: githubAPIError.localizedDescription)
    }

    private func showFirstScreen(reason: ShipTokAnalyticsEvent.FirstScreenShowReason, message: String?, opensJoinOrganization: Bool = false) {
        let visitID = UUID()
        let analytics = ShipTokAnalytics(firstScreenVisitID: visitID)
        analytics.capture(.firstScreenShown(reason: reason))
        if opensJoinOrganization {
            analytics.capture(.joinOrganizationShown(reason: .revylOrganizationRequired))
        }
        phase = .signedOut(FirstScreenVisit(visitID: visitID, message: message, opensJoinOrganization: opensJoinOrganization, analytics: analytics))
    }

    // A person signed in to Revyl who hasn't connected GitHub looks around the public demo Revyl's backend serves; one it can't serve leaves only Connect GitHub, saying why (AGENTS.md, "Demo Mode").
    private func exploreDemo(githubConnectionFailureMessage: String? = nil) async {
        guard let revylAPIKey, !isOpeningDemo else { return }
        isOpeningDemo = true
        defer { isOpeningDemo = false }
        let demoFeed = ShipTokDemoFeed()
        let repositoryFullName: String
        do {
            repositoryFullName = try await demoFeed.repositoryFullName()
        } catch {
            Self.logger.error("Opening the demo feed failed")
            guard self.revylAPIKey == revylAPIKey else { return }
            phase = .connectingGitHub(message: [githubConnectionFailureMessage, error.localizedDescription].compactMap { $0 }.joined(separator: " "))
            return
        }
        guard self.revylAPIKey == revylAPIKey else { return }
        let visitID = UUID()
        let demoVisitor = DemoVisitor(
            visitID: visitID,
            repositoryFullName: repositoryFullName,
            demoFeed: demoFeed,
            analytics: ShipTokAnalytics(demoVisitID: visitID),
            hiddenPeopleStore: .forDemoVisit(),
            mediaCache: FeedViewerMediaCache(savedMedia: .forDemoVisits, hostedVideoRevylSignIn: nil),
            feedWork: FeedViewerWork()
        )
        demoVisitor.analytics.capture(.demoEntered)
        Self.logger.info("Opened the demo feed")
        phase = .exploringDemo(demoVisitor, githubConnectionFailureMessage: githubConnectionFailureMessage)
    }

    // A GitHub sign-in this iPhone already holds, from an app that signed in with GitHub alone or from a Revyl sign-in that ended, connects to the Revyl account without another trip through GitHub.
    private func connectStoredGitHubSignInOrExploreDemo(revylAPIKey: String) async {
        let storedGitHubSignIn: StoredGitHubSignIn?
        do {
            storedGitHubSignIn = try ShipTokSignInKeychainStore.loadStoredGitHubSignIn()
        } catch {
            await exploreDemo(githubConnectionFailureMessage: error.localizedDescription)
            return
        }
        guard let storedGitHubSignIn else {
            await exploreDemo()
            return
        }
        let accessTokenVault = GitHubAccessTokenVault(tokens: storedGitHubSignIn.tokens)
        do {
            try await connectGitHubAccount(using: accessTokenVault, revylAPIKey: revylAPIKey)
        } catch {
            guard !endRevylSignInIfRefused(error, revylAPIKey: revylAPIKey) else { return }
            await exploreDemo(githubConnectionFailureMessage: messageAfterFailedGitHubConnection(error))
            return
        }
        guard self.revylAPIKey == revylAPIKey else { return }
        activate(user: storedGitHubSignIn.user, accessTokenVault: accessTokenVault, revylAPIKey: revylAPIKey)
    }

    private func connectGitHubAccount(using accessTokenVault: GitHubAccessTokenVault, revylAPIKey: String) async throws {
        _ = try await accessTokenVault.sendRevylRequest { [shipTokAPI] githubAccessToken in
            try await shipTokAPI.connectGitHubAccount(githubAccessToken: githubAccessToken, revylAPIKey: revylAPIKey)
        }
        Self.logger.info("Connected the GitHub account to the Revyl account")
    }

    @discardableResult
    private func finishConnectingGitHub(user: GitHubUserIdentity, accessTokenVault: GitHubAccessTokenVault, revylAPIKey: String, leaving demoVisitor: DemoVisitor?) -> SignedInTeammate? {
        guard self.revylAPIKey == revylAPIKey else { return nil }
        UserDefaults.standard.removeObject(forKey: Self.signedOutReasonDefaultsKey)
        demoVisitor?.feedWork.stop()
        return activate(user: user, accessTokenVault: accessTokenVault, revylAPIKey: revylAPIKey)
    }

    private func failConnectingGitHub(_ error: any Error, revylAPIKey: String, demoVisitor: DemoVisitor?) {
        guard !endRevylSignInIfRefused(error, revylAPIKey: revylAPIKey), self.revylAPIKey == revylAPIKey, !Self.isWebAuthenticationCancellation(error) else { return }
        let message = messageAfterFailedGitHubConnection(error)
        switch phase {
        case .exploringDemo(let shownDemoVisitor, _) where shownDemoVisitor.visitID == demoVisitor?.visitID:
            phase = .exploringDemo(shownDemoVisitor, githubConnectionFailureMessage: message)
        case .connectingGitHub:
            phase = .connectingGitHub(message: message)
        case .restoring, .signedOut, .exploringDemo, .signedIn:
            break
        }
    }

    // GitHub refusing the GitHub sign-in this iPhone holds ends it, so the next Connect GitHub goes through GitHub; any other failure keeps it for the next try.
    private func messageAfterFailedGitHubConnection(_ error: any Error) -> String {
        guard Self.isGitHubSignInRefusal(error) else { return error.localizedDescription }
        try? ShipTokSignInKeychainStore.deleteStoredGitHubSignIn()
        return GitHubAPIError.accessTokenRejected.localizedDescription
    }

    // Revyl refusing the key on any route ends the Revyl sign-in: a key it no longer takes leads to the first screen, and an account outside every organization to Join existing organization (AGENTS.md, "Revyl Sign-In"). True when the error was such a refusal.
    @discardableResult
    private func endRevylSignInIfRefused(_ error: any Error, revylAPIKey refusedRevylAPIKey: String) -> Bool {
        let endReason: ShipTokAnalyticsEvent.SignInEndReason
        switch error {
        case RevylShipTokAPIError.revylSignInRequired: endReason = .revylSignInRequired
        case RevylShipTokAPIError.revylOrganizationRequired: endReason = .revylOrganizationRequired
        default: return false
        }
        guard revylAPIKey == refusedRevylAPIKey, !isDeletingShipTokData, !isDeletingRevylAccount, !isSigningOut else { return true }
        if endReason == .revylOrganizationRequired {
            // The key of an account outside every organization may still be live, so Revyl is asked to revoke it as on sign-out; the iPhone forgets it either way.
            Task { await revokeRevylAPIKeyIfRevylCan(refusedRevylAPIKey) }
        }
        // A key the Keychain fails to forget is refused again on the next launch, which ends it then; the store logs the failure. The GitHub sign-in stays, so the next Revyl sign-in connects it again.
        try? ShipTokSignInKeychainStore.deleteRevylAPIKey()
        revylAPIKey = nil
        stopShownViewer(reason: endReason, message: error.localizedDescription)
        showFirstScreen(
            reason: endReason == .revylOrganizationRequired ? .revylOrganizationRequired : .revylSignInRequired,
            message: error.localizedDescription,
            opensJoinOrganization: endReason == .revylOrganizationRequired
        )
        return true
    }

    private func revokeRevylAPIKeyIfRevylCan(_ revylAPIKey: String) async {
        do {
            try await shipTokAPI.revokeRevylAPIKey(revylAPIKey)
        } catch {
            Self.logger.notice("Revyl didn't revoke the Revyl key, so this iPhone only forgets it: \(error.publicLogDescription, privacy: .public)")
        }
    }

    // The GitHub sign-in stays on the iPhone, so Connect GitHub connects it again in one tap.
    private func leaveFeedForDemo(_ teammate: SignedInTeammate, reason: ShipTokAnalyticsEvent.SignInEndReason, message: String) {
        end(teammate, reason: reason, message: message)
        phase = .restoring
        Task { await exploreDemo(githubConnectionFailureMessage: message) }
    }

    // The reason outlives the process, so a sign-in that ended while the app was in the background still says why on the next launch.
    private func stopShownViewer(reason: ShipTokAnalyticsEvent.SignInEndReason, message: String?) {
        switch phase {
        case .signedIn(let teammate):
            end(teammate, reason: reason, message: message)
        case .exploringDemo(let demoVisitor, _):
            demoVisitor.analytics.capture(.signInEnded(reason: reason))
            UserDefaults.standard.set(message, forKey: Self.signedOutReasonDefaultsKey)
            demoVisitor.mediaCache.stopDownloadsAndRemoveAllMedia()
            demoVisitor.feedWork.stop()
        case .restoring, .signedOut, .connectingGitHub:
            UserDefaults.standard.set(message, forKey: Self.signedOutReasonDefaultsKey)
        }
    }

    private func end(_ teammate: SignedInTeammate, reason: ShipTokAnalyticsEvent.SignInEndReason, message: String?) {
        teammate.analytics.capture(.signInEnded(reason: reason))
        UserDefaults.standard.set(message, forKey: Self.signedOutReasonDefaultsKey)
        teammate.mediaCache.stopDownloadsAndRemoveAllMedia()
        teammate.feedWork.stop()
    }

    // A hosted video refused for the Revyl sign-in itself says no more than that something changed, so Revyl's answer to GET /github-account decides what the app does (AGENTS.md, "Signed Media URLs").
    @discardableResult
    private func activate(user: GitHubUserIdentity, accessTokenVault: GitHubAccessTokenVault, revylAPIKey: String) -> SignedInTeammate {
        let hostedVideoRevylSignIn = HostedVideoRevylSignIn(revylAPIKey: revylAPIKey) { [weak self] in
            Task { await self?.verifyRevylSignIn() }
        }
        let teammate = SignedInTeammate(
            user: user,
            accountAPI: GitHubAccountAPI(accessTokenVault: accessTokenVault),
            accessTokenVault: accessTokenVault,
            analytics: ShipTokAnalytics(githubUserID: user.githubUserID),
            hiddenPeopleStore: HiddenPeopleStore(githubUserID: user.githubUserID),
            mediaCache: FeedViewerMediaCache(
                savedMedia: .forSignedInGitHubUser(id: user.githubUserID),
                hostedVideoRevylSignIn: hostedVideoRevylSignIn
            ),
            feedWork: FeedViewerWork()
        )
        phase = .signedIn(teammate)
        return teammate
    }

    // Ephemeral, since the shared session's prompt breaks sign-in on an unfolded iPhone Duo (AGENTS.md, "iOS App").
    private static func authenticate(using webAuthenticationSession: WebAuthenticationSession, at authorizationURL: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(
            using: authorizationURL,
            callbackURLScheme: signInCallbackURLScheme,
            preferredBrowserSession: .ephemeral
        )
    }

    private static func authorizationCode(in callbackURL: URL, matchingState signInState: String) throws -> String {
        let callbackQueryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callbackQueryItems.first(where: { $0.name == "state" })?.value == signInState else {
            throw SignInCallbackError.stateMismatch
        }
        guard let authorizationCode = callbackQueryItems.first(where: { $0.name == "code" })?.value else {
            throw SignInCallbackError.codeMissing(reason: callbackQueryItems.first(where: { $0.name == "error_description" })?.value)
        }
        return authorizationCode
    }

    private static func isWebAuthenticationCancellation(_ error: any Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }

    // A vault that can't save a refresh for a sign-in that ended throws CancellationError, which also means the GitHub sign-in is gone.
    private static func isGitHubSignInRefusal(_ error: any Error) -> Bool {
        switch error {
        case GitHubAPIError.accessTokenRejected, RevylShipTokAPIError.githubSignInRejected, is CancellationError: true
        default: false
        }
    }

    private static func revylSignInFailureReason(for error: any Error) -> ShipTokAnalyticsEvent.RevylSignInFailureReason {
        if isWebAuthenticationCancellation(error) { return .cancelled }
        switch error {
        case SignInCallbackError.stateMismatch:
            return .stateMismatch
        case SignInCallbackError.codeMissing:
            return .codeMissing
        case RevylShipTokAPIError.revylSignInExpired:
            return .signInExpired
        case let unfinishedDeletionError as UnfinishedDeletionError:
            return revylSignInFailureReason(for: unfinishedDeletionError.cleanupError)
        case is ShipTokSignInKeychainError:
            return .keychainFailed
        default:
            return .unavailable
        }
    }

    private static func githubSignInFailureReason(for error: any Error) -> ShipTokAnalyticsEvent.GitHubSignInFailureReason {
        if isWebAuthenticationCancellation(error) { return .cancelled }
        switch error {
        case SignInCallbackError.stateMismatch:
            return .stateMismatch
        case SignInCallbackError.codeMissing:
            return .githubRefused
        case RevylShipTokAPIError.githubSignInRejected:
            return .revylRejected
        case is ShipTokSignInKeychainError:
            return .keychainFailed
        default:
            return .unavailable
        }
    }

    // Finishes the deletion a quit or a failure left unfinished: the GitHub token revocation it still owes, then this iPhone's part. Nil when none was left.
    private func finishUnfinishedDeletion() async throws -> UnfinishedDeletion? {
        guard var unfinishedDeletion = UnfinishedDeletion.loadSaved() else { return nil }
        if unfinishedDeletion.gitHubTokenRevocation == .owed {
            unfinishedDeletion.gitHubTokenRevocation = await revokeGitHubAccessToken(heldBy: nil)
            unfinishedDeletion.save()
        }
        try await finishDeletingOnThisIPhone(unfinishedDeletion)
        return unfinishedDeletion
    }

    // Revokes the GitHub token this iPhone holds as Delete my ShipTok data revokes it, through the feed's own token vault when there is one. A GitHub sign-in GitHub already refuses has nothing left to revoke.
    private func revokeGitHubAccessToken(heldBy feedAccessTokenVault: GitHubAccessTokenVault?) async -> UnfinishedDeletion.GitHubTokenRevocation {
        do {
            guard let accessTokenVault = try feedAccessTokenVault ?? ShipTokSignInKeychainStore.loadStoredGitHubSignIn().map({ GitHubAccessTokenVault(tokens: $0.tokens) }) else {
                return .notOwed
            }
            try await accessTokenVault.sendRevylRequest { [shipTokAPI] accessToken in
                try await shipTokAPI.deleteUserData(gitHubAccessToken: accessToken)
            }
            return .notOwed
        } catch where Self.isGitHubSignInRefusal(error) {
            return .notOwed
        } catch {
            Self.logger.error("Ending ShipTok's GitHub access after deleting the Revyl account failed: \(error.publicLogDescription, privacy: .public)")
            return .failed
        }
    }

    // The record of the unfinished deletion goes last, with the defaults, so a failure or a quit midway is finished on the next try or launch; callers report success only once this returns.
    private func finishDeletingOnThisIPhone(_ unfinishedDeletion: UnfinishedDeletion) async throws {
        do {
            if let storedGitHubSignIn = try ShipTokSignInKeychainStore.loadStoredGitHubSignIn() {
                try ShipTokSignInKeychainStore.deleteStoredGitHubSignIn()
                ShipTokAnalytics(githubUserID: storedGitHubSignIn.user.githubUserID).capture(.signInEnded(reason: unfinishedDeletion.signInEndReason))
            }
            try ShipTokSignInKeychainStore.deleteRevylAPIKey()
            URLCache.shared.removeAllCachedResponses()
            await PullRequestMediaDiskCache.finishPendingSaves()
            try Self.deleteCachedFiles()
        } catch {
            throw UnfinishedDeletionError(kind: unfinishedDeletion.kind, cleanupError: error)
        }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        Self.logger.info("Deleted what ShipTok kept on this iPhone")
    }

    // The deletion finishes only once the app's own caches are gone. Anything else under Caches is iOS's, which may refuse its removal, so it goes best effort.
    private static func deleteCachedFiles() throws {
        var appCacheDirectoryURLs = [PullRequestFeedCache.savedFeedsDirectoryURL, PullRequestFeedCache.replacedSavedFeedsDirectoryURL, PullRequestMediaDiskCache.rootDirectoryURL]
        // URLCache.shared, which avatars load through, keeps its disk store here.
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            appCacheDirectoryURLs.append(.cachesDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory))
        }
        for appCacheDirectoryURL in appCacheDirectoryURLs {
            do {
                try FileManager.default.removeItem(at: appCacheDirectoryURL)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                logger.error("Deleting ShipTok's \(appCacheDirectoryURL.lastPathComponent, privacy: .public) cache failed")
                throw error
            }
        }
        let otherCachedFileURLs: [URL]
        do {
            otherCachedFileURLs = try FileManager.default.contentsOfDirectory(at: .cachesDirectory, includingPropertiesForKeys: nil)
        } catch {
            logger.error("Listing the other cached files to delete failed")
            return
        }
        for cachedFileURL in otherCachedFileURLs {
            do {
                try FileManager.default.removeItem(at: cachedFileURL)
            } catch {
                logger.error("Deleting another cached file failed")
            }
        }
    }
}
