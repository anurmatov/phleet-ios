import UIKit
import UserNotifications

/// The real notification system: the permission prompt, Apple's device token, and taps.
///
/// One instance, because the operating system has one application and one notification centre,
/// and their callbacks arrive on objects the system creates rather than on anything the
/// composition root owns. The app delegate and the notification delegate forward here; whoever
/// set the handlers hears about it.
@MainActor
final class SystemPushSystem: PushSystem {

    static let shared = SystemPushSystem()

    var onDeviceToken: ((String) -> Void)?
    var onRegistrationFailed: (() -> Void)?
    var onOpened: ((PushDestination) -> Void)?

    private init() {}

    func requestPermission() async -> PushPermission {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        return granted ? .granted : .denied
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func unregisterForRemoteNotifications() {
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// A device token as the lowercase hex the orchestrator stores and Apple's API takes.
    static func hex(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}

/// Receives what the application object is told about remote notifications.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Held here because the notification centre keeps its delegate weakly.
    private let notificationDelegate = PushNotificationDelegate()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        SystemPushSystem.shared.onDeviceToken?(SystemPushSystem.hex(deviceToken))
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        SystemPushSystem.shared.onRegistrationFailed?()
    }
}

/// Shows a notification that arrives while the app is open, and reports a tap.
final class PushNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Shown even in the foreground: the person may be on the Chat tab when a gate opens.
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Only the kind crosses to the main actor: a plain string, read out of the payload here.
        let kind = PushDestination.kind(in: response.notification.request.content.userInfo)
        await MainActor.run {
            SystemPushSystem.shared.onOpened?(PushDestination.destination(forKind: kind))
        }
    }
}
