import AppKit
import Observation
import PRtyTimeCore
import SwiftUI

/// The panel's view state. With only the Command Line Tools, `@State` doesn't
/// compile (it is a macro in the macOS 27 SDK and its plugin ships with Xcode),
/// so view-local state lives here. There is only one panel.
@MainActor @Observable
final class PanelState {
    static let shared = PanelState()
    private static let collapsedKey = "collapsedGroups"
    private static let repoOrderKey = "repoOrder"

    var tab = PanelTab.review
    var query = "" {
        // A row picked before is no longer what ↩ should open.
        didSet { if query != oldValue { highlightedID = nil } }
    }
    /// The row under the mouse or picked with ↑ and ↓: a PR id, or a repo group's key.
    var highlightedID: String?
    /// `highlightedID` was picked with ↑ or ↓, not hovered.
    private(set) var pickedWithKeyboard = false
    /// The PR last picked with ↑ or ↓, for the list to scroll to.
    var scrollTarget: String?
    /// Counts the panel opening, for the view to focus the filter.
    private(set) var openings = 0
    /// Counts requests to close the panel, which only the view can do (`dismiss`).
    private(set) var closeRequests = 0
    @ObservationIgnored weak var window: NSWindow?
    /// Where the mouse was at the last ↑ or ↓. Hover changes while it's still
    /// there come from the list scrolling under it, not from the user.
    @ObservationIgnored private var mouseAtKey: NSPoint?
    var listHeights: [PanelTab: CGFloat] = [:]
    /// Tabs whose Snoozed section is open; closed at launch.
    var snoozedOpen: Set<PanelTab> = []
    /// Collapsed repo groups as "<section>/<owner>/<repo>", kept across launches.
    var collapsed = Set(UserDefaults.standard.stringArray(forKey: PanelState.collapsedKey) ?? []) {
        didSet { UserDefaults.standard.set(collapsed.sorted(), forKey: Self.collapsedKey) }
    }
    /// Repos as "owner/name" in the order dragged into (see `RepoOrder`), kept across launches.
    var repoOrder = UserDefaults.standard.stringArray(forKey: PanelState.repoOrderKey) ?? [] {
        didSet { UserDefaults.standard.set(repoOrder, forKey: Self.repoOrderKey) }
    }
    /// The key of the repo group being dragged.
    var draggedGroup: String?
    /// The key of the repo group the dragged one is over, where it would land.
    var dropTarget: String?

    var isOpen: Bool { window?.isVisible == true }

    func opened() {
        highlightedID = nil
        mouseAtKey = nil
        draggedGroup = nil
        dropTarget = nil
        openings += 1
    }

    /// Moves `repo` to `index` of a list showing `shown`.
    func moveRepo(_ repo: String, to index: Int, shown: [String]) {
        withAnimation(.snappy(duration: 0.15)) {
            repoOrder = RepoOrder.moving(repo, to: index, shown: shown, in: repoOrder)
        }
    }

    func close() { closeRequests += 1 }

    func hover(_ id: String, inside: Bool) {
        if let point = mouseAtKey {
            guard NSEvent.mouseLocation != point else { return }
            mouseAtKey = nil
        }
        if inside {
            highlightedID = id
            pickedWithKeyboard = false
        } else if highlightedID == id {
            highlightedID = nil
        }
    }

    /// Highlights the PR picked with ↑ or ↓.
    func pick(_ id: String?) {
        highlightedID = id
        pickedWithKeyboard = true
        scrollTarget = id
        mouseAtKey = NSEvent.mouseLocation
    }
}

/// Gives `PanelState` the panel's window, and tells it when the panel opens.
struct PanelWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            PanelState.shared.window = window
            NotificationCenter.default.addObserver(self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: window)
            if window.isKeyWindow { becameKey() }
        }

        @objc private func becameKey() { PanelState.shared.opened() }
    }
}
