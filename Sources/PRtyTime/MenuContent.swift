import AppKit
import PRtyTimeCore
import SwiftUI

struct MenuBarLabel: View {
    let store: PRStore
    @AppStorage(Prefs.staleDays) private var staleDays = 30
    @AppStorage(Prefs.ignoreBots) private var ignoreBots = true

    var body: some View {
        let count = MenuSections(buckets: store.buckets, staleDays: staleDays, hideBots: ignoreBots, snoozed: Set(store.snoozed.keys)).badgeCount
        HStack(spacing: 2) {
            if store.errorMessage == nil {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template)
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
            if count > 0 { Text("\(count)") }
        }
    }
}

/// The panel's view state. With only the Command Line Tools, `@State` doesn't
/// compile (it is a macro in the macOS 27 SDK and its plugin ships with Xcode),
/// so view-local state lives here. There is only one panel.
@MainActor @Observable
final class PanelState {
    static let shared = PanelState()
    private static let collapsedKey = "collapsedGroups"

    var tab = PanelTab.review
    var query = "" {
        // A row picked before is no longer what ↩ should open.
        didSet { if query != oldValue { highlightedID = nil } }
    }
    /// The row under the mouse or picked with ↑ and ↓: a PR id, or a repo group's key.
    var highlightedID: String?
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

    var isOpen: Bool { window?.isVisible == true }

    func opened() {
        highlightedID = nil
        mouseAtKey = nil
        openings += 1
    }

    func close() { closeRequests += 1 }

    func hover(_ id: String, inside: Bool) {
        if let point = mouseAtKey {
            guard NSEvent.mouseLocation != point else { return }
            mouseAtKey = nil
        }
        if inside {
            highlightedID = id
        } else if highlightedID == id {
            highlightedID = nil
        }
    }

    /// Highlights the PR picked with ↑ or ↓.
    func pick(_ id: String?) {
        highlightedID = id
        scrollTarget = id
        mouseAtKey = NSEvent.mouseLocation
    }
}

/// The panel shown when clicking the menu-bar icon.
struct MenuContent: View {
    let store: PRStore
    @AppStorage(Prefs.staleDays) private var staleDays = 30
    @AppStorage(Prefs.ignoreBots) private var ignoreBots = true
    @AppStorage(Prefs.showLineCounts) private var showLineCounts = true
    @AppStorage(Prefs.showChecks) private var showChecks = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @FocusState private var filterFocused: Bool
    private let panel = PanelState.shared

    var body: some View {
        let all = MenuSections(buckets: store.buckets, staleDays: staleDays, hideBots: ignoreBots, snoozed: Set(store.snoozed.keys))
        let shown = filtering ? all.filtered(panel.query) : all
        let rows = shown.rows(panel.tab, collapsed: filtering ? [] : panel.collapsed, snoozedOpen: filtering || panel.snoozedOpen.contains(panel.tab))
        let selected = selection(in: rows)
        // Everything in the tab, for the menu's Mark all as read.
        let tabPRs = shown.rows(panel.tab, collapsed: [], snoozedOpen: true).map(\.id)

        VStack(spacing: 0) {
            filterField(rows: rows, selected: selected)
                .padding([.horizontal, .top], 10)
            Picker("", selection: Binding(get: { panel.tab }, set: { panel.tab = $0 })) {
                Text("To review (\(shown.toReview.count))").tag(PanelTab.review)
                Text("My PRs (\(shown.mine.count))").tag(PanelTab.mine)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("⌘1 and ⌘2 switch tabs")
            .background {
                Group {
                    Button("To review") { panel.tab = .review }.keyboardShortcut("1")
                    Button("My PRs") { panel.tab = .mine }.keyboardShortcut("2")
                }
                .hidden()
            }
            .padding(10)

            if let error = store.errorMessage { banner(error) }
            if let warning = store.warning { banner(warning) }

            Divider()
            // Both tabs share the taller tab's unfiltered, fully expanded height
            // (capped; scrolls beyond), so switching tabs, collapsing groups or
            // filtering never resizes the panel. MenuBarExtra resizes around the
            // center, which would move it away from the menu bar.
            // While filtering, every group is expanded so no match is hidden.
            ScrollViewReader { proxy in
                ScrollView {
                    list(panel.tab, shown, expandAll: filtering)
                        .environment(\.selectedRow, selected?.id)
                        .environment(\.tabPRs, tabPRs)
                }
                .onChange(of: panel.scrollTarget) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(height: min(max(panel.listHeights.values.max() ?? 0, 1), 520))
            .background {
                VStack {
                    measured(.review, all)
                    measured(.mine, all)
                }
                .hidden()
            }
            Divider()
            if let update = store.update { updateRow(update) }
            footer
        }
        .frame(width: 460)
        .pinTopOnResize()
        .background(PanelWindowReader())
        // Also when opened with a click, so ↑ and ↓ work right away. A query
        // kept from last time is selected, so typing replaces it.
        .onChange(of: panel.openings) {
            filterFocused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        .onChange(of: panel.closeRequests) { dismiss() }
    }

    private var filtering: Bool { !panel.query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The PR ↩ opens: the highlighted one, or while filtering the first match.
    private func selection(in rows: [PullRequest]) -> PullRequest? {
        rows.first { $0.id == panel.highlightedID } ?? (filtering ? rows.first : nil)
    }

    private func filterField(rows: [PullRequest], selected: PullRequest?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by #, title, repo, author, reviewer", text: Binding(get: { panel.query }, set: { panel.query = $0 }))
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onKeyPress(.escape) {
                    // Esc clears the filter; with nothing to clear, let it close the panel.
                    guard !panel.query.isEmpty else { return .ignored }
                    panel.query = ""
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    panel.pick(rows.id(movingFrom: selected?.id, by: 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    panel.pick(rows.id(movingFrom: selected?.id, by: -1))
                    return .handled
                }
                .onSubmit {
                    if let selected { open(selected) }
                }
            if !panel.query.isEmpty {
                Button { panel.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func list(_ tab: PanelTab, _ sections: MenuSections, expandAll: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            switch tab {
            case .review: reviewTab(sections, expandAll: expandAll)
            case .mine: mineTab(sections, expandAll: expandAll)
            }
        }
        .padding(6)
    }

    /// The tab's list, fully expanded, at its natural height, reporting that height.
    private func measured(_ tab: PanelTab, _ sections: MenuSections) -> some View {
        list(tab, sections, expandAll: true)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panel.listHeights[tab] = $0 }
            .frame(height: 0, alignment: .top)
    }

    @ViewBuilder private func reviewTab(_ sections: MenuSections, expandAll: Bool) -> some View {
        if sections.toReview.isEmpty && sections.reviewed.isEmpty {
            empty(filtering ? "No matching PRs" : "Nothing to review")
        }
        groups(sections.toReview, section: .review, expandAll: expandAll)
        if !sections.reviewed.isEmpty {
            header("Reviewed by you")
            groups(sections.reviewed.map { PRItem(pr: $0) }, section: .reviewed, expandAll: expandAll)
        }
        snoozedSection(sections.snoozedReview, tab: .review, expandAll: expandAll)
    }

    @ViewBuilder private func mineTab(_ sections: MenuSections, expandAll: Bool) -> some View {
        if sections.mine.isEmpty { empty(filtering ? "No matching PRs" : "No open PRs") }
        groups(sections.mine.map { PRItem(pr: $0) }, section: .mine, mine: true, expandAll: expandAll)
        snoozedSection(sections.snoozedMine.map { PRItem(pr: $0) }, tab: .mine, mine: true, expandAll: expandAll)
    }

    /// Closed until clicked; open while filtering so no match is hidden.
    @ViewBuilder private func snoozedSection(_ items: [PRItem], tab: PanelTab, mine: Bool = false, expandAll: Bool) -> some View {
        if !items.isEmpty {
            let open = expandAll || panel.snoozedOpen.contains(tab)
            Button {
                withAnimation(.snappy(duration: 0.15)) {
                    if open { panel.snoozedOpen.remove(tab) } else { panel.snoozedOpen.insert(tab) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text("Snoozed")
                    Text(verbatim: "\(items.count)").fontWeight(.regular)
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!expandAll)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .help("Snoozed PRs come back when there's new activity on them, or when their time runs out")
            if open {
                // Dimmed, to tell them from the groups above.
                groups(items, section: .snoozed(tab), mine: mine, expandAll: expandAll)
                    .opacity(0.6)
            }
        }
    }

    /// Collapsible per-repo groups. `section` keeps collapse state separate per list.
    private func groups(_ items: [PRItem], section: ListSection, mine: Bool = false, expandAll: Bool) -> some View {
        ForEach(items.groupedByRepo()) { group in
            let key = group.key(in: section)
            let collapsed = !expandAll && panel.collapsed.contains(key)
            GroupHeader(group: group, key: key, collapsed: collapsed, collapsible: !expandAll, hasUnread: group.items.contains { isUnread($0.pr) })
            if !collapsed {
                ForEach(group.items) { item in
                    PRRow(pr: item.pr, unread: isUnread(item.pr), forYou: item.forYou, showAuthor: !mine, labeledStatus: mine,
                          diff: showLineCounts ? store.diffStats[item.pr.id] : nil,
                          merge: showChecks ? store.mergeStatus[item.pr.id] : nil,
                          snoozedUntil: store.snoozed[item.pr.id]) {
                        open(item.pr)
                    }
                    .padding(.leading, 16)
                    .id(item.pr.id)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("Refresh now (⌘R)")
                .disabled(store.isRefreshing)
            Button {
                dismiss()
                NSApp.activate()
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .help("Settings (⌘,)")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit PRty Time (⌘Q)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String {
        guard let lastRefresh = store.lastRefresh else { return "Loading…" }
        let time = lastRefresh.formatted(date: .omitted, time: .shortened)
        return "Updated at \(time)" + (store.isRefreshing ? " · refreshing…" : "")
    }

    private func isUnread(_ pr: PullRequest) -> Bool { store.unread.contains(pr.id) }

    private func open(_ pr: PullRequest) {
        store.open(pr)
        dismiss()
    }

    private func updateRow(_ release: Release) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
            Text("PRty Time \(release.version) is available")
            Spacer()
            UpdateButton(release: release) { dismiss() }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func banner(_ text: String) -> some View {
        Text("⚠️ \(text)")
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func empty(_ text: String) -> some View {
        Text(store.lastRefresh == nil ? "Loading…" : text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// A PR row's right-click menu.
private struct RowMenu: View {
    let pr: PullRequest
    @Environment(\.tabPRs) private var tabPRs
    private let store = PRStore.shared

    var body: some View {
        Button("Open checks") { NSWorkspace.shared.open(pr.checksURL) }
        Divider()
        if store.unread.contains(pr.id) {
            Button("Mark as read") { store.markRead(pr.id) }
        } else {
            Button("Mark as unread") { store.markUnread(pr.id) }
        }
        let unreadInTab = tabPRs.filter(store.unread.contains)
        Button("Mark all in this tab as read") { store.markRead(unreadInTab) }
            .disabled(unreadInTab.isEmpty)
        Divider()
        if store.snoozed[pr.id] != nil {
            Button("Unsnooze") { store.unsnooze(pr.id) }
        } else {
            Button("Snooze until new activity") { store.snooze(pr, until: Snooze.untilActivity) }
            Button("Snooze until tomorrow morning") { store.snooze(pr, until: Snooze.tomorrowMorning(after: Date())) }
            Button("Snooze until next week") { store.snooze(pr, until: Snooze.nextWeek(after: Date())) }
        }
        Divider()
        Button("Copy link") { NSPasteboard.general.copy(pr.url.absoluteString) }
        // Nil until the PR's details are fetched, right after it first shows up.
        let branch = store.branches[pr.id]
        Button("Copy branch name") { if let branch { NSPasteboard.general.copy(branch) } }
            .disabled(branch == nil)
        Button("Copy “\(pr.checkoutCommand)”") { NSPasteboard.general.copy(pr.checkoutCommand) }
    }
}

private struct GroupHeader: View {
    let group: RepoGroup
    let key: String
    let collapsed: Bool
    /// Off while filtering, when every group is shown expanded.
    let collapsible: Bool
    let hasUnread: Bool
    private let panel = PanelState.shared

    private var hovering: Bool { panel.highlightedID == key }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) {
                if collapsed { panel.collapsed.remove(key) } else { panel.collapsed.insert(key) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Text(group.repoName)
                    .font(.callout.weight(.semibold))
                Text("\(group.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // What the collapsed rows would have shown.
                if collapsed && hasUnread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                if collapsed && group.hasForYou { YouBadge() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(collapsible)
        .padding(.top, 4)
        .onHover { panel.hover(key, inside: $0) }
        .help(group.repo)
    }
}

private struct YouBadge: View {
    var body: some View {
        Text("You")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
    }
}

private struct PRRow: View {
    let pr: PullRequest
    let unread: Bool
    var forYou = false
    var showAuthor = true
    /// Spell out the review decision instead of showing just an icon.
    var labeledStatus = false
    var diff: DiffStat?
    /// Only fetched for your PRs.
    var merge: MergeStatus?
    var snoozedUntil: Date?
    let action: () -> Void
    @Environment(\.selectedRow) private var selectedRow
    private let panel = PanelState.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(unread ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                if showAuthor {
                    Avatar(url: pr.author?.avatarURL)
                        .padding(.trailing, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // Checks next to the title as on GitHub, apart from the review decision.
                    HStack(spacing: 5) {
                        Text(pr.title)
                            .fontWeight(forYou ? .semibold : .regular)
                            .foregroundStyle(pr.isDraft ? .secondary : .primary)
                            .lineLimit(1)
                        checks
                    }
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if forYou { YouBadge() }
                if pr.isDraft { tag("Draft") }
                if merge?.conflicting == true { tag("Conflicts", Color.linesRemoved) }
                decision
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // On the button itself: outside PRRow, VoiceOver's Show Menu opened
        // the menu of the repo group's first row.
        .contextMenu { RowMenu(pr: pr) }
        .onHover { panel.hover(pr.id, inside: $0) }
        .help(pr.title)
    }

    /// "#12 · +40 −3 · author · @teams · 2h". The diff comes early so a long team list can't truncate it.
    private var subtitle: Text {
        // verbatim: an interpolated Int in a localized Text gets a thousands separator ("#1.570").
        var text = Text(verbatim: "#\(pr.number)")
        if let labels = diff?.labels {
            text = text + Text(" · ") + Text(labels.added).foregroundStyle(Color.linesAdded) + Text(" ") + Text(labels.removed).foregroundStyle(Color.linesRemoved)
        }
        var rest: [String] = []
        if showAuthor, let author = pr.author { rest.append(author.login) }
        if !forYou, !pr.requestedTeams.isEmpty { rest.append("@" + pr.requestedTeams.joined(separator: ", @")) }
        rest.append(pr.age())
        if let until = snoozedUntil, until != Snooze.untilActivity {
            rest.append("until " + until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
        return text + Text(" · " + rest.joined(separator: " · "))
    }

    private var background: Color {
        if selectedRow == pr.id { return .primary.opacity(0.1) }
        return forYou ? .accentColor.opacity(0.12) : .clear
    }

    private func tag(_ text: String, _ style: some ShapeStyle = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(style)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(style.opacity(0.5)))
    }

    /// GitHub's symbols: a check, a cross, or a dot while running.
    @ViewBuilder private var checks: some View {
        switch merge?.checks {
        case .passing: Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.linesAdded).help("Checks passed")
        case .failing: Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.linesRemoved).help("Checks failed")
        case .pending: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.checksPending).help("Checks running")
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var decision: some View {
        switch pr.reviewDecision {
        case .approved: status("Approved", "checkmark.circle.fill", .green)
        case .changesRequested: status("Changes requested", "xmark.circle.fill", .red)
        case .reviewRequired where labeledStatus: status("Awaiting review", "clock", .secondary)
        default: EmptyView()
        }
    }

    @ViewBuilder private func status(_ text: String, _ icon: String, _ color: some ShapeStyle) -> some View {
        if labeledStatus {
            Label(text, systemImage: icon).font(.caption).foregroundStyle(color)
        } else {
            Image(systemName: icon).foregroundStyle(color).help(text)
        }
    }
}

private extension Color {
    // GitHub's diff colors. The system green and red are too light to read on white.
    static let linesAdded = adaptive(light: (0x1A, 0x7F, 0x37), dark: (0x3F, 0xB9, 0x50))
    static let linesRemoved = adaptive(light: (0xCF, 0x22, 0x2E), dark: (0xF8, 0x51, 0x49))
    static let checksPending = adaptive(light: (0x9A, 0x67, 0x00), dark: (0xD2, 0x99, 0x22))

    static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        })
    }
}

extension EnvironmentValues {
    /// The id of the PR row that ↩ opens, highlighted.
    var selectedRow: String? {
        get { self[SelectedRowKey.self] }
        set { self[SelectedRowKey.self] = newValue }
    }
}

private struct SelectedRowKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The ids of every PR in the panel's tab, collapsed or snoozed ones included.
    var tabPRs: [String] {
        get { self[TabPRsKey.self] }
        set { self[TabPRsKey.self] = newValue }
    }
}

private struct TabPRsKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension NSPasteboard {
    func copy(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}

/// Gives `PanelState` the panel's window, and tells it when the panel opens.
private struct PanelWindowReader: NSViewRepresentable {
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

extension View {
    /// Keep the top edge in place if the panel resizes while open (e.g. a poll
    /// adds PRs). Without it MenuBarExtra resizes around the center.
    @ViewBuilder func pinTopOnResize() -> some View {
        if #available(macOS 26, *) {
            windowResizeAnchor(.top)
        } else {
            self
        }
    }
}
