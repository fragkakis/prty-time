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
    /// The Logger subsystem, the same as the bundle id. Don't rename (see CLAUDE.md).
    static let subsystem = "com.fragkakis.prty"
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

    /// Each pref's default, registered at launch. `@AppStorage` declarations start from these too.
    enum Default {
        static let pollMinutes = 2.0
        static let staleDays = 30
        static let ignoreBots = true
        static let showLineCounts = true
        static let showChecks = false
        static let checkUpdates = true
        /// For every `NotificationCategory`.
        static let notify = true
        static let notificationGrouping = NotificationGrouping.together
    }

    /// The saved settings `ActivityDiff` runs with.
    static var diffSettings: DiffSettings {
        let defaults = UserDefaults.standard
        return DiffSettings(
            ignoreBots: defaults.bool(forKey: ignoreBots),
            staleDays: defaults.integer(forKey: staleDays),
            notifySelf: notifySelf,
            enabled: Set(NotificationCategory.allCases.filter { defaults.bool(forKey: notifyKey($0)) })
        )
    }

    static func registerDefaults() {
        var defaults: [String: Any] = [
            pollMinutes: Default.pollMinutes, staleDays: Default.staleDays, ignoreBots: Default.ignoreBots,
            showLineCounts: Default.showLineCounts, showChecks: Default.showChecks, checkUpdates: Default.checkUpdates,
            notificationGrouping: Default.notificationGrouping.rawValue,
        ]
        for category in NotificationCategory.allCases { defaults[notifyKey(category)] = Default.notify }
        UserDefaults.standard.register(defaults: defaults)
    }
}
