import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct InboxTests {
    let earlier = now.addingTimeInterval(-600)
    let prs = [pr("A", number: 1), pr("B", number: 2), pr("C", number: 3), pr("D", number: 4)]

    func snapshot(unread: [String: Date], onGitHub: Set<String> = []) -> Snapshot {
        Snapshot(unread: Set(unread.keys), unreadSince: unread, unreadOnGitHub: onGitHub)
    }

    @Test func readOnGitHubAfterTheActivityClearsTheDot() {
        var s = snapshot(unread: ["A": earlier, "B": earlier, "C": earlier, "D": earlier])
        let inbox: [String: InboxThread] = [
            "o/repo#1": InboxThread(unread: false, lastReadAt: now),
            "o/repo#2": InboxThread(unread: false, lastReadAt: earlier.addingTimeInterval(-60)),
            "o/repo#3": InboxThread(unread: true),
            // D has no thread, e.g. its only activity was a push.
        ]
        #expect(s.syncRead(with: inbox, prs: prs) == 1)
        #expect(s.unread == ["B", "C", "D"])
        #expect(s.unreadSince["A"] == nil)
        #expect(s.unreadOnGitHub == ["C"])
    }

    @Test func seenUnreadThenReadClearsEvenWithoutReadTime() {
        var s = snapshot(unread: ["A": earlier], onGitHub: ["A"])
        s.syncRead(with: ["o/repo#1": InboxThread(unread: false)], prs: prs)
        #expect(s.unread.isEmpty)
        #expect(s.unreadOnGitHub.isEmpty)
    }

    @Test func notificationsAreCheckedFromTheOldestDotAtMostTwoWeeksBack() {
        #expect(snapshot(unread: [:]).inboxFetchStart(now: now) == nil)
        #expect(snapshot(unread: ["A": earlier, "B": now]).inboxFetchStart(now: now) == earlier)
        let old = now.addingTimeInterval(-30 * 86_400)
        #expect(snapshot(unread: ["A": old]).inboxFetchStart(now: now) == now.addingTimeInterval(-14 * 86_400))
    }

    @Test func markingReadClearsEverythingAboutTheDot() {
        var s = snapshot(unread: ["A": earlier, "B": earlier], onGitHub: ["A"])
        s.markRead(["A", "C"])
        #expect(s.unread == ["B"])
        #expect(s.unreadSince == ["B": earlier])
        #expect(s.unreadOnGitHub.isEmpty)
    }

    @Test func aDotMarkedByHandOutlivesAnEarlierReadOnGitHub() {
        var s = snapshot(unread: [:])
        s.markUnread("A", at: now)
        s.markUnread("B", at: now)
        let inbox: [String: InboxThread] = [
            "o/repo#1": InboxThread(unread: false, lastReadAt: earlier),
            "o/repo#2": InboxThread(unread: false, lastReadAt: now.addingTimeInterval(60)),
        ]
        #expect(s.syncRead(with: inbox, prs: prs) == 1)
        #expect(s.unread == ["A"])
        #expect(s.inboxSince == now)
    }

    @Test func aDotMarkedByHandSurvivesThePoll() {
        var s = ActivityDiff.run(previous: nil, poll: poll([.direct: [pr("A")]]), settings: DiffSettings(now: now)).snapshot
        s.markUnread("A", at: now)
        let next = ActivityDiff.run(previous: s, poll: poll([.direct: [pr("A")]]), settings: DiffSettings(now: now))
        #expect(next.snapshot.unread == ["A"])
        #expect(next.notifications.isEmpty)
    }

    @Test func inboxSinceIsTheOldestDot() {
        #expect(snapshot(unread: ["A": earlier, "B": now]).inboxSince == earlier)
        #expect(Snapshot().inboxSince == nil)
    }

    @Test func diffRecordsWhenTheActivityCouldStart() {
        let seeded = ActivityDiff.run(previous: nil, poll: poll([.mine: [pr("A", author: me)]]), settings: DiffSettings(now: earlier)).snapshot
        #expect(seeded.polledAt == earlier)

        var result = ActivityDiff.run(
            previous: seeded, poll: poll([.mine: [pr("A", author: me, comments: [comment("c1", by: "bob")])]]), settings: DiffSettings(now: now)
        ).snapshot
        #expect(result.unreadSince == ["A": earlier])

        // New activity on a dot already seen unread on GitHub: it has to be seen unread again.
        result.unreadOnGitHub = ["A"]
        let next = ActivityDiff.run(
            previous: result,
            poll: poll([.mine: [pr("A", author: me, comments: [comment("c1", by: "bob"), comment("c2", by: "bob")])]]),
            settings: DiffSettings(now: now.addingTimeInterval(120))
        ).snapshot
        #expect(next.unreadSince == ["A": now])
        #expect(next.unreadOnGitHub.isEmpty)
    }

    @Test func dotsFromOlderStateAssumeTheLastWeek() {
        var old = ActivityDiff.run(previous: nil, poll: poll([.mine: [pr("A", author: me)]]), settings: DiffSettings(now: now)).snapshot
        old.unread = ["A"]
        old.polledAt = nil
        let result = ActivityDiff.run(previous: old, poll: poll([.mine: [pr("A", author: me)]]), settings: DiffSettings(now: now)).snapshot
        #expect(result.unreadSince == ["A": now.addingTimeInterval(-7 * 86_400)])
    }

    @Test func decodesPullRequestThreads() throws {
        let json = #"""
        [
          {"unread": true, "last_read_at": null, "reason": "review_requested",
           "subject": {"type": "PullRequest", "url": "https://api.github.com/repos/Acme/API/pulls/42"},
           "repository": {"full_name": "Acme/API"}},
          {"unread": false, "last_read_at": "2026-11-17T08:41:05Z", "reason": "author",
           "subject": {"type": "PullRequest", "url": "https://api.github.com/repos/acme/web/pulls/7"},
           "repository": {"full_name": "acme/web"}},
          {"unread": true, "last_read_at": null, "reason": "subscribed",
           "subject": {"type": "Release", "url": "https://api.github.com/repos/acme/web/releases/1"},
           "repository": {"full_name": "acme/web"}}
        ]
        """#
        let threads = try InboxResponse.decode(Data(json.utf8))
        #expect(threads.count == 2)
        #expect(threads["acme/web#7"]?.lastReadAt == ISO8601DateFormatter().date(from: "2026-11-17T08:41:05Z"))
        var p = pr("X", number: 42)
        p.repo = "Acme/API"
        #expect(threads[p.inboxKey] == InboxThread(unread: true))
    }

    @Test func nextPageFromLinkHeader() {
        let link = #"<https://api.github.com/notifications?page=2>; rel="next", <https://api.github.com/notifications?page=5>; rel="last""#
        #expect(GitHubClient.nextPage(link)?.absoluteString == "https://api.github.com/notifications?page=2")
        #expect(GitHubClient.nextPage(#"<https://api.github.com/notifications?page=1>; rel="prev""#) == nil)
        #expect(GitHubClient.nextPage(nil) == nil)
    }
}
