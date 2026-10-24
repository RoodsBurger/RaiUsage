import Foundation

// MARK: - Range

/// Time window the History view looks back over. The 24h view buckets by hour
/// so the chart still has 24 data points; everything else buckets by day.
enum HistoryRange: String, CaseIterable, Codable, Sendable {
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"

    var labelKey: String {
        "history.range.\(rawValue)"
    }

    /// Number of seconds covered by the range.
    var seconds: TimeInterval {
        switch self {
        case .twentyFourHours: return 24 * 3600
        case .sevenDays:       return 7 * 86_400
        case .thirtyDays:      return 30 * 86_400
        case .ninetyDays:      return 90 * 86_400
        }
    }

    /// True when the range is short enough to be displayed at hourly resolution.
    var isHourly: Bool { self == .twentyFourHours }

    /// Bucket size used when aggregating raw events. The cache stores hourly
    /// counts as well, so daily ranges simply roll up multiple hourly buckets.
    var bucketSeconds: TimeInterval {
        isHourly ? 3600 : 86_400
    }
}

// MARK: - Model classification

/// Model identity used for chart colouring, legend labels and filter chips:
/// a family plus the version parsed from the raw JSONL model id
/// (`claude-opus-5-5` -> Opus 5.5, `claude-fable-5-1[1m]` -> Fable 5.1). The
/// version is read from the id itself, so new releases get a correct label
/// without code changes. Bare aliases (`opus`, `sonnet`) carry no version.
struct ModelKind: Hashable, Sendable, Comparable {
    let family: ModelFamily
    /// Dotted version ("5.5"), nil when the raw id names no version.
    let version: String?

    init(family: ModelFamily, version: String? = nil) {
        self.family = family
        self.version = family == .other ? nil : version
    }

    init(rawModel: String) {
        let lower = rawModel.lowercased()
        guard let family = ModelFamily.allCases.first(where: { $0 != .other && lower.contains($0.rawValue) }),
              let range = lower.range(of: family.rawValue) else {
            self.init(family: .other)
            return
        }
        self.init(family: family, version: Self.version(in: lower[range.upperBound...]))
    }

    static let other = ModelKind(family: .other)

    var displayName: String {
        guard let version else { return family.displayName }
        return "\(family.displayName) \(version)"
    }

    /// Chart stacking order: family rank first, then older versions below newer.
    static func < (lhs: ModelKind, rhs: ModelKind) -> Bool {
        if lhs.family != rhs.family { return lhs.family.stackRank < rhs.family.stackRank }
        return lhs.versionComponents.lexicographicallyPrecedes(rhs.versionComponents)
    }

    private var versionComponents: [Int] {
        (version ?? "").split(separator: ".").compactMap { Int($0) }
    }

    /// Reads up to the first non-version piece after the family token: 1-2 digit
    /// groups split by `-` or `.`, so `-4-5-20251001` yields "4.5" and `-5[1m]` "5".
    private static func version(in tail: Substring) -> String? {
        guard let first = tail.first, first == "-" || first == "." else { return nil }
        var parts: [Substring] = []
        for piece in tail.split(whereSeparator: { $0 == "-" || $0 == "." }) {
            let digits = piece.prefix(while: \.isASCII).prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 2 else { break }
            parts.append(digits)
            if digits.count < piece.count { break }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }
}

/// Encoded as a single `family` or `family-version` string so cached buckets stay compact.
extension ModelKind: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: "-", maxSplits: 1).map(String.init)
        guard let family = parts.first.flatMap(ModelFamily.init(rawValue:)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown model kind \(raw)"))
        }
        self.init(family: family, version: parts.count > 1 ? parts[1] : nil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(version.map { "\(family.rawValue)-\($0)" } ?? family.rawValue)
    }
}

enum ModelFamily: String, CaseIterable, Codable, Hashable, Sendable {
    // Declaration order drives the History filter-chip row (rendered right after
    // the "All" chip). Fable leads as the top tier, then Opus / Sonnet / Haiku,
    // with `.other` last as the catch-all.
    case fable, opus, sonnet, haiku, other

    var displayName: String {
        switch self {
        case .fable:  return "Fable"
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .other:  return "Other"
        }
    }

    /// Bottom-to-top position in the stacked chart (`.other` stays on top as the catch-all).
    var stackRank: Int {
        switch self {
        case .haiku:  return 0
        case .opus:   return 1
        case .fable:  return 2
        case .sonnet: return 3
        case .other:  return 4
        }
    }
}

// MARK: - Filter

enum HistoryFilter: Hashable, Sendable {
    case all
    case family(ModelFamily)

    var isAll: Bool { if case .all = self { true } else { false } }
}

// MARK: - Token breakdown

/// Per-model split of the four billable token classes, used to price usage.
/// Kept separate from the aggregate `HistoryBucket` counters so cost can be
/// computed per raw model id (pricing differs by exact version, e.g.
/// `sonnet-5` vs `sonnet-4-6`).
struct TokenBreakdown: Codable, Sendable, Equatable, Hashable {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheCreate: Int

    static let zero = TokenBreakdown(input: 0, output: 0, cacheRead: 0, cacheCreate: 0)

    /// Element-wise sum, used when merging buckets across files.
    static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheCreate: lhs.cacheCreate + rhs.cacheCreate
        )
    }
}

// MARK: - Aggregates

/// Per-bucket aggregate produced by `SessionHistoryService`. The bucket can be
/// either an hour (24h range) or a day (everything else); the consumer decides
/// based on the active `HistoryRange`.
struct HistoryBucket: Identifiable, Codable, Sendable {
    /// Bucket start instant, normalised to the calendar boundary (start of day
    /// or start of hour depending on resolution).
    let date: Date
    /// Token totals broken down by model so the chart can stack segments and
    /// the filter chips can sum a single family.
    var tokensByModel: [ModelKind: Int]
    /// Active tokens (input + output) per project path. Used for the "top
    /// project" chip and any future project drill-down.
    var tokensByProject: [String: Int]
    /// Distinct session count -> drives "avg / session" stat.
    var sessionsCount: Int
    /// Accumulated raw counters for cache hit rate calculation.
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreateTokens: Int
    /// Per raw-model-id token split, keyed by the exact model string from the
    /// JSONL so cost can price each version separately. Defaulted so the
    /// synthesized memberwise init stays source-compatible with the existing
    /// call sites; the cache version bump discards any pre-existing cache that
    /// lacks the field. Only populated by the parser (empty in the summary /
    /// filter paths that don't need it).
    var tokensByRawModelDetailed: [String: TokenBreakdown] = [:]

    var id: Date { date }

    var totalActive: Int {
        tokensByModel.values.reduce(0, +)
    }

    var totalIncludingCache: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens
    }

    var cachedTokens: Int {
        cacheReadTokens + cacheCreateTokens
    }

    static let empty = HistoryBucket(
        date: .distantPast,
        tokensByModel: [:],
        tokensByProject: [:],
        sessionsCount: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreateTokens: 0
    )

    static func merging(_ lhs: HistoryBucket, _ rhs: HistoryBucket, date: Date) -> HistoryBucket {
        var byModel = lhs.tokensByModel
        for (k, v) in rhs.tokensByModel { byModel[k, default: 0] += v }
        var byProject = lhs.tokensByProject
        for (k, v) in rhs.tokensByProject { byProject[k, default: 0] += v }
        var byRaw = lhs.tokensByRawModelDetailed
        for (k, v) in rhs.tokensByRawModelDetailed { byRaw[k, default: .zero] = byRaw[k, default: .zero] + v }
        return HistoryBucket(
            date: date,
            tokensByModel: byModel,
            tokensByProject: byProject,
            sessionsCount: lhs.sessionsCount + rhs.sessionsCount,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreateTokens: lhs.cacheCreateTokens + rhs.cacheCreateTokens,
            tokensByRawModelDetailed: byRaw
        )
    }
}

// MARK: - Summary

/// One-line snapshot of the visible range, used to fill the hero card and the
/// footer chips. Computed by `HistoryStore` from the current bucket array
/// after applying the model filter.
struct HistorySummary: Sendable {
    let totalActive: Int
    let totalCached: Int
    /// Active tokens of the equivalent previous period (e.g. `last 7d` -> the
    /// 7d before that), for the hero delta percentage.
    let previousPeriodActive: Int
    let heaviestBucket: HistoryBucket?
    let topModel: (kind: ModelKind, tokens: Int)?
    let topProject: (path: String, tokens: Int)?
    let sessionsCount: Int
    /// Ranked top-5 lists behind the collapsed chips, surfaced when the footer
    /// is expanded. Ordered biggest first; may hold fewer than 5.
    let topProjects: [(path: String, tokens: Int)]
    let topModels: [(kind: ModelKind, tokens: Int)]
    let heaviestDays: [HistoryBucket]

    var totalIncludingCache: Int { totalActive + totalCached }

    var cacheHitRate: Double {
        let denom = totalIncludingCache
        return denom == 0 ? 0 : Double(totalCached) / Double(denom)
    }

    var averagePerSession: Int {
        sessionsCount == 0 ? 0 : totalActive / sessionsCount
    }

    var deltaPercent: Double? {
        guard previousPeriodActive > 0 else { return nil }
        return (Double(totalActive) - Double(previousPeriodActive)) / Double(previousPeriodActive) * 100
    }

    static let empty = HistorySummary(
        totalActive: 0,
        totalCached: 0,
        previousPeriodActive: 0,
        heaviestBucket: nil,
        topModel: nil,
        topProject: nil,
        sessionsCount: 0,
        topProjects: [],
        topModels: [],
        heaviestDays: []
    )
}

// MARK: - Cache entry

/// Per-file cache entry persisted to disk. The aggregator skips re-parsing a
/// file when its mtime matches the cached value -> repeated opens of the
/// History view stay sub-100ms after the first scan.
struct HistoryFileCacheEntry: Codable, Sendable {
    let path: String
    let mtime: Date
    let buckets: [HistoryBucket]
    /// Distinct session ids seen in this file. Used by the merger to compute
    /// `sessionsCount` correctly when aggregating across files (one session
    /// might span multiple JSONL lines but the count is per session, not per
    /// line).
    let sessionIds: [String]
}

struct HistoryCache: Codable, Sendable {
    /// Schema version. Bump when the cache shape changes so old caches are
    /// thrown away cleanly instead of decoded into garbage.
    var version: Int
    var entries: [String: HistoryFileCacheEntry]

    /// Caches with any other version are discarded and re-scanned, so stored
    /// `ModelKind` keys always match the current version-parsing rules.
    static let currentVersion = 4
    static let empty = HistoryCache(version: currentVersion, entries: [:])
}
