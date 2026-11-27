import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct RepoOrderTests {
    /// The repos as a list shows them, given `repos` newest activity first.
    private func shown(_ repos: [String], _ order: [String]) -> [String] {
        repos.map { repo in
            var p = pr(repo)
            p.repo = repo
            return PRItem(pr: p)
        }
        .groupedByRepo(order: order).map(\.repo)
    }

    /// Drags `repo` to `index` of the list showing `repos` (newest activity first).
    private func drag(_ repo: String, to index: Int, in repos: [String], _ order: [String]) -> [String] {
        RepoOrder.moving(repo, to: index, shown: shown(repos, order), in: order)
    }

    @Test func noOrderKeepsNewestActivityFirst() {
        #expect(shown(["c", "a", "b"], []) == ["c", "a", "b"])
    }

    @Test func placedReposFirstThenTheRestNewestFirst() {
        #expect(shown(["c", "a", "b", "d"], ["x", "b", "a"]) == ["b", "a", "c", "d"])
    }

    @Test func firstDragPlacesEveryShownRepo() {
        #expect(drag("c", to: 0, in: ["a", "b", "c"], []) == ["c", "a", "b"])
        #expect(drag("a", to: 1, in: ["a", "b", "c"], []) == ["b", "a", "c"])
    }

    @Test func unplacedReposGoBelowHiddenPlacedOnes() {
        // b is placed; a and c were shown below it, so they go after hidden h too.
        #expect(drag("c", to: 1, in: ["a", "b", "c"], ["b", "h"]) == ["b", "h", "c", "a"])
    }

    @Test func movedRepoOnlyPassesWhatItMust() {
        // Up between a and b: lands right above b, h stays above it.
        #expect(drag("c", to: 1, in: ["a", "b", "c"], ["a", "h", "b", "c"]) == ["a", "h", "c", "b"])
        // Down between a and b: lands right below a, h stays below it.
        #expect(drag("x", to: 1, in: ["x", "a", "b"], ["x", "a", "h", "b"]) == ["a", "x", "h", "b"])
        // Down past c: has to pass h2, which was above c; h1 stays above it.
        #expect(drag("b", to: 2, in: ["a", "b", "c"], ["a", "h1", "b", "h2", "c"]) == ["a", "h1", "h2", "c", "b"])
    }

    @Test func reposArrangedAtDifferentTimesMerge() {
        // Mon: docs to the top.
        let mon = drag("docs", to: 0, in: ["web", "api", "docs"], [])
        #expect(mon == ["docs", "web", "api"])
        // Tue: web is placed, infra and mobile are new so they show below it; mobile to the top.
        #expect(shown(["infra", "mobile", "web"], mon) == ["web", "infra", "mobile"])
        let tue = drag("mobile", to: 0, in: ["infra", "mobile", "web"], mon)
        #expect(tue == ["docs", "mobile", "web", "api", "infra"])
        // Wed: together for the first time, both days' arrangements hold.
        #expect(shown(["api", "infra", "web", "docs", "mobile"], tue) == ["docs", "mobile", "web", "api", "infra"])
        // Thu: api above mobile; it also passes web (mobile is above web), nothing else moves.
        #expect(shown(["api", "mobile"], tue) == ["mobile", "api"])
        let thu = drag("api", to: 0, in: ["api", "mobile"], tue)
        #expect(thu == ["docs", "api", "mobile", "web", "infra"])
    }

    @Test func moveThatChangesNothingSavesNothing() {
        #expect(drag("a", to: 0, in: ["a", "b"], []) == [])
        #expect(drag("b", to: 5, in: ["a", "b"], []) == [])
        #expect(RepoOrder.moving("x", to: 0, shown: ["a", "b"], in: ["a"]) == ["a"])
    }

    @Test func moveClampsAtEitherEnd() {
        #expect(drag("a", to: 5, in: ["a", "b", "c"], []) == ["b", "c", "a"])
        #expect(drag("c", to: -1, in: ["a", "b", "c"], []) == ["c", "a", "b"])
    }

    @Test func keyboardRowsFollowTheOrder() {
        func mine(_ id: String, _ repo: String, minutesAgo: Double) -> PullRequest {
            var p = pr(id, updated: now.addingTimeInterval(-minutesAgo * 60))
            p.repo = repo
            return p
        }
        let sections = MenuSections(
            buckets: [.mine: [mine("A", "o/a", minutesAgo: 1), mine("B", "o/b", minutesAgo: 2), mine("C", "o/a", minutesAgo: 3)]],
            staleDays: 30, hideBots: false, now: now
        )
        #expect(sections.rows(.mine, collapsed: [], snoozedOpen: false).map(\.id) == ["A", "C", "B"])
        #expect(sections.rows(.mine, collapsed: [], snoozedOpen: false, order: ["o/b"]).map(\.id) == ["B", "A", "C"])
    }
}
