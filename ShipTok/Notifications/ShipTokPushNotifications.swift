import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

// A tapped notification's post, and its comment when it's about one, waiting for the feed to open it.
struct OpenedPushNotification: Equatable, Sendable {
    let id = UUID()
    let postID: String
    let commentID: String?
    // The inbox item it's about, as "<kind>:<id>".
    let inboxItemID: String?

    var inboxItemKind: String? {
        inboxItemID?.split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    // A comment, reply or vibe shows in the post's comments sheet; a like or reaction is on the card itself.
    var opensComments: Bool {
        inboxItemKind != nil && inboxItemKind != "reaction"
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let shipTokPayload = userInfo["shiptok"] as? [String: Any], let postID = shipTokPayload["post_id"] as? String else { return nil }
        self.postID = postID
        commentID = shipTokPayload["comment_id"] as? String
        inboxItemID = shipTokPayload["inbox_item_id"] as? String
    }
}

// Revyl pushes each new piece of feedback on a person's posts, and each reply to their comments, to every iPhone they're signed in on; a tap opens the post (AGENTS.md, "Push Notifications").
@Observable
@MainActor
final class ShipTokPushNotifications {
    static let shared = ShipTokPushNotifications()

    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "push-notifications")
    // Debug builds get their tokens from APNs' sandbox, and TestFlight and App Store builds from production.
    #if DEBUG
    private static let apnsEnvironment = "development"
    #else
    private static let apnsEnvironment = "production"
    #endif

    private(set) var openedNotification: OpenedPushNotification?
    @ObservationIgnored private var api: RevylShipTokAPI?
    @ObservationIgnored private var analytics: ShipTokAnalytics?

    // The first sign-in asks for permission; every launch after it registers again, so Revyl always holds the token APNs gave this iPhone last.
    func startRegistering(api: RevylShipTokAPI, analytics: ShipTokAnalytics) {
        self.api = api
        self.analytics = analytics
        Task { await askForPermissionAndRegister() }
    }

    // Revyl deletes the devices a ShipTok key registered when it signs out, so nothing more is sent for this sign-in.
    func stopRegistering() {
        api = nil
        analytics = nil
    }

    func registerDevice(apnsDeviceToken: Data) {
        guard let api else { return }
        let apnsDeviceTokenHex = apnsDeviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                try await api.registerPushNotificationDevice(apnsDeviceTokenHex: apnsDeviceTokenHex, apnsEnvironment: Self.apnsEnvironment)
                Self.logger.info("Registered this iPhone for \(Self.apnsEnvironment, privacy: .public) notifications")
            } catch {
                Self.logger.error("Registering this iPhone for notifications failed: \(error.publicLogDescription, privacy: .public)")
            }
        }
    }

    func recordRegistrationFailure(_ error: any Error) {
        Self.logger.error("APNs gave this iPhone no device token: \(error.publicLogDescription, privacy: .public)")
    }

    func open(_ openedNotification: OpenedPushNotification) {
        self.openedNotification = openedNotification
    }

    // The feed takes the notification once it's on screen, which a tap that launched the app reaches only after the sign-in is restored.
    func takeOpenedNotification() -> OpenedPushNotification? {
        guard let openedNotification else { return nil }
        self.openedNotification = nil
        analytics?.capture(.pushNotificationOpened(inboxItemID: openedNotification.inboxItemID, inboxItemKind: openedNotification.inboxItemKind))
        return openedNotification
    }

    private func askForPermissionAndRegister() async {
        let notificationCenter = UNUserNotificationCenter.current()
        switch await notificationCenter.notificationSettings().authorizationStatus {
        case .notDetermined:
            do {
                let isGranted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                analytics?.capture(.pushNotificationPermissionAnswered(granted: isGranted))
                guard isGranted else { return }
            } catch {
                Self.logger.error("Asking for notification permission failed: \(error.publicLogDescription, privacy: .public)")
                return
            }
        case .denied:
            return
        default:
            break
        }
        guard api != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }
}

final class ShipTokAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ShipTokPushNotifications.shared.registerDevice(apnsDeviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        ShipTokPushNotifications.shared.recordRegistrationFailure(error)
    }

    // A notification that arrives while ShipTok is open shows as a banner too, since the feed doesn't show the inbox.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // iOS calls this off the main thread, so it reads what it needs before handing the tap to the feed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let openedNotification = OpenedPushNotification(userInfo: response.notification.request.content.userInfo) else { return }
        await ShipTokPushNotifications.shared.open(openedNotification)
    }
}
