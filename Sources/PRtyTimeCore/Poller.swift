import Foundation

/// The GitHub requests a poll makes: `GitHubClient`, or a fake in tests.
public protocol GitHubAPI: Sendable {
    func poll() async throws -> PollResult
    func closedPRs(_ ids: [String]) async throws -> [ClosedPR]
    func mergeStatus(_ ids: [String]) async throws -> [String: MergeStatus]
    func details(_ ids: [String]) async throws -> [String: PRDetails]
    func inbox(since: Date, maxPages: Int) async throws -> [String: InboxThread]
}

extension GitHubClient: GitHubAPI {}

/// The settings a poll runs with.
public struct PollSettings: Sendable {
    public var intervalMinutes: Double
    /// Fetch checks and merge conflicts of the PRs the panel lists.
    public var fetchChecks: Bool
    public var diff: DiffSettings

    public init(intervalMinutes: Double, fetchChecks: Bool, diff: DiffSettings) {
        self.intervalMinutes = intervalMinutes
        self.fetchChecks = fetchChecks
        self.diff = diff
    }
}

/// A successful poll, for the app to show.
public struct PollUpdate: Sendable {
    public var snapshot: Snapshot
    public var buckets: [Bucket: [PullRequest]]
    /// Empty when not fetched; nil when fetching failed, so the last ones stay on show.
    public var mergeStatus: [String: MergeStatus]?
    /// PRs with new activity, which ends their snooze.
    public var activity: Set<String>
    public var notifications: [PRNotification]
    public var warning: String?
    /// Seconds until the next poll.
    public var delay: TimeInterval
    /// The PRs the panel lists, whose details `Poller.refreshDetails` keeps.
    public var shown: [PullRequest]
    /// Requests after the first that failed without failing the poll.
    public var errors: [String]
    /// Counts for the log: "requests=… closed=… readOnGitHub=… cost=… remaining=… checks=… notifications=…".
    public var summary: String
}

/// Runs polls: the search, then the lookups that depend on it, then the diff
/// against the previous snapshot. Keeps the failure count for backing off, and
/// the PRs' details between polls.
public actor Poller {
    public enum Outcome: Sendable {
        case updated(PollUpdate)
        case failed(message: String, failures: Int, delay: TimeInterval)
        /// Cancelled for a poll started sooner; not counted as a failure.
        case cancelled(delay: TimeInterval)
    }

    private let github: any GitHubAPI
    private var failures = 0
    private var details = DetailsCache()

    public init(github: any GitHubAPI) {
        self.github = github
    }

    public func run(previous: Snapshot?, settings: PollSettings, now: Date = Date()) async -> Outcome {
        let interval = PollSchedule.interval(minutes: settings.intervalMinutes)
        do {
            let result = try await github.poll()
            var data = result.data
            var errors: [String] = []
            // PRs that left every list: look up which were merged.
            if let missing = previous?.missing(from: data), !missing.isEmpty {
                do {
                    data.closed = try await github.closedPRs(missing)
                } catch {
                    errors.append("checking \(missing.count) closed PRs failed: \(error.localizedDescription)")
                }
            }
            let sections = MenuSections(buckets: data.buckets, staleDays: settings.diff.staleDays, hideBots: settings.diff.ignoreBots, now: now)
            let shown = sections.toReview.map(\.pr) + sections.reviewed + sections.mine
            // For every PR on show (only yours notify when they fail), every
            // poll, not only for updated PRs like details: checks finishing
            // needn't change a PR's updatedAt.
            if settings.fetchChecks {
                let ids = shown.map(\.id)
                do {
                    data.mergeStatus = try await github.mergeStatus(ids)
                } catch {
                    data.mergeStatus = nil
                    errors.append("fetching checks for \(ids.count) PRs failed: \(error.localizedDescription)")
                }
            }
            let diff = ActivityDiff.run(previous: previous, poll: data, settings: settings.diff)
            var next = diff.snapshot
            // Clear dots for PRs read on GitHub.
            var readOnGitHub = 0
            if let since = next.inboxFetchStart(now: now) {
                do {
                    let inbox = try await github.inbox(since: since, maxPages: 4)
                    readOnGitHub = next.syncRead(with: inbox, prs: data.buckets.values.flatMap { $0 })
                } catch {
                    errors.append("checking GitHub notifications failed: \(error.localizedDescription)")
                }
            }
            failures = 0
            let schedule = PollSchedule.afterSuccess(result, interval: interval, now: now)
            let summary = "requests=\(result.requests) closed=\(data.closed.count) readOnGitHub=\(readOnGitHub) cost=\(result.cost) "
                + "remaining=\(result.rateLimit?.remaining ?? -1) checks=\(data.mergeStatus?.count ?? -1) notifications=\(diff.notifications.count)"
            return .updated(PollUpdate(
                snapshot: next, buckets: data.buckets, mergeStatus: data.mergeStatus, activity: diff.activity,
                notifications: diff.notifications, warning: schedule.warning, delay: schedule.delay,
                shown: shown, errors: errors, summary: summary
            ))
        } catch {
            if Task.isCancelled { return .cancelled(delay: interval) }
            failures += 1
            return .failed(message: error.localizedDescription, failures: failures, delay: PollSchedule.retryDelay(failures: failures))
        }
    }

    /// Fetches line counts and branches for the PRs in `prs` that are new or
    /// updated since their last fetch, and drops the ones not in `prs`. Returns
    /// the details kept, how many PRs were requested, and why that failed.
    public func refreshDetails(for prs: [PullRequest]) async -> (details: DetailsCache, requested: Int, error: String?) {
        let requested = details.outdated(keeping: prs)
        guard !requested.isEmpty else { return (details, 0, nil) }
        do {
            details.store(try await github.details(Array(requested.keys)), requested: requested)
            return (details, requested.count, nil)
        } catch {
            return (details, requested.count, "fetching details for \(requested.count) PRs failed: \(error.localizedDescription)")
        }
    }
}
