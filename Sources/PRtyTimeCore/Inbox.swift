import Foundation

/// A PR's thread in your GitHub notifications.
public struct InboxThread: Sendable, Equatable {
    public var unread: Bool
    public var lastReadAt: Date?

    public init(unread: Bool, lastReadAt: Date? = nil) {
        self.unread = unread
        self.lastReadAt = lastReadAt
    }
}

extension PullRequest {
    /// GitHub notifications identify PRs by repo and number, not node id.
    public var inboxKey: String { "\(repo.lowercased())#\(number)" }
}

extension Snapshot {
    /// How far back GitHub notifications need checking; nil when nothing is unread.
    public var inboxSince: Date? { unread.compactMap { unreadSince[$0] }.min() }

    /// How far back `inboxFetchStart` goes at most, so a dot that never clears
    /// doesn't widen the request forever.
    public static let inboxWindow: TimeInterval = 14 * 86_400

    /// Where to start checking GitHub notifications: `inboxSince`, at most `inboxWindow` back.
    public func inboxFetchStart(now: Date) -> Date? {
        inboxSince.map { max($0, now.addingTimeInterval(-Self.inboxWindow)) }
    }

    /// Clears the dots of `ids`, as opening them from the panel does.
    public mutating func markRead(_ ids: some Sequence<String>) {
        for id in ids {
            unread.remove(id)
            unreadSince[id] = nil
            unreadOnGitHub.remove(id)
        }
    }

    /// Puts a dot on `id` by hand at `date`. Like one from activity, it clears
    /// when the PR is opened, or read on GitHub after `date`.
    public mutating func markUnread(_ id: String, at date: Date) {
        unread.insert(id)
        unreadSince[id] = date
        unreadOnGitHub.remove(id)
    }

    /// Clears the dots of PRs read on GitHub after their activity. Returns how many it cleared.
    @discardableResult
    public mutating func syncRead(with inbox: [String: InboxThread], prs: [PullRequest]) -> Int {
        let keys = Dictionary(prs.map { ($0.id, $0.inboxKey) }, uniquingKeysWith: { first, _ in first })
        var cleared = 0
        for id in unread {
            guard let key = keys[id], let thread = inbox[key] else { continue }
            if thread.unread {
                unreadOnGitHub.insert(id)
                continue
            }
            let readAfterActivity = zip(thread.lastReadAt, unreadSince[id]).map { $0 > $1 } ?? false
            guard unreadOnGitHub.contains(id) || readAfterActivity else { continue }
            unread.remove(id)
            unreadSince[id] = nil
            unreadOnGitHub.remove(id)
            cleared += 1
        }
        return cleared
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Decodes a page of `GET /notifications`, keeping pull request threads keyed by `PullRequest.inboxKey`.
enum InboxResponse {
    private struct Thread: Decodable {
        struct Subject: Decodable { var type: String; var url: String? }
        struct Repository: Decodable { var fullName: String }
        var unread: Bool
        var lastReadAt: Date?
        var subject: Subject
        var repository: Repository
    }

    static func decode(_ body: Data) throws -> [String: InboxThread] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        var threads: [String: InboxThread] = [:]
        for thread in try decoder.decode([Thread].self, from: body) where thread.subject.type == "PullRequest" {
            // subject.url is the API URL, ending in /pulls/<number>.
            guard let number = thread.subject.url?.split(separator: "/").last.flatMap({ Int($0) }) else { continue }
            threads["\(thread.repository.fullName.lowercased())#\(number)"] = InboxThread(unread: thread.unread, lastReadAt: thread.lastReadAt)
        }
        return threads
    }
}
