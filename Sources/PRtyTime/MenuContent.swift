import AppKit
import PRtyTimeCore
import SwiftUI

struct MenuBarLabel: View {
    let store: PRStore
    @AppStorage(Prefs.staleDays) private var staleDays = Prefs.Default.staleDays
    @AppStorage(Prefs.ignoreBots) private var ignoreBots = Prefs.Default.ignoreBots

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

/// The panel shown when clicking the menu-bar icon.
struct MenuContent: View {
    let store: PRStore
    @AppStorage(Prefs.staleDays) private var staleDays = Prefs.Default.staleDays
    @AppStorage(Prefs.ignoreBots) private var ignoreBots = Prefs.Default.ignoreBots
    @AppStorage(Prefs.showLineCounts) private var showLineCounts = Prefs.Default.showLineCounts
    @AppStorage(Prefs.showChecks) private var showChecks = Prefs.Default.showChecks
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @FocusState private var filterFocused: Bool
    private let panel = PanelState.shared

    var body: some View {
        let all = MenuSections(buckets: store.buckets, staleDays: staleDays, hideBots: ignoreBots, snoozed: Set(store.snoozed.keys))
        let shown = filtering ? all.filtered(panel.query) : all
        let rows = shown.rows(panel.tab, collapsed: filtering ? [] : panel.collapsed, snoozedOpen: filtering || panel.snoozedOpen.contains(panel.tab))
        let selected = selection(in: rows)
        // Ringed when picked with ↑ or ↓, or as the first match while filtering
        // (not the hovered row): the one ↩ opens without the mouse.
        let ringed = selected.flatMap { $0.id != panel.highlightedID || panel.pickedWithKeyboard ? $0.id : nil }
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
                        .environment(\.focusedRow, ringed)
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
                groups(items, section: .snoozed(tab), mine: mine, dimmed: true, expandAll: expandAll)
            }
        }
    }

    /// Collapsible per-repo groups. `section` keeps collapse state separate per list.
    private func groups(_ items: [PRItem], section: ListSection, mine: Bool = false, dimmed: Bool = false, expandAll: Bool) -> some View {
        ForEach(items.groupedByRepo()) { group in
            let key = group.key(in: section)
            let collapsed = !expandAll && panel.collapsed.contains(key)
            GroupHeader(group: group, key: key, collapsed: collapsed, collapsible: !expandAll, hasUnread: group.items.contains { isUnread($0.pr) })
            if !collapsed {
                ForEach(group.items) { item in
                    PRRow(pr: item.pr, unread: isUnread(item.pr), forYou: item.forYou, showAuthor: !mine, labeledStatus: mine,
                          diff: showLineCounts ? store.diffStats[item.pr.id] : nil,
                          merge: showChecks ? store.mergeStatus[item.pr.id] : nil,
                          snoozedUntil: store.snoozed[item.pr.id], dimmed: dimmed) {
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
    /// The id of the selected row when it was picked from the keyboard, which gets a focus ring.
    var focusedRow: String? {
        get { self[FocusedRowKey.self] }
        set { self[FocusedRowKey.self] = newValue }
    }
}

private struct FocusedRowKey: EnvironmentKey {
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
