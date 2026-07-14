import Testing
import Foundation

@Suite("ActivityWindowCalculator")
struct ActivityWindowCalculatorTests {

    /// Fixed instant so every window boundary is deterministic.
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private static func bucket(hoursAgo: Double, tokens: Int, sessions: Int = 0) -> HistoryBucket {
        HistoryBucket(
            date: now.addingTimeInterval(-hoursAgo * 3600),
            tokensByModel: [.fable: tokens],
            tokensByProject: [:],
            sessionsCount: sessions,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreateTokens: 0
        )
    }

    private func fiveHourSummary(_ buckets: [HistoryBucket]) -> ActivityWindowSummary {
        ActivityWindowCalculator.summary(buckets: buckets, window: 5 * 3600, bucketSpan: 3600, now: Self.now)
    }

    @Test("empty buckets yield a zero summary")
    func emptyBuckets() {
        let summary = fiveHourSummary([])
        #expect(summary == ActivityWindowSummary(activeTokens: 0, sessionCount: 0))
    }

    @Test("sums tokens and sessions across in-window buckets")
    func sumsInWindow() {
        let summary = fiveHourSummary([
            Self.bucket(hoursAgo: 1, tokens: 100, sessions: 1),
            Self.bucket(hoursAgo: 2, tokens: 250, sessions: 2),
            Self.bucket(hoursAgo: 4, tokens: 50, sessions: 0),
        ])
        #expect(summary.activeTokens == 400)
        #expect(summary.sessionCount == 3)
    }

    @Test("excludes buckets entirely older than the window")
    func excludesOldBuckets() {
        let summary = fiveHourSummary([
            Self.bucket(hoursAgo: 1, tokens: 100, sessions: 1),
            // Started 7h ago and spans one hour -> fully outside [now-5h, now].
            Self.bucket(hoursAgo: 7, tokens: 999, sessions: 5),
        ])
        #expect(summary.activeTokens == 100)
        #expect(summary.sessionCount == 1)
    }

    @Test("keeps the partial boundary bucket whose span crosses the window start")
    func keepsBoundaryBucket() {
        // Started 5.5h ago, spans until 4.5h ago -> overlaps the last 5h.
        let summary = fiveHourSummary([Self.bucket(hoursAgo: 5.5, tokens: 80, sessions: 1)])
        #expect(summary.activeTokens == 80)
        #expect(summary.sessionCount == 1)
    }

    @Test("drops a bucket whose span ends exactly at the window start")
    func dropsExactBoundary() {
        // Started 6h ago, span ends exactly at now-5h -> no overlap (half-open).
        let summary = fiveHourSummary([Self.bucket(hoursAgo: 6, tokens: 80, sessions: 1)])
        #expect(summary.activeTokens == 0)
    }

    @Test("ignores buckets starting after now")
    func ignoresFutureBuckets() {
        let summary = fiveHourSummary([Self.bucket(hoursAgo: -1, tokens: 500, sessions: 1)])
        #expect(summary.activeTokens == 0)
        #expect(summary.sessionCount == 0)
    }

    @Test("7d window over daily buckets keeps the partial oldest day")
    func sevenDayDailyBuckets() {
        // Daily buckets are start-of-day aligned; the oldest one can start
        // before now-7d while its (pre-filtered) contents lie inside.
        let daily = [
            Self.bucket(hoursAgo: 7 * 24 + 12, tokens: 300, sessions: 2), // partial oldest day
            Self.bucket(hoursAgo: 3 * 24, tokens: 700, sessions: 4),
            Self.bucket(hoursAgo: 0, tokens: 100, sessions: 1),
        ]
        let summary = ActivityWindowCalculator.summary(
            buckets: daily, window: 7 * 86_400, bucketSpan: 86_400, now: Self.now
        )
        #expect(summary.activeTokens == 1100)
        #expect(summary.sessionCount == 7)
    }

    @Test("a bucket 8+ days old stays out of the 7d window")
    func sevenDayExcludesOlder() {
        let daily = [Self.bucket(hoursAgo: 8 * 24 + 1, tokens: 900, sessions: 3)]
        let summary = ActivityWindowCalculator.summary(
            buckets: daily, window: 7 * 86_400, bucketSpan: 86_400, now: Self.now
        )
        #expect(summary.activeTokens == 0)
    }
}
