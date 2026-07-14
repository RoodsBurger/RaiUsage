import Testing
import Foundation

@Suite("PopoverConfig")
struct PopoverConfigTests {

    @Test("defaults match the spec")
    func defaults() {
        let config = PopoverConfig()
        #expect(config.metricOrder == [.fiveHour, .sevenDay, .opus, .sonnet, .cowork, .fable, .design])
        #expect(config.hiddenMetrics.isEmpty)
        #expect(config.showPacing == true)
        #expect(config.showSpend == true)
        #expect(config.showTimestamp == true)
    }

    @Test("popoverDefaultOrder matches the spec")
    func popoverDefaultOrder() {
        #expect(MetricID.popoverDefaultOrder == [.fiveHour, .sevenDay, .opus, .sonnet, .cowork, .fable, .design])
    }

    @Test("Codable round-trip preserves every field")
    func roundTrip() throws {
        let original = PopoverConfig(
            metricOrder: [.sevenDay, .fiveHour, .design, .sonnet, .opus, .fable, .cowork],
            hiddenMetrics: [.opus, .fable],
            showPacing: false,
            showSpend: false,
            showTimestamp: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PopoverConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("decoding an empty JSON object falls back to every field default")
    func decodeMissingKeys() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(PopoverConfig.self, from: data)
        #expect(decoded == PopoverConfig())
    }

    @Test("decoding a partial JSON object fills only the missing fields with defaults")
    func decodePartialKeys() throws {
        let data = Data(#"{"showSpend":false,"hiddenMetrics":["design"]}"#.utf8)
        let decoded = try JSONDecoder().decode(PopoverConfig.self, from: data)
        #expect(decoded.showSpend == false)
        #expect(decoded.hiddenMetrics == [.design])
        // Untouched fields still fall back to defaults.
        #expect(decoded.metricOrder == PopoverConfig().metricOrder)
        #expect(decoded.showPacing == true)
        #expect(decoded.showTimestamp == true)
    }

    // MARK: - visibleMetrics

    @Test("visibleMetrics filters out hidden metrics")
    func visibleMetricsFiltersHidden() {
        var config = PopoverConfig()
        config.hiddenMetrics = [.opus, .fable]
        let available = Set(MetricID.popoverDefaultOrder)
        #expect(config.visibleMetrics(available: available) == [.fiveHour, .sevenDay, .sonnet, .cowork, .design])
    }

    @Test("visibleMetrics filters out unavailable metrics")
    func visibleMetricsFiltersUnavailable() {
        let config = PopoverConfig()
        let available: Set<MetricID> = [.fiveHour, .sevenDay, .sonnet]
        #expect(config.visibleMetrics(available: available) == [.fiveHour, .sevenDay, .sonnet])
    }

    @Test("visibleMetrics preserves metricOrder's order, not availability order")
    func visibleMetricsPreservesOrder() {
        var config = PopoverConfig()
        config.metricOrder = [.design, .fable, .sevenDay, .fiveHour, .sonnet, .cowork, .opus]
        let available = Set(MetricID.popoverDefaultOrder)
        #expect(config.visibleMetrics(available: available) == [.design, .fable, .sevenDay, .fiveHour, .sonnet, .cowork, .opus])
    }

    @Test("visibleMetrics can be empty")
    func visibleMetricsCanBeEmpty() {
        var config = PopoverConfig()
        config.hiddenMetrics = Set(MetricID.popoverDefaultOrder)
        #expect(config.visibleMetrics(available: Set(MetricID.popoverDefaultOrder)).isEmpty)
    }

    // MARK: - Fully optional metrics

    @Test("session and weekly can both be hidden at once - no floor remains")
    func sessionAndWeeklyBothHideable() {
        var config = PopoverConfig()
        config.hiddenMetrics = [.fiveHour, .sevenDay]
        let available = Set(MetricID.popoverDefaultOrder)
        #expect(config.visibleMetrics(available: available) == [.opus, .sonnet, .cowork, .fable, .design])
    }

    // MARK: - Visibility helpers (activity metrics)

    @Test("isVisible requires presence in metricOrder AND not hidden")
    func isVisibleRequiresOrderMembership() {
        var config = PopoverConfig()
        // A default config predates the activity metrics -> not visible.
        #expect(!config.isVisible(.fiveHourActivity))
        #expect(config.isVisible(.fiveHour))
        config.hiddenMetrics = [.fiveHour]
        #expect(!config.isVisible(.fiveHour))
    }

    @Test("setVisible(true) appends a missing metric to metricOrder")
    func setVisibleAppendsMissingMetric() {
        var config = PopoverConfig()
        config.setVisible(.sevenDayActivity, true)
        #expect(config.metricOrder.last == .sevenDayActivity)
        #expect(config.isVisible(.sevenDayActivity))
        let available = Set(MetricID.popoverDefaultOrder).union([.sevenDayActivity])
        #expect(config.visibleMetrics(available: available).contains(.sevenDayActivity))
    }

    @Test("setVisible(true) never duplicates an existing metricOrder entry")
    func setVisibleNoDuplicate() {
        var config = PopoverConfig()
        config.hiddenMetrics = [.design]
        config.setVisible(.design, true)
        #expect(config.metricOrder.filter { $0 == .design }.count == 1)
        #expect(config.isVisible(.design))
    }

    @Test("setVisible(false) hides without touching the order")
    func setVisibleFalseHides() {
        var config = PopoverConfig()
        config.setVisible(.fiveHour, false)
        #expect(config.hiddenMetrics.contains(.fiveHour))
        #expect(config.metricOrder == PopoverConfig().metricOrder)
    }

    @Test("activity metrics render only when the caller marks them available")
    func activityMetricsGatedByAvailability() {
        var config = PopoverConfig()
        config.setVisible(.fiveHourActivity, true)
        // Personal plans never put the activity ids in the available set.
        #expect(!config.visibleMetrics(available: Set(MetricID.popoverDefaultOrder)).contains(.fiveHourActivity))
        let enterpriseAvailable = Set(MetricID.popoverDefaultOrder).union([.fiveHourActivity, .sevenDayActivity])
        #expect(config.visibleMetrics(available: enterpriseAvailable).contains(.fiveHourActivity))
    }

    // MARK: - Enterprise first-run defaults

    @Test("enterpriseDefault shows the design row plus both activity rows")
    func enterpriseDefaultMetrics() {
        let config = PopoverConfig.enterpriseDefault
        // Personal-availability set -> the activity rows are filtered out.
        #expect(config.visibleMetrics(available: Set(MetricID.popoverDefaultOrder)) == [.design])
        let enterpriseAvailable = Set(MetricID.popoverDefaultOrder).union([.fiveHourActivity, .sevenDayActivity])
        #expect(config.visibleMetrics(available: enterpriseAvailable) == [.design, .fiveHourActivity, .sevenDayActivity])
        #expect(config.metricOrder == PopoverConfig().metricOrder + [.fiveHourActivity, .sevenDayActivity])
    }

    @Test("enterpriseDefault keeps spend and timestamp on, pacing off")
    func enterpriseDefaultSections() {
        let config = PopoverConfig.enterpriseDefault
        #expect(config.showSpend == true)
        #expect(config.showTimestamp == true)
        #expect(config.showPacing == false)
    }
}
