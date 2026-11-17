import SwiftUI

@main
struct ShipTokApp: App {
    @State private var signInSession = GitHubSignInSession()

    var body: some Scene {
        WindowGroup {
            RootView(signInSession: signInSession)
                .preferredColorScheme(.dark)
                .tint(RevylBrandColor.brand)
        }
    }
}
