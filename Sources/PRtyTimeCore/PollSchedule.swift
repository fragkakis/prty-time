import Foundation

/// When to poll next, and what to warn about after a poll.
public enum PollSchedule {
    /// With fewer requests left than this, polling pauses until the rate limit resets.
    public static let lowRateLimit = 200

    /// The poll interval setting in seconds, at least a minute.
    public static func interval(minutes: Double) -> TimeInterval {
        max(1, minutes) * 60
    }

    /// The wait after the `failures`th failed poll in a row: 30 seconds, doubling, at most 10 minutes.
    public static func retryDelay(failures: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(failures, 1) - 1)), 600)
    }

    /// The wait after a successful poll, and the warning to show. A low rate limit
    /// pauses polling until it resets; otherwise the wait is `interval`.
    public static func afterSuccess(_ result: PollResult, interval: TimeInterval, now: Date) -> (delay: TimeInterval, warning: String?) {
        if let limit = result.rateLimit, limit.remaining < lowRateLimit {
            let warning = "Rate limit low (\(limit.remaining) left), pausing until \(limit.resetAt.formatted(date: .omitted, time: .shortened))"
            return (max(interval, limit.resetAt.timeIntervalSince(now) + 5), warning)
        }
        let warning = result.usedFallback
            ? "Combined request timed out; fell back to \(result.requests) requests"
            : result.warnings.first
        return (interval, warning)
    }
}
