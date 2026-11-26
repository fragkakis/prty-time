import Foundation

extension PullRequest {
    /// What VoiceOver reads after a panel row's title: what the row shows with
    /// dots, icons, colour and abbreviations, spelled out. `diff` and `merge`
    /// are nil when the panel doesn't show them.
    public func spokenDetails(
        unread: Bool, forYou: Bool, showAuthor: Bool, awaitingReview: Bool,
        diff: DiffStat?, merge: MergeStatus?, snoozedUntil: Date?,
        now: Date = Date(), locale: Locale = .current
    ) -> String {
        var parts: [String] = []
        if unread { parts.append("unread") }
        if forYou { parts.append("review requested from you") }
        if isDraft { parts.append("draft") }
        switch merge?.checks {
        case .passing: parts.append("checks passed")
        case .failing: parts.append("checks failed")
        case .pending: parts.append("checks running")
        case nil: break
        }
        if merge?.conflicting == true { parts.append("merge conflicts") }
        switch reviewDecision {
        case .approved: parts.append("approved")
        case .changesRequested: parts.append("changes requested")
        case .reviewRequired where awaitingReview: parts.append("awaiting review")
        default: break
        }
        if showAuthor, let author {
            parts.append("number \(number) by \(author.login)")
        } else {
            parts.append("number \(number)")
        }
        if !forYou, !requestedTeams.isEmpty { parts.append("requested from " + requestedTeams.joined(separator: ", ")) }
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .full
        parts.append("updated " + relative.localizedString(for: updatedAt, relativeTo: now))
        if let diff, diff.additions + diff.deletions > 0 {
            parts.append("\(diff.additions) lines added, \(diff.deletions) removed")
        }
        if let snoozedUntil {
            parts.append(snoozedUntil == Snooze.untilActivity
                ? "snoozed until new activity"
                : "snoozed until " + snoozedUntil.formatted(.dateTime.weekday(.wide).hour().minute().locale(locale)))
        }
        return parts.joined(separator: ", ")
    }
}
