import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct SpokenTests {
    let english = Locale(identifier: "en_US")

    @Test func spellsOutWhatTheRowShowsWithIconsAndColour() {
        var p = pr("A", number: 482, updated: now.addingTimeInterval(-12 * 60))
        p.reviewDecision = .approved
        let spoken = p.spokenDetails(
            unread: true, forYou: true, showAuthor: true, awaitingReview: false,
            diff: DiffStat(additions: 148, deletions: 12), merge: MergeStatus(checks: .passing, conflicting: true, headOid: "c1"),
            snoozedUntil: nil, now: now, locale: english
        )
        #expect(spoken == "unread, review requested from you, checks passed, merge conflicts, approved, "
            + "number 482 by alice, updated 12 minutes ago, 148 lines added, 12 removed")
    }

    @Test func leavesOutWhatTheRowLeavesOut() {
        var p = pr("A", number: 7, updated: now.addingTimeInterval(-3 * 86_400), teams: ["backend"])
        p.isDraft = true
        p.reviewDecision = .reviewRequired
        let review = p.spokenDetails(unread: false, forYou: false, showAuthor: false, awaitingReview: false,
                                     diff: nil, merge: nil, snoozedUntil: Snooze.untilActivity, now: now, locale: english)
        #expect(review == "draft, number 7, requested from backend, updated 3 days ago, snoozed until new activity")
        let mine = p.spokenDetails(unread: false, forYou: false, showAuthor: false, awaitingReview: true,
                                   diff: DiffStat(additions: 0, deletions: 0), merge: nil, snoozedUntil: nil, now: now, locale: english)
        #expect(mine == "draft, awaiting review, number 7, requested from backend, updated 3 days ago")
    }
}
