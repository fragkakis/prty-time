import Foundation
import Testing
@testable import PRtyTimeCore

/// Answers with the results set on it and records the requests. Tests use it
/// from one task at a time, hence unchecked.
final class FakeGitHub: GitHubAPI, @unchecked Sendable {
    var search: Result<PollData, GitHubError>
    var closed: Result<[ClosedPR], GitHubError> = .success([])
    var checks: Result<[String: MergeStatus], GitHubError> = .success([:])
    var notifications: Result<[String: InboxThread], GitHubError> = .success([:])
    var details: Result<[String: PRDetails], GitHubError> = .success([:])
    private(set) var requests: [String] = []

    init(_ buckets: [Bucket: [PullRequest]]) {
        search = .success(PollData(viewer: me, buckets: buckets))
    }

    func poll() async throws -> PollResult {
        requests.append("poll")
        return PollResult(data: try search.get(), rateLimit: nil, requests: 1, cost: 1, usedFallback: false, warnings: [])
    }

    func closedPRs(_ ids: [String]) async throws -> [ClosedPR] {
        requests.append("closed \(ids.sorted())")
        return try closed.get()
    }

    func mergeStatus(_ ids: [String]) async throws -> [String: MergeStatus] {
        requests.append("checks \(ids.sorted())")
        return try checks.get()
    }

    func details(_ ids: [String]) async throws -> [String: PRDetails] {
        requests.append("details \(ids.sorted())")
        return try details.get()
    }

    func inbox(since: Date, maxPages: Int) async throws -> [String: InboxThread] {
        requests.append("inbox")
        return try notifications.get()
    }
}

@Suite struct PollerTests {
    let settings = PollSettings(intervalMinutes: 2, fetchChecks: false, diff: DiffSettings(now: now))

    func update(_ outcome: Poller.Outcome) throws -> PollUpdate {
        guard case .updated(let update) = outcome else { throw GitHubError.incomplete("not updated: \(outcome)") }
        return update
    }

    @Test func failuresBackOffAndASuccessResetsThem() async throws {
        let github = FakeGitHub([:])
        github.search = .failure(.timeout)
        let poller = Poller(github: github)
        for (failures, delay) in [(1, 30.0), (2, 60.0)] {
            guard case .failed(let message, failures, delay) = await poller.run(previous: nil, settings: settings, now: now) else {
                Issue.record("expected failure \(failures)")
                return
            }
            #expect(message == "GitHub timed out")
        }
        github.search = .success(poll([:]))
        #expect(try update(await poller.run(previous: nil, settings: settings, now: now)).delay == 120)
        github.search = .failure(.timeout)
        guard case .failed(_, 1, 30) = await poller.run(previous: nil, settings: settings, now: now) else {
            Issue.record("a success didn't reset the failures")
            return
        }
    }

    @Test func aFailedLookupAfterTheSearchDoesntFailThePoll() async throws {
        let github = FakeGitHub([.direct: [pr("A")]])
        let poller = Poller(github: github)
        let first = try update(await poller.run(previous: nil, settings: settings, now: now))
        // A left every list, so the poll asks whether it was merged.
        github.search = .success(poll([:]))
        github.closed = .failure(.timeout)
        let second = try update(await poller.run(previous: first.snapshot, settings: settings, now: now))
        #expect(github.requests == ["poll", "poll", "closed [\"A\"]"])
        #expect(second.errors == ["checking 1 closed PRs failed: GitHub timed out"])
        #expect(second.buckets.isEmpty)
    }

    @Test func checksAreFetchedForYourPRsOnlyWhenTurnedOn() async throws {
        let github = FakeGitHub([.mine: [pr("M", author: me)], .direct: [pr("A")]])
        let poller = Poller(github: github)
        #expect(try update(await poller.run(previous: nil, settings: settings, now: now)).mergeStatus == [:])
        #expect(github.requests == ["poll"])

        var on = settings
        on.fetchChecks = true
        github.checks = .success(["M": MergeStatus(checks: .passing, headOid: "c1")])
        #expect(try update(await poller.run(previous: nil, settings: on, now: now)).mergeStatus?["M"]?.checks == .passing)
        #expect(github.requests.last == "checks [\"M\"]")
        // Failing, nil: the panel keeps showing the last ones.
        github.checks = .failure(.timeout)
        #expect(try update(await poller.run(previous: nil, settings: on, now: now)).mergeStatus == nil)
    }

    @Test func dotsReadOnGitHubClear() async throws {
        let github = FakeGitHub([.direct: [pr("A", number: 1), pr("B", number: 2)]])
        let poller = Poller(github: github)
        let before = Snapshot(unread: ["A", "B"], unreadSince: ["A": now.addingTimeInterval(-600), "B": now.addingTimeInterval(-600)])
        github.notifications = .success(["o/repo#1": InboxThread(unread: false, lastReadAt: now)])
        let after = try update(await poller.run(previous: before, settings: settings, now: now))
        #expect(github.requests == ["poll", "inbox"])
        #expect(after.snapshot.unread == ["B"])
        #expect(after.summary.contains("readOnGitHub=1"))
    }

    @Test func detailsAreKeptForThePRsOnShow() async throws {
        let bot = PullRequest(id: "bot", number: 9, title: "Bump", url: URL(string: "https://github.com/o/repo/pull/9")!, updatedAt: now,
                              author: Actor(login: "dependabot", isBot: true), repo: "o/repo")
        let github = FakeGitHub([.direct: [pr("A")], .team: [bot]])
        github.details = .success(["A": PRDetails(diff: DiffStat(additions: 3, deletions: 1), branch: "a")])
        let poller = Poller(github: github)
        let poll = try update(await poller.run(previous: nil, settings: settings, now: now))
        // Bots' PRs are hidden, so they get no details.
        #expect(poll.shown.map(\.id) == ["A"])
        let first = await poller.refreshDetails(for: poll.shown)
        #expect(first.requested == 1)
        #expect(first.details.branches == ["A": "a"])
        #expect(await poller.refreshDetails(for: poll.shown).requested == 0)

        github.details = .failure(.timeout)
        let failed = await poller.refreshDetails(for: [pr("A", updated: now.addingTimeInterval(60))])
        #expect(failed.error == "fetching details for 1 PRs failed: GitHub timed out")
        #expect(failed.details.branches == ["A": "a"])
    }
}
