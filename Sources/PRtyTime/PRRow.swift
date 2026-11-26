import AppKit
import PRtyTimeCore
import SwiftUI

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

struct GroupHeader: View {
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

struct PRRow: View {
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
    /// Snoozed: secondary text instead of a lower opacity, which would fall below readable contrast.
    var dimmed = false
    let action: () -> Void
    @Environment(\.selectedRow) private var selectedRow
    @Environment(\.focusedRow) private var focusedRow
    private let panel = PanelState.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(unread ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                if showAuthor {
                    Avatar(url: pr.author?.avatarURL)
                        .opacity(dimmed ? 0.6 : 1)
                        .padding(.trailing, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // Checks next to the title as on GitHub, apart from the review decision.
                    HStack(spacing: 5) {
                        Text(pr.title)
                            .fontWeight(forYou ? .semibold : .regular)
                            .foregroundStyle(pr.isDraft || dimmed ? .secondary : .primary)
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
                if merge?.conflicting == true { tag("Conflicts", Color.danger) }
                decision
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            // The row ↩ opens, picked from the keyboard: a focus ring, which
            // the faint hover fill alone isn't.
            .overlay {
                if focusedRow == pr.id {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
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
            text = text + Text(" · ") + Text(labels.added).foregroundStyle(Color.success) + Text(" ") + Text(labels.removed).foregroundStyle(Color.danger)
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

    /// Under the mouse or picked: grey, or a stronger tint on your rows so they keep their color.
    private var background: Color {
        let selected = selectedRow == pr.id
        if forYou { return .accentColor.opacity(selected ? 0.2 : 0.12) }
        return selected ? .primary.opacity(0.1) : .clear
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
        case .passing: Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.success).help("Checks passed")
        case .failing: Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.danger).help("Checks failed")
        case .pending: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.attention).help("Checks running")
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var decision: some View {
        switch pr.reviewDecision {
        case .approved: status("Approved", "checkmark.circle.fill", Color.success)
        case .changesRequested: status("Changes requested", "xmark.circle.fill", Color.danger)
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

extension Color {
    // GitHub's colors, used for every status: the system green and red are too
    // light to read on white (2:1 and 3.6:1; text needs 4.5:1). Two are a shade
    // stronger than GitHub's (#1A7F37, #F85149), which are tuned for white and
    // black and fell short on the panel's grey (#EFEFEF, #323232).
    static let success = adaptive(light: (0x18, 0x75, 0x32), dark: (0x3F, 0xB9, 0x50))
    static let danger = adaptive(light: (0xCF, 0x22, 0x2E), dark: (0xFF, 0x7B, 0x72))
    static let attention = adaptive(light: (0x9A, 0x67, 0x00), dark: (0xD2, 0x99, 0x22))

    static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        })
    }
}

extension NSPasteboard {
    func copy(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}
