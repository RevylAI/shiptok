import AuthenticationServices
import Observation
import OSLog
import SwiftUI
import UserNotifications

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

// Revyl deleted the account, and only this iPhone's part is left to try again. It's recorded in the defaults as soon as Revyl confirms, so a quit or a failure leaves it for the next launch or sign-in to finish, and this iPhone's part removes the record last, with the rest of the defaults (AGENTS.md, "Ownership And Boundaries").
struct UnfinishedRevylAccountDeletionError: LocalizedError {
    let cleanupError: any Error

    var errorDescription: String? {
        "Revyl deleted your Revyl account. \(cleanupError.localizedDescription) Try again or open ShipTok again to finish on this iPhone."
    }
}

// One showing of the first screen. Nobody is signed in there, so it has an analytics identity of its own, and it opens on Join existing organization when Revyl said the account is in no organization.
struct FirstScreenVisit {
    let visitID: UUID
    var message: String?
    let opensJoinOrganization: Bool
    let analytics: ShipTokAnalytics
}

// The person signs in to Revyl, and that sign-in alone opens their organization's feed: Revyl's backend reads GitHub for them through its GitHub App, so nobody connects a GitHub account (AGENTS.md, "Revyl Sign-In").
@Observable
@MainActor
final class ShipTokSignInSession {
    enum Phase {
        case restoring
        case signedOut(FirstScreenVisit)
        case signedIn(SignedInTeammate)
    }

    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "sign-in")
    private static let signedOutReasonDefaultsKey = "signed-out-reason"
    private static let unfinishedRevylAccountDeletionDefaultsKey = "unfinished-revyl-account-deletion"
    private static let signInCallbackURLScheme = "shiptok"
    private static let revylAccountDeletedMessage = "Your Revyl account is deleted, with the comments, replies, reactions and vibes you gave in ShipTok."
    private static let gitHubSignInRetiredMessage = "ShipTok now signs in with your Revyl account and shows your organization's repositories. Sign in to Revyl to keep watching."
    // Builds before the Revyl sign-in kept these on the iPhone, keyed by GitHub account, and nothing reads them any more (AGENTS.md, "Feed Caching").
    private static let retiredCacheDirectoryNames = ["pull-request-feeds", "merged-pull-request-feeds", "pull-request-media"]
    private static let retiredDefaultsKeyPrefixes = [
        "unfinished-data-deletion-github-user-id",
        "unfinished-deletion",
        "developer-inbox-last-seen-occurred-at-github-",
        "hidden-people-github-logins-github-",
        "feed-repository-full-name-github-",
    ]

    private(set) var phase: Phase = .restoring
    private(set) var isSigningInToRevyl = false
    private(set) var isSigningOut = false
    private(set) var isDeletingRevylAccount = false
    // The Keychain's sign-in, nil while the first screen shows. Work started for one sign-in checks its key is still the one held before it changes anything, so it never touches a later sign-in.
    private var storedRevylSignIn: StoredRevylSignIn?
    private var isVerifyingRevylSignIn = false

    // A saved sign-in opens the feed at once on the account it saved, and Revyl's answer to GET /revyl-account then confirms or ends it.
    func restoreSavedSession() async {
        Self.deleteRetiredStorage()
        do {
            if try await finishUnfinishedRevylAccountDeletion() {
                showFirstScreen(reason: .revylAccountDeleted, message: Self.revylAccountDeletedMessage)
                return
            }
        } catch {
            showFirstScreen(reason: .failure, message: error.localizedDescription)
            return
        }
        let savedRevylSignIn: StoredRevylSignIn?
        let hadRetiredGitHubSignIn: Bool
        do {
            hadRetiredGitHubSignIn = try ShipTokSignInKeychainStore.deleteRetiredGitHubSignIn()
            savedRevylSignIn = try ShipTokSignInKeychainStore.loadStoredRevylSignIn()
        } catch {
            showFirstScreen(reason: .failure, message: error.localizedDescription)
            return
        }
        // A relaunch with the same arguments finds the same key saved and keeps what the session chose since.
        if let passedRevylAPIKey = LaunchArgumentSignIn.passedRevylAPIKey, passedRevylAPIKey != savedRevylSignIn?.revylAPIKey {
            do {
                let launchRevylSignIn = try await LaunchArgumentSignIn.save(revylAPIKey: passedRevylAPIKey)
                UserDefaults.standard.removeObject(forKey: Self.signedOutReasonDefaultsKey)
                activate(launchRevylSignIn)
            } catch {
                showFirstScreen(reason: .failure, message: error.localizedDescription)
            }
            return
        }
        let signedOutReason = UserDefaults.standard.string(forKey: Self.signedOutReasonDefaultsKey)
        guard let savedRevylSignIn else {
            if hadRetiredGitHubSignIn {
                showFirstScreen(reason: .githubSignInRetired, message: Self.gitHubSignInRetiredMessage)
            } else {
                showFirstScreen(reason: .noSignIn, message: signedOutReason)
            }
            return
        }
        activate(savedRevylSignIn)
    }

    func signInToRevyl(using webAuthenticationSession: WebAuthenticationSession) async {
        guard case .signedOut(var firstScreenVisit) = phase, !isSigningInToRevyl else { return }
        isSigningInToRevyl = true
        defer { isSigningInToRevyl = false }
        let signInAttemptID = UUID()
        firstScreenVisit.analytics.capture(.revylSignInStarted(attemptID: signInAttemptID))
        let newRevylSignIn: StoredRevylSignIn
        do {
            // An unfinished deletion would take a new sign-in with it on the next launch, so it finishes before Revyl's sign-in opens.
            if try await finishUnfinishedRevylAccountDeletion() {
                firstScreenVisit.message = Self.revylAccountDeletedMessage
                phase = .signedOut(firstScreenVisit)
            }
            let signInAPI = RevylShipTokAPI(revylAPIKey: nil)
            let proofKey = ProofKeyForCodeExchange.generate()
            let signInState = randomURLSafeString(byteCount: 32)
            let authorizationURL = try await signInAPI.revylSignInAuthorizationURL(state: signInState, codeChallenge: proofKey.codeChallenge)
            let callbackURL = try await Self.authenticate(using: webAuthenticationSession, at: authorizationURL)
            let authorizationCode = try Self.authorizationCode(in: callbackURL, matchingState: signInState)
            let newRevylAPIKey = try await signInAPI.exchangeRevylSignInCode(
                authorizationCode,
                codeVerifier: proofKey.codeVerifier,
                deviceLabel: "ShipTok on \(UIDevice.current.model)"
            )
            let revylAccount = try await RevylShipTokAPI(revylAPIKey: newRevylAPIKey).fetchRevylAccount()
            newRevylSignIn = StoredRevylSignIn(revylAPIKey: newRevylAPIKey, revylAccount: revylAccount)
            try ShipTokSignInKeychainStore.saveStoredRevylSignIn(newRevylSignIn)
        } catch {
            let failureReason = Self.revylSignInFailureReason(for: error)
            firstScreenVisit.analytics.capture(.revylSignInFailed(attemptID: signInAttemptID, reason: failureReason))
            // An account in no organization gets the join choices on Revyl's page and closes it, which iOS reports as a cancel, so the first screen stays as it was.
            if failureReason == .cancelled { return }
            if case RevylShipTokAPIError.revylOrganizationRequired = error {
                showFirstScreen(reason: .revylOrganizationRequired, message: error.localizedDescription, opensJoinOrganization: true)
                return
            }
            firstScreenVisit.message = error.localizedDescription
            phase = .signedOut(firstScreenVisit)
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.signedOutReasonDefaultsKey)
        Self.logger.info("Signed in to Revyl")
        activate(newRevylSignIn).analytics.capture(.revylSignInCompleted(attemptID: signInAttemptID))
    }

    // Revyl may end the sign-in, or the account may leave its organization or move to another, while ShipTok sleeps, so each launch and return to the foreground asks Revyl who is signed in. A refusal ends the sign-in through the API's own handler (AGENTS.md, "Revyl Sign-In").
    func verifyRevylSignIn() async {
        guard case .signedIn(let teammate) = phase, !isVerifyingRevylSignIn, !isSigningOut, !isDeletingRevylAccount else { return }
        isVerifyingRevylSignIn = true
        defer { isVerifyingRevylSignIn = false }
        let revylAccount: RevylAccount
        do {
            revylAccount = try await teammate.api.fetchRevylAccount()
        } catch {
            Self.logger.notice("Checking the Revyl sign-in failed: \(error.publicLogDescription, privacy: .public)")
            return
        }
        guard case .signedIn(let currentTeammate) = phase, currentTeammate.signInID == teammate.signInID,
              let storedRevylSignIn, revylAccount != storedRevylSignIn.revylAccount, !isSigningOut, !isDeletingRevylAccount
        else { return }
        let updatedRevylSignIn = StoredRevylSignIn(revylAPIKey: storedRevylSignIn.revylAPIKey, revylAccount: revylAccount)
        try? ShipTokSignInKeychainStore.saveStoredRevylSignIn(updatedRevylSignIn)
        // Another person or organization behind the same key sees a feed of its own, so the sign-in starts over; a new name or picture only updates what's shown.
        if revylAccount.revylUserID != storedRevylSignIn.revylAccount.revylUserID || revylAccount.organization.orgID != storedRevylSignIn.revylAccount.organization.orgID {
            end(currentTeammate, reason: .revylAccountChanged, message: nil)
            activate(updatedRevylSignIn)
            return
        }
        self.storedRevylSignIn = updatedRevylSignIn
        var updatedTeammate = currentTeammate
        updatedTeammate.account = revylAccount
        phase = .signedIn(updatedTeammate)
    }

    // Revyl deletes the account with its keys and everything ShipTok holds for it, then the iPhone forgets everything ShipTok kept. Revyl's part can't run twice, since it revokes the key, so what's left is recorded as soon as Revyl confirms (AGENTS.md, "Revyl Sign-In").
    func deleteRevylAccount() async throws {
        guard case .signedIn(let teammate) = phase, !teammate.feedWork.hasStopped, !isDeletingRevylAccount, !isSigningOut else { return }
        teammate.analytics.capture(.revylAccountDeletionRequested)
        isDeletingRevylAccount = true
        defer { isDeletingRevylAccount = false }
        do {
            try await teammate.api.deleteRevylAccount()
        } catch {
            let failureReason: ShipTokAnalyticsEvent.RevylAccountDeletionFailureReason = switch error {
            case RevylShipTokAPIError.revylAccountOwnsOrganization: .ownsOrganization
            default: .unavailable
            }
            teammate.analytics.capture(.revylAccountDeletionFailed(reason: failureReason))
            throw error
        }
        UserDefaults.standard.set(true, forKey: Self.unfinishedRevylAccountDeletionDefaultsKey)
        storedRevylSignIn = nil
        Self.logger.info("Deleted the Revyl account")
        teammate.analytics.capture(.signInEnded(reason: .revylAccountDeleted))
        ShipTokPushNotifications.shared.stopRegistering()
        teammate.mediaCache.stopDownloadsAndRemoveAllMedia()
        // A feed read that finishes after the files go would save its feeds again, so the feed's work stops and drains first.
        await teammate.feedWork.stopAndWaitForRunningWork()
        do {
            try await finishDeletingOnThisIPhone()
            showFirstScreen(reason: .revylAccountDeleted, message: Self.revylAccountDeletedMessage)
        } catch {
            showFirstScreen(reason: .failure, message: error.localizedDescription)
        }
    }

    // A sign-in the Keychain still holds would come back on the next launch, so nothing ends until the Keychain lets it go. Revyl revokes the key and the push notification devices it registered; the feed's reads and saves stop and drain before it ends, so nothing is saved for it afterwards.
    func signOut() async throws {
        guard case .signedIn(let teammate) = phase, !teammate.feedWork.hasStopped, !isDeletingRevylAccount, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await teammate.api.revokeRevylAPIKey()
        } catch {
            Self.logger.notice("Revyl didn't revoke the Revyl key, so this iPhone only forgets it: \(error.publicLogDescription, privacy: .public)")
        }
        try ShipTokSignInKeychainStore.deleteStoredRevylSignIn()
        guard case .signedIn(let currentTeammate) = phase, currentTeammate.signInID == teammate.signInID else { return }
        storedRevylSignIn = nil
        ShipTokPushNotifications.shared.stopRegistering()
        await teammate.feedWork.stopAndWaitForRunningWork()
        end(teammate, reason: .signedOut, message: nil)
        UserDefaults.standard.removeObject(forKey: Self.signedOutReasonDefaultsKey)
        showFirstScreen(reason: .signedOut, message: nil)
    }

    // Revyl refusing the key on any route ends the sign-in it ran for: a key it no longer takes leads to the first screen, and an account in no organization to Join existing organization (AGENTS.md, "Revyl Sign-In").
    private func endRevylSignIn(refusedWith error: RevylShipTokAPIError, signInID: UUID) {
        guard case .signedIn(let teammate) = phase, teammate.signInID == signInID, !isDeletingRevylAccount, !isSigningOut else { return }
        let isOrganizationRequired = if case .revylOrganizationRequired = error { true } else { false }
        if isOrganizationRequired {
            // The key of an account in no organization may still be live, so Revyl is asked to revoke it as on sign-out; the iPhone forgets it either way.
            Task { [api = teammate.api] in try? await api.revokeRevylAPIKey() }
        }
        // A key the Keychain fails to forget is refused again on the next launch, which ends it then; the store logs the failure.
        try? ShipTokSignInKeychainStore.deleteStoredRevylSignIn()
        storedRevylSignIn = nil
        ShipTokPushNotifications.shared.stopRegistering()
        end(teammate, reason: isOrganizationRequired ? .revylOrganizationRequired : .revylSignInRequired, message: error.localizedDescription)
        showFirstScreen(
            reason: isOrganizationRequired ? .revylOrganizationRequired : .revylSignInRequired,
            message: error.localizedDescription,
            opensJoinOrganization: isOrganizationRequired
        )
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

    // The reason outlives the process, so a sign-in that ended while the app was in the background still says why on the next launch.
    private func end(_ teammate: SignedInTeammate, reason: ShipTokAnalyticsEvent.SignInEndReason, message: String?) {
        teammate.analytics.capture(.signInEnded(reason: reason))
        UserDefaults.standard.set(message, forKey: Self.signedOutReasonDefaultsKey)
        teammate.mediaCache.stopDownloadsAndRemoveAllMedia()
        teammate.feedWork.stop()
    }

    @discardableResult
    private func activate(_ revylSignIn: StoredRevylSignIn) -> SignedInTeammate {
        let signInID = UUID()
        let revylUserID = revylSignIn.revylAccount.revylUserID
        let api = RevylShipTokAPI(revylAPIKey: revylSignIn.revylAPIKey) { [weak self] refusal in
            self?.endRevylSignIn(refusedWith: refusal, signInID: signInID)
        }
        let teammate = SignedInTeammate(
            signInID: signInID,
            account: revylSignIn.revylAccount,
            api: api,
            analytics: ShipTokAnalytics(revylUserID: revylUserID),
            hiddenPeopleStore: HiddenPeopleStore(revylUserID: revylUserID),
            mediaCache: FeedViewerMediaCache(savedMedia: .forRevylUser(id: revylUserID)),
            feedWork: FeedViewerWork()
        )
        storedRevylSignIn = revylSignIn
        phase = .signedIn(teammate)
        ShipTokPushNotifications.shared.startRegistering(api: api, analytics: teammate.analytics)
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

    private static func revylSignInFailureReason(for error: any Error) -> ShipTokAnalyticsEvent.RevylSignInFailureReason {
        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return .cancelled }
        switch error {
        case SignInCallbackError.stateMismatch:
            return .stateMismatch
        case SignInCallbackError.codeMissing:
            return .codeMissing
        case RevylShipTokAPIError.revylSignInExpired:
            return .signInExpired
        case RevylShipTokAPIError.revylOrganizationRequired:
            return .organizationRequired
        case let unfinishedDeletionError as UnfinishedRevylAccountDeletionError:
            return revylSignInFailureReason(for: unfinishedDeletionError.cleanupError)
        case is ShipTokSignInKeychainError:
            return .keychainFailed
        default:
            return .unavailable
        }
    }

    // True when a deletion a quit or a failure left unfinished was finished now.
    private func finishUnfinishedRevylAccountDeletion() async throws -> Bool {
        guard UserDefaults.standard.bool(forKey: Self.unfinishedRevylAccountDeletionDefaultsKey) else { return false }
        try await finishDeletingOnThisIPhone()
        return true
    }

    // The record of the unfinished deletion goes last, with the defaults, so a failure or a quit midway is finished on the next try or launch; callers report success only once this returns.
    private func finishDeletingOnThisIPhone() async throws {
        do {
            try ShipTokSignInKeychainStore.deleteStoredRevylSignIn()
            URLCache.shared.removeAllCachedResponses()
            await PostMediaDiskCache.finishPendingSaves()
            try Self.deleteCachedFiles()
        } catch {
            throw UnfinishedRevylAccountDeletionError(cleanupError: error)
        }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        Self.logger.info("Deleted what ShipTok kept on this iPhone")
    }

    // The deletion finishes only once the app's own caches are gone. Anything else under Caches is iOS's, which may refuse its removal, so it goes best effort.
    private static func deleteCachedFiles() throws {
        var appCacheDirectoryURLs = [SavedPostFeeds.directoryURL, PostMediaDiskCache.rootDirectoryURL]
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

    private static func deleteRetiredStorage() {
        for retiredCacheDirectoryName in retiredCacheDirectoryNames {
            try? FileManager.default.removeItem(at: .cachesDirectory.appending(path: retiredCacheDirectoryName, directoryHint: .isDirectory))
        }
        for defaultsKey in UserDefaults.standard.dictionaryRepresentation().keys
        where retiredDefaultsKeyPrefixes.contains(where: { defaultsKey.hasPrefix($0) }) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
