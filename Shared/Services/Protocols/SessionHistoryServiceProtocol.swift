import Foundation

/// Reads `~/.claude/projects/**/*.jsonl` (and any configured remote-instance
/// caches) and produces aggregated history buckets. Implementations must be
/// cancellable and persist a cache so the repeated UI-driven loads stay cheap.
protocol SessionHistoryServiceProtocol: Sendable {
    /// Loads buckets covering the requested range from the LOCAL projects dir
    /// only. Implementations should honour `Task.checkCancellation()` so a fast
    /// range switch doesn't waste CPU on an obsolete scan.
    func loadHistory(range: HistoryRange) async throws -> [HistoryBucket]

    /// Loads the equivalent previous-period total active tokens for the LOCAL
    /// dir (used by the hero delta). Returns 0 if there is no older data.
    func loadPreviousPeriodActiveTokens(range: HistoryRange) async throws -> Int

    /// Scans every `ScanRoot` and returns buckets keyed by the root's
    /// `LogSource`, so the caller can filter by source without re-scanning.
    func loadHistoryBySource(range: HistoryRange, roots: [ScanRoot]) async throws -> [LogSource: [HistoryBucket]]

    /// Previous-period active tokens per source, for a source-scoped hero delta.
    func loadPreviousPeriodActiveTokensBySource(range: HistoryRange, roots: [ScanRoot]) async throws -> [LogSource: Int]
}
