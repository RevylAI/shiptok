import SwiftUI

@main
struct ShipTokApp: App {
    @UIApplicationDelegateAdaptor(ShipTokAppDelegate.self) private var appDelegate
    @State private var signInSession = ShipTokSignInSession()

    init() {
        PostMediaDiskCache.removeLongUnusedFilesInBackground()
    }

    var body: some Scene {
        WindowGroup {
            RootView(signInSession: signInSession)
                .preferredColorScheme(.dark)
                .tint(RevylBrandColor.brand)
        }
    }
}
