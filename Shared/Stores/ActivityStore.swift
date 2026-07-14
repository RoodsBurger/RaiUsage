import Foundation
import SwiftUI

/// App-level cache of the history-derived activity windows (5h / 7d) shown on
/// enterprise plans, where the usage API doesn't track those windows. Owned by
/// `RaiUsageApp` (not a view) because the menu bar pins and the popover need
/// the data while the dashboard window is closed.
///
/// Caching contract: JSONL parsing happens ONLY inside `warmIfStale()`, on a
/// background task, at most once per `staleAfter` - the menu bar render path
/// just reads the published values. `StatusBarController` gates every warm
/// call on enterprise + a surface that actually displays activity, so
/// personal plans never trigger a scan. `SessionHistoryService`'s per-file
/// mtime cache keeps the repeat scans cheap.
@MainActor
final class ActivityStore: ObservableObject {

    /// nil until the first successful load, and stays nil when there is no
    /// local JSONL history at all - consumers render "—" for nil.
    @Published private(set) var fiveHour: ActivityWindowSummary?
    @Published private(set) var sevenDay: ActivityWindowSummary?
    @Published private(set) var hasLoaded = false

    private let service: SessionHistoryServiceProtocol
    private var loadTask: Task<Void, Never>?
    private var inFlight = false
    private var lastLoaded: Date?
    private static let staleAfter: TimeInterval = 60

    init(service: SessionHistoryServiceProtocol = SessionHistoryService()) {
        self.service = service
    }

    /// Kicks a background load unless one is in flight or the cached data is
    /// younger than 60s. Safe to call from high-frequency sinks - the guards
    /// make the common case a no-op.
    func warmIfStale() {
        guard !inFlight else { return }
        if let lastLoaded, hasLoaded, Date().timeIntervalSince(lastLoaded) < Self.staleAfter {
            return
        }
        inFlight = true
        let service = self.service
        loadTask = Task { [weak self] in
            do {
                // 24h range -> hourly buckets (5h window needs hour-level
                // resolution); 7d range -> daily buckets.
                async let hourlyTask = Task.detached(priority: .utility) {
                    try await service.loadHistory(range: .twentyFourHours)
                }.value
                async let dailyTask = Task.detached(priority: .utility) {
                    try await service.loadHistory(range: .sevenDays)
                }.value

                let hourly = try await hourlyTask
                let daily = try await dailyTask
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.inFlight = false
                    return
                }

                let now = Date()
                if hourly.isEmpty && daily.isEmpty {
                    // No local history at all -> keep nil so surfaces show "—"
                    // instead of a misleading hard zero.
                    self.fiveHour = nil
                    self.sevenDay = nil
                } else {
                    self.fiveHour = ActivityWindowCalculator.summary(
                        buckets: hourly, window: 5 * 3600, bucketSpan: 3600, now: now
                    )
                    self.sevenDay = ActivityWindowCalculator.summary(
                        buckets: daily, window: 7 * 86_400, bucketSpan: 86_400, now: now
                    )
                }
                self.hasLoaded = true
                self.lastLoaded = now
                self.inFlight = false
            } catch {
                // Silent fail - keep the previous (possibly stale) summaries.
                self?.inFlight = false
            }
        }
    }
}
