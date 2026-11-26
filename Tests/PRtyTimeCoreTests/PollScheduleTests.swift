import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct PollScheduleTests {
    func result(remaining: Int? = nil, resetIn: TimeInterval = 0, fallback: Bool = false, warnings: [String] = []) -> PollResult {
        PollResult(
            data: poll([:]), rateLimit: remaining.map { RateLimit(cost: 1, remaining: $0, resetAt: now.addingTimeInterval(resetIn)) },
            requests: 4, cost: 1, usedFallback: fallback, warnings: warnings
        )
    }

    @Test func intervalIsAtLeastAMinute() {
        #expect(PollSchedule.interval(minutes: 2) == 120)
        #expect(PollSchedule.interval(minutes: 0) == 60)
    }

    @Test func retriesBackOffFromThirtySecondsToTenMinutes() {
        #expect((1...7).map { PollSchedule.retryDelay(failures: $0) } == [30, 60, 120, 240, 480, 600, 600])
        #expect(PollSchedule.retryDelay(failures: 0) == 30)
    }

    @Test func aLowRateLimitPausesUntilItResets() {
        let low = PollSchedule.afterSuccess(result(remaining: 199, resetIn: 1800), interval: 120, now: now)
        #expect(low.delay == 1805)
        #expect(low.warning?.hasPrefix("Rate limit low (199 left), pausing until") == true)
        // Resetting sooner than the interval doesn't poll early.
        #expect(PollSchedule.afterSuccess(result(remaining: 10, resetIn: 30), interval: 120, now: now).delay == 120)
        let enough = PollSchedule.afterSuccess(result(remaining: 200, resetIn: 1800), interval: 120, now: now)
        #expect(enough.delay == 120)
        #expect(enough.warning == nil)
    }

    @Test func warnsAboutTheFallbackBeforeGraphQLWarnings() {
        #expect(PollSchedule.afterSuccess(result(fallback: true, warnings: ["partial"]), interval: 120, now: now).warning
            == "Combined request timed out; fell back to 4 requests")
        #expect(PollSchedule.afterSuccess(result(warnings: ["partial", "other"]), interval: 120, now: now).warning == "partial")
        #expect(PollSchedule.afterSuccess(result(), interval: 120, now: now).warning == nil)
    }
}
