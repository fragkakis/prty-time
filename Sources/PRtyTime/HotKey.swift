import AppKit
import Carbon.HIToolbox
import Observation
import os

/// A key combination, in Carbon's terms for `RegisterEventHotKey`.
struct Shortcut: Equatable {
    var keyCode: UInt32
    /// Carbon flags: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    var modifiers: UInt32
    /// The key's name for display ("P"). Key codes are positions on the
    /// keyboard, so the character is taken from the layout when recorded.
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), key: "P")

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// The shortcut typed in `event`; nil without ⌘, ⌥ or ⌃, as a global
    /// shortcut of a plain or shifted key would swallow typing.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        guard modifiers & (cmdKey | optionKey | controlKey) != 0,
              let key = Self.names[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased(),
              !key.isEmpty
        else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), key: key)
    }

    /// "⌃⌥P", the modifiers in the order menus show them.
    var label: String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    /// Keys that type no character, or an invisible one.
    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    var plist: [String: Any] { ["keyCode": Int(keyCode), "modifiers": Int(modifiers), "key": key] }

    init?(plist: [String: Any]) {
        guard let code = plist["keyCode"] as? Int, let modifiers = plist["modifiers"] as? Int, let key = plist["key"] as? String else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(modifiers), key: key)
    }
}

/// The global shortcut that opens the panel. Carbon's `RegisterEventHotKey`,
/// unlike an `NSEvent` global monitor, needs no Accessibility permission.
@MainActor @Observable
final class HotKey {
    static let shared = HotKey()

    /// nil when turned off in Settings.
    private(set) var shortcut: Shortcut?
    /// Why the shortcut couldn't be registered. Another app using it isn't
    /// one: macOS registers it for both.
    private(set) var error: String?
    /// Set when the shortcut last failed to open the panel (see `MenuBarPanel`).
    var openFailed = false
    /// Settings is recording a new shortcut from the next key typed. The
    /// current one is let go meanwhile, so it can be typed too.
    var recording = false {
        didSet {
            guard recording != oldValue else { return }
            register()
            if recording { startRecording() } else { stopRecording() }
        }
    }

    @ObservationIgnored private var ref: EventHotKeyRef?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.subsystem, category: "hotkey")

    func start() {
        // Never set: the default. Turned off: an empty dictionary.
        if let saved = UserDefaults.standard.dictionary(forKey: Prefs.hotKey) {
            shortcut = Shortcut(plist: saved)
        } else {
            shortcut = .default
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon calls back on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { MenuBarPanel.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        register()
    }

    func set(_ shortcut: Shortcut?) {
        self.shortcut = shortcut
        UserDefaults.standard.set(shortcut?.plist ?? [:], forKey: Prefs.hotKey)
        register()
    }

    private func register() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        error = nil
        guard let shortcut, !recording else { return }
        let id = EventHotKeyID(signature: OSType(0x5052_5459), id: 1) // "PRTY"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status != noErr else { return }
        ref = nil
        error = "Couldn't use \(shortcut.label) (error \(status))"
        log.error("registering \(shortcut.label, privacy: .public) failed: \(status)")
    }

    private func startRecording() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { HotKey.shared.record(event) }
            return nil
        }
        // Leaving Settings cancels, so the shortcut isn't left off.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HotKey.shared.recording = false }
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
    }

    private func record(_ event: NSEvent) {
        if let shortcut = Shortcut(event) {
            set(shortcut)
            recording = false
        } else if Int(event.keyCode) == kVK_Escape {
            recording = false
        } else {
            NSSound.beep()
        }
    }
}

/// Opens and closes the MenuBarExtra panel, which SwiftUI has no API for. The
/// way in is private AppKit; if the shortcut stops opening the panel after a
/// macOS update, look here.
@MainActor
enum MenuBarPanel {
    private static let log = Logger(subsystem: AppInfo.subsystem, category: "hotkey")

    static func toggle() {
        let panel = PanelState.shared
        if panel.isOpen {
            panel.close()
        } else {
            open()
        }
    }

    private static func open() {
        guard let button = statusButton else {
            failed("status-bar button not found")
            return
        }
        // On macOS 27 SwiftUI's status item (NSSceneStatusItem) gives its button
        // no action: a click asks the system to show the panel, an "expanded
        // interface session". Earlier, the button's action shows it.
        let request = NSSelectorFromString("_requestExpandedInterfaceSession")
        if button.action == nil, let item = statusItem(of: button), item.responds(to: request) {
            item.perform(request)
        } else {
            button.performClick(nil)
        }
        // Neither way reports failing, so check that the panel opened. Counting
        // openings, not `isOpen`, as a second press may close it again.
        let openings = PanelState.shared.openings
        Task {
            try? await Task.sleep(for: .seconds(1))
            if PanelState.shared.openings == openings && !PanelState.shared.isOpen {
                failed("panel didn't open (button action: \(button.action.map(NSStringFromSelector) ?? "none"))")
            } else {
                HotKey.shared.openFailed = false
            }
        }
    }

    private static func failed(_ reason: String) {
        log.error("opening the panel failed: \(reason, privacy: .public)")
        HotKey.shared.openFailed = true
        NSSound.beep()
    }

    /// The status item's button. Besides the window holding it, the status bar
    /// has a window per other display and Space showing a copy (a replicant).
    private static var statusButton: NSStatusBarButton? {
        func find(in view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.lazy
            .filter { $0.className == "NSStatusBarWindow" }
            .compactMap { $0.contentView.flatMap(find) }
            .first
    }

    private static func statusItem(of button: NSStatusBarButton) -> NSStatusItem? {
        guard let window = button.window, window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }
}
