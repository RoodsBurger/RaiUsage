import Foundation
import SwiftUI

/// Drives `HistoryView`. Owns the active range + filter, kicks off cancellable
/// load tasks on a detached priority `.utility` queue, and exposes the
/// aggregated buckets + summary for the view to render.
@MainActor
final class HistoryStore: ObservableObject {

    // MARK: - State

    @Published var range: HistoryRange = .sevenDays {
        didSet { if oldValue != range { reload() } }
    }

    @Published var filter: HistoryFilter = .all

    /// Active source selection (nil = "All sources"). Applied on top of the
    /// range + model filters. Changing it recomputes from already-loaded
    /// per-source buckets, so switching sources is instant (no re-scan).
    @Published var sourceFilter: LogSource? {
        didSet { if oldValue != sourceFilter { recomputeForSource() } }
    }

    /// Buckets for the CURRENT source selection within the active range. Kept
    /// un-filtered by model so swapping the model filter is instant.
    @Published private(set) var buckets: [HistoryBucket] = []

    /// Raw per-source buckets from the last load, keyed by `LogSource`. The
    /// source picker narrows `buckets` from this without re-parsing.
    @Published private(set) var bucketsBySource: [LogSource: [HistoryBucket]] = [:]

    /// Summary computed from `buckets` after applying `filter`.
    @Published private(set) var summary: HistorySummary = .empty

    @Published private(set) var isLoading: Bool = false

    /// True once we attempted at least one load; prevents the empty-state from
    /// flashing during the cold load.
    @Published private(set) var hasLoadedOnce: Bool = false

    /// Active model families derived from the data. Drives the auto-adaptive
    /// legend + which filter chips light up vs grey out.
    @Published private(set) var activeFamilies: Set<ModelFamily> = []

    /// Total active tokens per family for the chip badges (e.g. "Opus · 1.2M").
    @Published private(set) var familyTotals: [ModelFamily: Int] = [:]

    // MARK: - Wiring

    private let service: SessionHistoryServiceProtocol
    private let pricing: PricingServiceProtocol
    private var loadTask: Task<Void, Never>?

    /// Enabled + disabled instances that define the remote scan roots. Fed by
    /// the view from `RemoteInstancesStore`; a change re-scans on next reload.
    private var currentInstances: [RemoteInstance] = []

    init(
        service: SessionHistoryServiceProtocol = SessionHistoryService(),
        pricing: PricingServiceProtocol = PricingService()
    ) {
        self.service = service
        self.pricing = pricing
    }

    // MARK: - Public

    /// Updates the remote instances feeding the scan roots. Drops a stale
    /// `sourceFilter` that points at a removed/disabled instance. Does not
    /// reload on its own; the caller pairs it with `reload()`.
    func setInstances(_ instances: [RemoteInstance]) {
        currentInstances = instances
        if case .instance(let id, _)? = sourceFilter,
           !instances.contains(where: { $0.enabled && $0.id == id }) {
            sourceFilter = nil
        }
    }

    func setSourceFilter(_ newSource: LogSource?) {
        guard sourceFilter != newSource else { return }
        sourceFilter = newSource
    }

    func reload() {
        loadTask?.cancel()
        let range = self.range
        let service = self.service
        let roots = LogSourceAggregator.buildRoots(instances: currentInstances)
        // Refresh the maintained price table in the background (throttled to
        // 24h internally). Fire-and-forget: the cost UI reads the cached table
        // synchronously and never waits on this.
        let pricing = self.pricing
        Task { await pricing.refresh() }
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let bucketsTask = Task.detached(priority: .utility) {
                    try await service.loadHistoryBySource(range: range, roots: roots)
                }.value
                async let previousTask = Task.detached(priority: .utility) {
                    try await service.loadPreviousPeriodActiveTokensBySource(range: range, roots: roots)
                }.value

                let bySource = try await bucketsTask
                let previousBySource = (try? await previousTask) ?? [:]

                if Task.isCancelled { return }
                await MainActor.run {
                    self.applyResult(bySource: bySource, previousBySource: previousBySource)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.bucketsBySource = [:]
                    self.buckets = []
                    self.summary = .empty
                    self.isLoading = false
                    self.hasLoadedOnce = true
                }
            }
        }
    }

    func setFilter(_ newFilter: HistoryFilter) {
        guard filter != newFilter else { return }
        filter = newFilter
        recomputeSummary()
    }

    // MARK: - Private

    private func applyResult(bySource: [LogSource: [HistoryBucket]], previousBySource: [LogSource: Int]) {
        self.bucketsBySource = bySource
        self.previousActiveBySource = previousBySource
        self.isLoading = false
        self.hasLoadedOnce = true
        recomputeForSource()
    }

    /// Re-derives `buckets` + family stats + previous-period for the current
    /// source selection, then the summary. Called after a load and whenever
    /// the source picker changes (no re-scan).
    private func recomputeForSource() {
        let active = LogSourceAggregator.activeBuckets(bySource: bucketsBySource, sourceFilter: sourceFilter)
        self.buckets = active
        self.activeFamilies = Self.activeFamilies(in: active)
        self.familyTotals = Self.familyTotals(in: active)
        self.previousPeriodActive = LogSourceAggregator.previousActive(
            previousBySource: previousActiveBySource, sourceFilter: sourceFilter
        )
        recomputeSummary()
    }

    /// Previous-period active tokens per source from the last load.
    private var previousActiveBySource: [LogSource: Int] = [:]

    /// Previous-period active tokens for the active source, cached so
    /// `recomputeSummary` (called on every filter flip) needn't re-load.
    private var previousPeriodActive: Int = 0

    private func recomputeSummary() {
        let filtered = applyFilter(to: buckets, filter: filter)

        let totalActive = filtered.reduce(0) { $0 + $1.totalActive }
        let totalCached = filtered.reduce(0) { $0 + $1.cachedTokens }
        let sessionsCount = filtered.reduce(0) { $0 + $1.sessionsCount }

        let heaviest = filtered.max(by: { $0.totalActive < $1.totalActive })

        // Top model: across the filtered range, which model carried the most
        // active tokens.
        var modelTotals: [ModelKind: Int] = [:]
        for bucket in filtered {
            for (kind, tokens) in bucket.tokensByModel {
                modelTotals[kind, default: 0] += tokens
            }
        }
        let topModel: (kind: ModelKind, tokens: Int)? = modelTotals
            .max(by: { $0.value < $1.value })
            .map { (kind: $0.key, tokens: $0.value) }

        // Top project: same idea over the project breakdown.
        var projectTotals: [String: Int] = [:]
        for bucket in filtered {
            for (path, tokens) in bucket.tokensByProject {
                projectTotals[path, default: 0] += tokens
            }
        }
        let topProject: (path: String, tokens: Int)? = projectTotals
            .max(by: { $0.value < $1.value })
            .map { (path: $0.key, tokens: $0.value) }

        // The previous-period delta only makes sense when `filter == .all`.
        // Filtered totals don't have an apples-to-apples previous comparison
        // (we'd have to refetch with the same filter), so we zero it out for
        // the filtered case to avoid lying with the % delta.
        let prev = filter.isAll ? previousPeriodActive : 0

        summary = HistorySummary(
            totalActive: totalActive,
            totalCached: totalCached,
            previousPeriodActive: prev,
            heaviestBucket: heaviest,
            topModel: topModel,
            topProject: topProject,
            sessionsCount: sessionsCount
        )
    }

    private func applyFilter(to buckets: [HistoryBucket], filter: HistoryFilter) -> [HistoryBucket] {
        switch filter {
        case .all:
            return buckets
        case .family(let family):
            return buckets.map { bucket in
                var b = bucket
                b.tokensByModel = bucket.tokensByModel.filter { $0.key.family == family }
                // Active token totals are recomputed lazily via totalActive,
                // but we also need the input/output split if we want to keep
                // cache hit rate accurate. Conservatively zero out the cache
                // counters when filtering to avoid lying about cache hit rate
                // for a model-specific view (cache counters are not reported
                // per-model in the JSONL, so we can't attribute them).
                let kept = b.tokensByModel.values.reduce(0, +)
                let scale = bucket.totalActive == 0 ? 0 : Double(kept) / Double(bucket.totalActive)
                b.inputTokens = Int(Double(bucket.inputTokens) * scale)
                b.outputTokens = Int(Double(bucket.outputTokens) * scale)
                b.cacheReadTokens = Int(Double(bucket.cacheReadTokens) * scale)
                b.cacheCreateTokens = Int(Double(bucket.cacheCreateTokens) * scale)
                return b
            }
        }
    }

    private static func activeFamilies(in buckets: [HistoryBucket]) -> Set<ModelFamily> {
        var set: Set<ModelFamily> = []
        for bucket in buckets {
            for kind in bucket.tokensByModel.keys {
                set.insert(kind.family)
            }
        }
        return set
    }

    private static func familyTotals(in buckets: [HistoryBucket]) -> [ModelFamily: Int] {
        var totals: [ModelFamily: Int] = [:]
        for bucket in buckets {
            for (kind, tokens) in bucket.tokensByModel {
                totals[kind.family, default: 0] += tokens
            }
        }
        return totals
    }

    /// Total active tokens per `ModelKind` across the given buckets. Pure and
    /// static so it can be unit-tested without a MainActor store instance.
    /// Used by the chart to decide which kinds have any data to stack.
    nonisolated static func totalsByKind(in buckets: [HistoryBucket]) -> [ModelKind: Int] {
        var totals: [ModelKind: Int] = [:]
        for bucket in buckets {
            for (kind, tokens) in bucket.tokensByModel {
                totals[kind, default: 0] += tokens
            }
        }
        return totals
    }

    /// Instance accessor over the currently loaded (unfiltered) buckets.
    var totalsByKind: [ModelKind: Int] {
        Self.totalsByKind(in: buckets)
    }

    /// Chart-facing filter: keeps every field intact and narrows only
    /// `tokensByModel` (and the per raw-model cost breakdown) to the selected
    /// family. Distinct from the private `applyFilter` used by the summary,
    /// which additionally scales the cache counters. Pure + static for unit
    /// tests.
    nonisolated static func bucketsForChart(_ buckets: [HistoryBucket], filter: HistoryFilter) -> [HistoryBucket] {
        switch filter {
        case .all:
            return buckets
        case .family(let family):
            return buckets.map { bucket in
                var b = bucket
                b.tokensByModel = bucket.tokensByModel.filter { $0.key.family == family }
                b.tokensByRawModelDetailed = bucket.tokensByRawModelDetailed
                    .filter { ModelKind(rawModel: $0.key).family == family }
                return b
            }
        }
    }

    /// Instance accessor over the loaded buckets with the active filter applied.
    var filteredBuckets: [HistoryBucket] {
        Self.bucketsForChart(buckets, filter: filter)
    }

    // MARK: - Cost estimate

    /// Merged per raw-model token breakdown across the given buckets. Pure +
    /// static so cost derivation is unit-testable without a store instance.
    nonisolated static func breakdownByRawModel(in buckets: [HistoryBucket]) -> [String: TokenBreakdown] {
        var merged: [String: TokenBreakdown] = [:]
        for bucket in buckets {
            for (raw, bd) in bucket.tokensByRawModelDetailed {
                merged[raw, default: .zero] = merged[raw, default: .zero] + bd
            }
        }
        return merged
    }

    /// Estimated cost over the currently loaded buckets with the active filter
    /// applied, priced with the best available table. The number is an estimate
    /// from list prices; the view labels it as such.
    var estimatedCost: CostEstimator.Estimate {
        CostEstimator.estimate(
            breakdownByRawModel: Self.breakdownByRawModel(in: filteredBuckets),
            pricing: pricing.currentPricing()
        )
    }

    /// Currency the cost estimate is quoted in (from the active price table).
    var costCurrencyCode: String { pricing.currentPricing().currencyCode }

    /// Estimated cost for a single bucket, priced per raw model id and folded
    /// to `ModelKind`. Drives the per-model line in the hover tooltip.
    func estimatedCost(for bucket: HistoryBucket) -> CostEstimator.Estimate {
        CostEstimator.estimate(
            breakdownByRawModel: bucket.tokensByRawModelDetailed,
            pricing: pricing.currentPricing()
        )
    }
}
