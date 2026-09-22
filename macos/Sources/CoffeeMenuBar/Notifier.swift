import Foundation
import UserNotifications

/// Delivers the app's announcements (order ready, placed, failed…) through
/// Notification Center rather than modal dialogs, so nothing steals focus and
/// the message stays on screen until dismissed.
///
/// Whether they persist is the user's Notification Center style for the app:
/// the Info.plist asks for Alerts via NSUserNotificationAlertStyle, but
/// macOS 26 ignores that for this (ad-hoc signed) app and defaults to
/// auto-dismissing banners, so the startup log nudges towards System Settings.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter aborts the process when the executable isn't
    /// inside an app bundle (plain `swift run`), so fall back to the log there.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()

    override init() {
        super.init()
        guard let center else {
            log("not running from an app bundle — notifications will be logged instead")
            return
        }
        // Present notifications even while the app is frontmost (e.g. with the
        // order window open); without a delegate the system suppresses them.
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                log("notification permission error: \(error.localizedDescription)")
            }
            center.getNotificationSettings { settings in
                log("notifications: \(Self.describe(settings))")
            }
        }
    }

    /// "authorized, alerts" / "denied — …" / "not determined", for the startup
    /// log, so a missing notification can be traced to permissions vs delivery.
    static func describe(_ settings: UNNotificationSettings) -> String {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            let style: String
            switch settings.alertStyle {
            case .alert: style = "alerts"
            case .banner: style = "banners — for persistent notifications choose Alerts for Coffee in System Settings > Notifications"
            case .none: style = "alerts off"
            default: style = "unknown style"
            }
            return "authorized, \(style)"
        case .denied:
            return "denied — allow Coffee in System Settings > Notifications"
        case .notDetermined:
            return "not determined"
        default:
            return "unknown status"
        }
    }

    func notify(title: String, body: String) {
        guard let center else {
            log("\(title): \(body)")
            return
        }
        center.add(Self.request(title: title, body: body)) { error in
            if let error {
                log("notification failed: \(error.localizedDescription)")
            }
        }
    }

    static func content(title: String, body: String, sound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        return content
    }

    /// A unique identifier per event: reusing one would replace the previous
    /// notification in Notification Center instead of adding to it. The sound
    /// follows the Play Sounds setting at the moment of posting.
    static func request(title: String, body: String) -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content(title: title, body: body, sound: Settings.playSounds),
            trigger: nil
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
