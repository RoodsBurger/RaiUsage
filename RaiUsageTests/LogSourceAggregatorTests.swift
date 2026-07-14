import Testing
import Foundation

@Suite("LogSourceAggregator source-tagged filtering")
struct LogSourceAggregatorTests {

    private static func bucket(
        _ y: Int, _ m: Int, _ d: Int,
        byModel: [ModelKind: Int],
        sessions: Int = 1
    ) -> HistoryBucket {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        return HistoryBucket(
            date: date,
            tokensByModel: byModel,
            tokensByProject: [:],
            sessionsCount: sessions,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreateTokens: 0
        )
    }

    private static let instanceA = LogSource.instance(id: UUID(), label: "prod")
    private static let instanceB = LogSource.instance(id: UUID(), label: "training")

    private static var sample: [LogSource: [HistoryBucket]] {
        [
            .local: [bucket(2026, 7, 1, byModel: [.opus48: 100], sessions: 2)],
            instanceA: [bucket(2026, 7, 1, byModel: [.opus48: 40, .sonnet: 10], sessions: 1)],
            instanceB: [bucket(2026, 7, 2, byModel: [.haiku: 5], sessions: 3)]
        ]
    }

    @Test("nil source filter unions every source, merging same-date buckets")
    func nilFilterUnions() {
        let merged = LogSourceAggregator.activeBuckets(bySource: Self.sample, sourceFilter: nil)
        // Two distinct dates: Jul 1 (local + instanceA merged) and Jul 2.
        #expect(merged.count == 2)
        let jul1 = merged.first { Calendar(identifier: .gregorian).component(.day, from: $0.date) == 1 }
        #expect(jul1?.tokensByModel[.opus48] == 140)   // 100 (local) + 40 (A)
        #expect(jul1?.tokensByModel[.sonnet] == 10)
        #expect(jul1?.sessionsCount == 3)              // 2 + 1
        let total = merged.reduce(0) { $0 + $1.totalActive }
        #expect(total == 155)                          // 100 + 40 + 10 + 5
    }

    @Test("selecting .local returns only this Mac's buckets")
    func localOnly() {
        let out = LogSourceAggregator.activeBuckets(bySource: Self.sample, sourceFilter: .local)
        #expect(out.count == 1)
        #expect(out.first?.tokensByModel[.opus48] == 100)
        #expect(out.first?.tokensByModel[.sonnet] == nil)
    }

    @Test("selecting an instance returns only that instance's buckets")
    func instanceOnly() {
        let out = LogSourceAggregator.activeBuckets(bySource: Self.sample, sourceFilter: Self.instanceA)
        #expect(out.count == 1)
        #expect(out.first?.tokensByModel[.opus48] == 40)
        #expect(out.reduce(0) { $0 + $1.totalActive } == 50)
    }

    @Test("an unknown / removed source yields no buckets")
    func unknownSourceEmpty() {
        let ghost = LogSource.instance(id: UUID(), label: "gone")
        #expect(LogSourceAggregator.activeBuckets(bySource: Self.sample, sourceFilter: ghost).isEmpty)
    }

    @Test("previousActive sums all sources when unfiltered, one when scoped")
    func previousActiveScoping() {
        let previous: [LogSource: Int] = [.local: 100, Self.instanceA: 40, Self.instanceB: 5]
        #expect(LogSourceAggregator.previousActive(previousBySource: previous, sourceFilter: nil) == 145)
        #expect(LogSourceAggregator.previousActive(previousBySource: previous, sourceFilter: .local) == 100)
        #expect(LogSourceAggregator.previousActive(previousBySource: previous, sourceFilter: Self.instanceA) == 40)
        let ghost = LogSource.instance(id: UUID(), label: "gone")
        #expect(LogSourceAggregator.previousActive(previousBySource: previous, sourceFilter: ghost) == 0)
    }

    @Test("buildRoots always includes local and only ENABLED instances")
    func buildRootsFiltersDisabled() {
        let enabled = RemoteInstance(host: "10.0.0.1", user: "ubuntu", enabled: true, nickname: "on")
        let disabled = RemoteInstance(host: "10.0.0.2", user: "ubuntu", enabled: false, nickname: "off")
        let roots = LogSourceAggregator.buildRoots(instances: [enabled, disabled])
        let sources = roots.map(\.source)
        #expect(sources.contains(.local))
        #expect(sources.contains(.instance(id: enabled.id, label: "on")))
        #expect(!sources.contains(.instance(id: disabled.id, label: "off")))
        #expect(roots.count == 2)
        // The instance root points at its per-host cache dir.
        let instanceRoot = roots.first { $0.source == .instance(id: enabled.id, label: "on") }
        #expect(instanceRoot?.url.path.contains("remote-logs") == true)
        #expect(instanceRoot?.url.lastPathComponent == "10.0.0.1")
    }
}
