import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct DetailsCacheTests {
    let later = now.addingTimeInterval(60)

    func details(_ branch: String) -> PRDetails {
        PRDetails(diff: DiffStat(additions: 1, deletions: 2), branch: branch)
    }

    @Test func fetchesNewPRsAndOnlyThoseUpdatedSince() {
        var cache = DetailsCache()
        let first = cache.outdated(keeping: [pr("A"), pr("B")])
        #expect(first == ["A": now, "B": now])
        cache.store(["A": details("a"), "B": details("b")], requested: first)
        #expect(cache.outdated(keeping: [pr("A"), pr("B")]).isEmpty)
        #expect(cache.outdated(keeping: [pr("A", updated: later), pr("B")]) == ["A": later])
    }

    @Test func forgetsPRsNoLongerShown() {
        var cache = DetailsCache()
        cache.store(["A": details("a"), "B": details("b")], requested: cache.outdated(keeping: [pr("A"), pr("B")]))
        #expect(cache.outdated(keeping: [pr("B")]).isEmpty)
        #expect(cache.branches == ["B": "b"])
        #expect(Set(cache.diffStats.keys) == ["B"])
        // Shown again, it's fetched again.
        #expect(cache.outdated(keeping: [pr("A"), pr("B")]) == ["A": now])
    }

    @Test func aFailedFetchIsRetriedAndAMissingOneIsNot() {
        var cache = DetailsCache()
        let request = cache.outdated(keeping: [pr("A"), pr("B")])
        // Nothing stored: the fetch failed.
        #expect(cache.outdated(keeping: [pr("A"), pr("B")]) == request)
        // GitHub returned nothing for B (e.g. deleted): not asked for again until it changes.
        cache.store(["A": details("a")], requested: request)
        #expect(cache.outdated(keeping: [pr("A"), pr("B")]).isEmpty)
        #expect(cache.branches == ["A": "a"])
    }
}
