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
    /// JSONL history at all for the active source - consumers render "—".
    @Published private(set) var fiveHour: ActivityWindowSummary?
    @Published private(set) var sevenDay: ActivityWindowSummary?
    @Published private(set) var hasLoaded = false

    /// Active source selection for the popover activity tiles (nil = "All
    /// sources"). Independent of `HistoryStore.sourceFilter`. Changing it
    /// recomputes from already-loaded per-source buckets (no re-scan).
    @Published var sourceFilter: LogSource? {
        didSet { if oldValue != sourceFilter { recompute() } }
    }

    private let service: SessionHistoryServiceProtocol
    private var loadTask: Task<Void, Never>?
    private var inFlight = false
    private var lastLoaded: Date?
    private static let staleAfter: TimeInterval = 60

    /// Per-source hourly (24h) and daily (7d) buckets from the last scan.
    private var hourlyBySource: [LogSource: [HistoryBucket]] = [:]
    private var dailyBySource: [LogSource: [HistoryBucket]] = [:]
    /// Enabled + disabled instances defining the remote scan roots.
    private var currentInstances: [RemoteInstance] = []

    init(service: SessionHistoryServiceProtocol = SessionHistoryService()) {
        self.service = service
    }

    /// Updates the remote instances feeding the scan roots. A real change
    /// invalidates the cache so the next `warmIfStale` re-scans with the new
    /// roots, and drops a stale `sourceFilter` for a removed/disabled instance.
    func setInstances(_ instances: [RemoteInstance]) {
        guard instances != currentInstances else { return }
        currentInstances = instances
        lastLoaded = nil
        if case .instance(let id, _)? = sourceFilter,
           !instances.contains(where: { $0.enabled && $0.id == id }) {
            sourceFilter = nil
        }
    }

    /// Forces the next `warmIfStale` to re-scan (e.g. after a remote sync
    /// refreshed a cache dir).
    func invalidate() {
        lastLoaded = nil
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
        let roots = LogSourceAggregator.buildRoots(instances: currentInstances)
        loadTask = Task { [weak self] in
            do {
                // 24h range -> hourly buckets (5h window needs hour-level
                // resolution); 7d range -> daily buckets. Both scan every
                // source root so the tiles can be scoped to one instance.
                async let hourlyTask = Task.detached(priority: .utility) {
                    try await service.loadHistoryBySource(range: .twentyFourHours, roots: roots)
                }.value
                async let dailyTask = Task.detached(priority: .utility) {
                    try await service.loadHistoryBySource(range: .sevenDays, roots: roots)
                }.value

                let hourly = try await hourlyTask
                let daily = try await dailyTask
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.inFlight = false
                    return
                }

                self.hourlyBySource = hourly
                self.dailyBySource = daily
                self.hasLoaded = true
                self.lastLoaded = Date()
                self.inFlight = false
                self.recompute()
            } catch {
                // Silent fail - keep the previous (possibly stale) summaries.
                self?.inFlight = false
            }
        }
    }

    /// Re-derives the 5h / 7d tiles for the current source selection from the
    /// stored per-source buckets. No I/O.
    private func recompute() {
        let now = Date()
        let hourly = LogSourceAggregator.activeBuckets(bySource: hourlyBySource, sourceFilter: sourceFilter)
        let daily = LogSourceAggregator.activeBuckets(bySource: dailyBySource, sourceFilter: sourceFilter)
        if hourly.isEmpty && daily.isEmpty {
            // No history at all for this source -> keep nil so surfaces show
            // "—" instead of a misleading hard zero.
            fiveHour = nil
            sevenDay = nil
        } else {
            fiveHour = ActivityWindowCalculator.summary(
                buckets: hourly, window: 5 * 3600, bucketSpan: 3600, now: now
            )
            sevenDay = ActivityWindowCalculator.summary(
                buckets: daily, window: 7 * 86_400, bucketSpan: 86_400, now: now
            )
        }
    }
}
