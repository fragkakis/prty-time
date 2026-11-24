import AppKit
import PRtyTimeCore
import SwiftUI

@main
struct PRtyTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = PRStore.shared

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PRStore.shared.start()
        HotKey.shared.start()
    }
}

enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "PRty Time"
    /// "dev" when run outside the app bundle (`swift run`).
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let repo = URL(string: "https://github.com/fragkakis/prty-time")!
}

enum Prefs {
    static let pollMinutes = "pollMinutes"
    static let staleDays = "staleDays"
    static let ignoreBots = "ignoreBots"
    static let showLineCounts = "showLineCounts"
    /// Fetch and show checks and merge conflicts of your PRs.
    static let showChecks = "showChecks"
    /// Look for a newer release once a day.
    static let checkUpdates = "checkUpdates"
    /// The panel's global shortcut (see `Shortcut.plist`); an empty dictionary turns it off.
    static let hotKey = "hotKey"
    /// A `NotificationGrouping` raw value.
    static let notificationGrouping = "notificationGrouping"

    static func notifyKey(_ category: NotificationCategory) -> String { "notify.\(category.rawValue)" }

    /// Debug: treat your own comments/reviews/pushes as activity. Set with
    /// `defaults write com.fragkakis.prty notifySelf -bool YES` or `PRTY_NOTIFY_SELF=1`.
    static var notifySelf: Bool {
        ProcessInfo.processInfo.environment["PRTY_NOTIFY_SELF"] == "1" || UserDefaults.standard.bool(forKey: "notifySelf")
    }

    static func registerDefaults() {
        var defaults: [String: Any] = [pollMinutes: 2.0, staleDays: 30, ignoreBots: true, showLineCounts: true, showChecks: false, checkUpdates: true,
                                     notificationGrouping: NotificationGrouping.together.rawValue]
        for category in NotificationCategory.allCases { defaults[notifyKey(category)] = true }
        UserDefaults.standard.register(defaults: defaults)
    }
}
