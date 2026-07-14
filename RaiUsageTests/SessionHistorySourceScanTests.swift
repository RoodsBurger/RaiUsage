import Testing
import Foundation

/// Proves `loadHistoryBySource` scans multiple roots and tags each root's
/// buckets with its `LogSource`, using temp dirs (no real ~/.claude, no ssh).
@Suite("SessionHistoryService source-tagged scan")
struct SessionHistorySourceScanTests {

    private func writeSession(in dir: URL, session: String, model: String, input: Int, output: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A timestamp a minute ago -> safely inside a 30-day window at call time.
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let line = """
        {"timestamp":"\(ts)","sessionId":"\(session)","cwd":"/tmp/\(session)","message":{"model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
        try line.write(to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
    }

    @Test("each root's buckets are keyed by its own LogSource; union sums both")
    func scansAndTagsBySource() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("raiusage-scan-\(UUID().uuidString)")
        let localDir = base.appendingPathComponent("local")
        let instanceDir = base.appendingPathComponent("instance")
        defer { try? FileManager.default.removeItem(at: base) }

        try writeSession(in: localDir, session: "localA", model: "claude-opus-4-8", input: 100, output: 200)
        try writeSession(in: instanceDir, session: "remoteA", model: "claude-sonnet-5", input: 10, output: 5)

        let instanceSource = LogSource.instance(id: UUID(), label: "prod")
        let roots = [
            ScanRoot(source: .local, url: localDir),
            ScanRoot(source: instanceSource, url: instanceDir)
        ]

        let service = SessionHistoryService()
        let bySource = try await service.loadHistoryBySource(range: .thirtyDays, roots: roots)

        // Local carries the 300 active tokens; the instance carries 15.
        let localTotal = (bySource[.local] ?? []).reduce(0) { $0 + $1.totalActive }
        let instanceTotal = (bySource[instanceSource] ?? []).reduce(0) { $0 + $1.totalActive }
        #expect(localTotal == 300)
        #expect(instanceTotal == 15)

        // The aggregator union covers both sources.
        let unioned = LogSourceAggregator.activeBuckets(bySource: bySource, sourceFilter: nil)
        #expect(unioned.reduce(0) { $0 + $1.totalActive } == 315)

        // Scoping to the instance drops the local tokens.
        let scoped = LogSourceAggregator.activeBuckets(bySource: bySource, sourceFilter: instanceSource)
        #expect(scoped.reduce(0) { $0 + $1.totalActive } == 15)
    }

    @Test("a missing instance cache dir simply contributes no buckets")
    func missingRootIsEmpty() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("raiusage-scan-\(UUID().uuidString)")
        let localDir = base.appendingPathComponent("local")
        let missingDir = base.appendingPathComponent("never-synced")
        defer { try? FileManager.default.removeItem(at: base) }

        try writeSession(in: localDir, session: "localA", model: "claude-opus-4-8", input: 1, output: 1)

        let ghost = LogSource.instance(id: UUID(), label: "offline")
        let roots = [
            ScanRoot(source: .local, url: localDir),
            ScanRoot(source: ghost, url: missingDir)
        ]
        let bySource = try await SessionHistoryService().loadHistoryBySource(range: .thirtyDays, roots: roots)
        #expect((bySource[ghost] ?? []).isEmpty)
        #expect((bySource[.local] ?? []).reduce(0) { $0 + $1.totalActive } == 2)
    }
}
