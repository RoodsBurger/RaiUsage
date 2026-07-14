import Foundation

/// Pure merge / filter math over source-keyed history buckets, shared by
/// `HistoryStore` and `ActivityStore` so a `sourceFilter` selection resolves
/// identically in both (no I/O, fully unit-testable).
enum LogSourceAggregator {

    /// Buckets for the active source selection: a single source's buckets when
    /// `sourceFilter` is set, otherwise the union across every source (session
    /// files are unique per machine, so a plain per-date merge is correct — no
    /// dedup needed).
    static func activeBuckets(
        bySource: [LogSource: [HistoryBucket]],
        sourceFilter: LogSource?
    ) -> [HistoryBucket] {
        if let sourceFilter {
            return (bySource[sourceFilter] ?? []).sorted { $0.date < $1.date }
        }
        return mergeBuckets(Array(bySource.values))
    }

    /// Merges several bucket arrays by bucket date, summing overlapping dates
    /// via `HistoryBucket.merging`.
    static func mergeBuckets(_ arrays: [[HistoryBucket]]) -> [HistoryBucket] {
        var combined: [Date: HistoryBucket] = [:]
        for array in arrays {
            for bucket in array {
                if let existing = combined[bucket.date] {
                    combined[bucket.date] = HistoryBucket.merging(existing, bucket, date: bucket.date)
                } else {
                    combined[bucket.date] = bucket
                }
            }
        }
        return combined.values.sorted { $0.date < $1.date }
    }

    /// Previous-period active tokens for the active selection: one source's
    /// value when filtered, otherwise the sum across all sources.
    static func previousActive(
        previousBySource: [LogSource: Int],
        sourceFilter: LogSource?
    ) -> Int {
        if let sourceFilter {
            return previousBySource[sourceFilter] ?? 0
        }
        return previousBySource.values.reduce(0, +)
    }

    /// Scan roots for a set of instances: the local projects dir tagged
    /// `.local`, plus each ENABLED instance's cache dir tagged `.instance`.
    static func buildRoots(instances: [RemoteInstance]) -> [ScanRoot] {
        var roots = [ScanRoot(source: .local, url: SessionHistoryService.localProjectsURL)]
        for instance in instances where instance.enabled {
            roots.append(ScanRoot(
                source: .instance(id: instance.id, label: instance.displayLabel),
                url: RemoteLogCache.directory(forHost: instance.host)
            ))
        }
        return roots
    }
}
