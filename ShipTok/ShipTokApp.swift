import SwiftUI

@main
struct ShipTokApp: App {
    @State private var signInSession = GitHubSignInSession()

    init() {
        PullRequestMediaDiskCache.removeLongUnusedFilesInBackground()
        PullRequestFeedCache.removeReplacedSavedFeedsInBackground()
    }

    var body: some Scene {
        WindowGroup {
            RootView(signInSession: signInSession)
                .preferredColorScheme(.dark)
                .tint(RevylBrandColor.brand)
        }
    }
}
