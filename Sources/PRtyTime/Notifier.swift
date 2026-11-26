import AppKit
import PRtyTimeCore
import UserNotifications

/// How Notification Center stacks PRty Time's notifications (when its macOS grouping
/// setting is Automatic). Notifications without a thread id share the app's stack.
enum NotificationGrouping: String, CaseIterable {
    /// One stack for the app, cleared in one go.
    case together
    /// A stack per PR.
    case byPR

    static var current: Self {
        UserDefaults.standard.string(forKey: Prefs.notificationGrouping).flatMap(Self.init) ?? Prefs.Default.notificationGrouping
    }

    var label: String {
        switch self {
        case .together: "All together"
        case .byPR: "By PR"
        }
    }

    func thread(_ id: String) -> String {
        self == .byPR ? id : ""
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the PR id when a notification is clicked.
    var onOpen: ((String) -> Void)?

    /// UNUserNotificationCenter crashes outside an .app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func activate() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notification: PRNotification) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = NotificationGrouping.current.thread(notification.prID)
        content.userInfo = ["url": notification.url.absoluteString, "prID": notification.prID]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Clicking it opens the release page.
    func postUpdate(_ release: Release) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "PRty Time \(release.version) is available"
        content.body = UpdateHelp.shared.viaHomebrew ? "Update with: \(UpdateHelp.brewCommand)" : "Click to download it."
        content.sound = .default
        content.threadIdentifier = NotificationGrouping.current.thread("update")
        content.userInfo = ["url": release.url.absoluteString]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let prID = info["prID"] as? String
        await MainActor.run {
            if let url { NSWorkspace.shared.open(url) }
            if let prID { onOpen?(prID) }
        }
    }
}
