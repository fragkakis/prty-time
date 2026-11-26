import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct NavigationTests {
    func inRepo(_ pr: PullRequest, _ repo: String) -> PullRequest {
        var pr = pr
        pr.repo = repo
        return pr
    }

    /// To review: A (o/api), B (o/web), C (o/api). Reviewed: R. Snoozed: S. Mine: M1, M2 (snoozed).
    var sections: MenuSections {
        let buckets: [Bucket: [PullRequest]] = [
            .direct: [inRepo(pr("A", updated: now), "o/api"), inRepo(pr("S", updated: now.addingTimeInterval(-5)), "o/api")],
            .team: [inRepo(pr("B", updated: now.addingTimeInterval(-10), details: false), "o/web"),
                    inRepo(pr("C", updated: now.addingTimeInterval(-20), details: false), "o/api")],
            .reviewed: [pr("R", updated: now.addingTimeInterval(-30))],
            .mine: [pr("M1", author: me, updated: now), pr("M2", author: me, updated: now.addingTimeInterval(-10))],
        ]
        return MenuSections(buckets: buckets, staleDays: 30, hideBots: true, snoozed: ["S", "M2"], now: now)
    }

    @Test func rowsFollowTheRepoGroupsAndSections() {
        // A repo is listed where its first PR is, so C follows A, before B.
        #expect(sections.rows(.review, collapsed: [], snoozedOpen: false).map(\.id) == ["A", "C", "B", "R"])
        #expect(sections.rows(.review, collapsed: [], snoozedOpen: true).map(\.id) == ["A", "C", "B", "R", "S"])
        #expect(sections.rows(.mine, collapsed: [], snoozedOpen: true).map(\.id) == ["M1", "M2"])
    }

    @Test func rowsSkipCollapsedGroupsOfThatSectionOnly() {
        let collapsed: Set = ["review/o/api", "snoozed-mine/o/repo"]
        #expect(sections.rows(.review, collapsed: collapsed, snoozedOpen: true).map(\.id) == ["B", "R", "S"])
        #expect(sections.rows(.mine, collapsed: collapsed, snoozedOpen: true).map(\.id) == ["M1"])
    }

    /// Users' collapsed groups are saved under these names.
    @Test func sectionNamesStayAsSaved() {
        #expect(ListSection.allCases.map(\.rawValue) == ["review", "reviewed", "mine", "snoozed-review", "snoozed-mine"])
        #expect(ListSection.snoozed(.review) == .snoozedReview)
        #expect(ListSection.snoozed(.mine) == .snoozedMine)
    }

    @Test func movingStopsAtTheEnds() {
        let rows = sections.rows(.review, collapsed: [], snoozedOpen: false)
        #expect(rows.id(movingFrom: "A", by: 1) == "C")
        #expect(rows.id(movingFrom: "C", by: -1) == "A")
        #expect(rows.id(movingFrom: "A", by: -1) == "A")
        #expect(rows.id(movingFrom: "R", by: 1) == "R")
    }

    @Test func movingWithoutARowStartsAtAnEnd() {
        let rows = sections.rows(.review, collapsed: [], snoozedOpen: false)
        #expect(rows.id(movingFrom: nil, by: 1) == "A")
        #expect(rows.id(movingFrom: nil, by: -1) == "R")
        #expect(rows.id(movingFrom: "gone", by: 1) == "A")
        #expect([PullRequest]().id(movingFrom: nil, by: 1) == nil)
    }
}
