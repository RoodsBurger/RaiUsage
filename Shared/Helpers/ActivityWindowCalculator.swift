import Foundation

/// Totals for one trailing activity window (5h / 7d), derived from local
/// Claude Code JSONL history. On enterprise plans the usage API does not
/// track the 5h/weekly windows, so these history-derived numbers stand in
/// for them on the dashboard, the menu bar, and the popover.
struct ActivityWindowSummary: Equatable, Sendable {
    /// Active (input + output) tokens observed inside the window.
    let activeTokens: Int
    /// Sessions that STARTED inside the window: `SessionHistoryService`
    /// attributes each file's session count to its earliest bucket, so a
    /// session spanning the window boundary counts only in the window that
    /// contains its first activity.
    let sessionCount: Int
}

/// Pure window math over `HistoryBucket` arrays - no I/O, no stores, fully
/// unit-testable. The buckets come from `SessionHistoryService` (hourly for
/// the 24h range, daily otherwise) and are already range-filtered at the
/// hourly level, so a partial boundary bucket never over-counts.
enum ActivityWindowCalculator {
    /// Sums active tokens and session starts across the buckets that
    /// intersect the trailing window `[now - window, now]`. A bucket
    /// intersects when any part of its `[date, date + bucketSpan)` span
    /// overlaps the window, so the partial bucket at the window's older edge
    /// still contributes (its contents are pre-filtered by the service).
    /// Buckets starting after `now` are ignored.
    static func summary(
        buckets: [HistoryBucket],
        window: TimeInterval,
        bucketSpan: TimeInterval,
        now: Date = Date()
    ) -> ActivityWindowSummary {
        let windowStart = now.addingTimeInterval(-window)
        var tokens = 0
        var sessions = 0
        for bucket in buckets {
            guard bucket.date.addingTimeInterval(bucketSpan) > windowStart,
                  bucket.date <= now else { continue }
            tokens += bucket.totalActive
            sessions += bucket.sessionsCount
        }
        return ActivityWindowSummary(activeTokens: tokens, sessionCount: sessions)
    }

    /// Localized session-count caption ("1 session" / "12 sessions") shared
    /// by the dashboard activity tiles and the popover activity rows.
    static func sessionsLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "activity.sessions.one")
            : String(format: String(localized: "activity.sessions.many"), count)
    }
}
