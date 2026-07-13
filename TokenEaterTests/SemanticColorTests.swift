import Testing
import SwiftUI

@Suite("Semantic Colors")
struct SemanticColorTests {

    // MARK: - RiskZone tests

    @Test("RiskZone has 3 cases")
    func riskZoneHasThreeCases() {
        #expect(RiskZone.allCases.count == 3)
    }

    @Test("RiskZone.ok has green color")
    func riskZoneOkIsGreen() {
        #expect(RiskZone.ok.color == .green)
    }

    @Test("RiskZone.warning has orange color")
    func riskZoneWarningIsOrange() {
        #expect(RiskZone.warning.color == .orange)
    }

    @Test("RiskZone.critical has red color")
    func riskZoneCriticalIsRed() {
        #expect(RiskZone.critical.color == .red)
    }

    @Test("RiskZone.ok has systemGreen NSColor")
    func riskZoneOkNSColorIsSystemGreen() {
        #expect(RiskZone.ok.nsColor == .systemGreen)
    }

    @Test("RiskZone.warning has systemOrange NSColor")
    func riskZoneWarningNSColorIsSystemOrange() {
        #expect(RiskZone.warning.nsColor == .systemOrange)
    }

    @Test("RiskZone.critical has systemRed NSColor")
    func riskZoneCriticalNSColorIsSystemRed() {
        #expect(RiskZone.critical.nsColor == .systemRed)
    }

    // MARK: - RiskZone.forPercent tests

    @Test("forPercent returns ok when at 0% with default thresholds")
    func forPercentReturnsOkAt0Percent() {
        let thresholds = UsageThresholds.default
        #expect(RiskZone.forPercent(0, thresholds: thresholds) == .ok)
    }

    @Test("forPercent returns ok when below warning threshold")
    func forPercentReturnsOkBelowWarningThreshold() {
        let thresholds = UsageThresholds.default
        #expect(RiskZone.forPercent(59, thresholds: thresholds) == .ok)
    }

    @Test("forPercent returns warning when at warning threshold")
    func forPercentReturnsWarningAtWarningThreshold() {
        let thresholds = UsageThresholds.default
        #expect(RiskZone.forPercent(60, thresholds: thresholds) == .warning)
    }

    @Test("forPercent returns warning when between warning and critical")
    func forPercentReturnsWarningBetweenThresholds() {
        let thresholds = UsageThresholds.default
        #expect(RiskZone.forPercent(70, thresholds: thresholds) == .warning)
    }

    @Test("forPercent returns critical when at critical threshold")
    func forPercentReturnsCriticalAtCriticalThreshold() {
        let thresholds = UsageThresholds.default
        #expect(RiskZone.forPercent(85, thresholds: thresholds) == .critical)
    }

    @Test("forPercent returns critical when at 100%")
    func forPercentReturnsCriticalAt100Percent() {
        let thresholds = UsageThresholds.default
        #expect(RiskZone.forPercent(100, thresholds: thresholds) == .critical)
    }

    @Test("forPercent honors custom warning threshold")
    func forPercentHonorsCustomWarningThreshold() {
        let thresholds = UsageThresholds(warningPercent: 50, criticalPercent: 80)
        #expect(RiskZone.forPercent(49, thresholds: thresholds) == .ok)
        #expect(RiskZone.forPercent(50, thresholds: thresholds) == .warning)
        #expect(RiskZone.forPercent(79, thresholds: thresholds) == .warning)
    }

    @Test("forPercent honors custom critical threshold")
    func forPercentHonorsCustomCriticalThreshold() {
        let thresholds = UsageThresholds(warningPercent: 50, criticalPercent: 80)
        #expect(RiskZone.forPercent(79, thresholds: thresholds) == .warning)
        #expect(RiskZone.forPercent(80, thresholds: thresholds) == .critical)
    }

    // MARK: - PacingZone semantic colors

    @Test("PacingZone.chill has green semanticColor")
    func pacingZoneChillIsGreen() {
        #expect(PacingZone.chill.semanticColor == .green)
    }

    @Test("PacingZone.onTrack has blue semanticColor")
    func pacingZoneOnTrackIsBlue() {
        #expect(PacingZone.onTrack.semanticColor == .blue)
    }

    @Test("PacingZone.warning has orange semanticColor")
    func pacingZoneWarningIsOrange() {
        #expect(PacingZone.warning.semanticColor == .orange)
    }

    @Test("PacingZone.hot has red semanticColor")
    func pacingZoneHotIsRed() {
        #expect(PacingZone.hot.semanticColor == .red)
    }

    @Test("PacingZone.chill has systemGreen semanticNSColor")
    func pacingZoneChillNSColorIsSystemGreen() {
        #expect(PacingZone.chill.semanticNSColor == .systemGreen)
    }

    @Test("PacingZone.onTrack has systemBlue semanticNSColor")
    func pacingZoneOnTrackNSColorIsSystemBlue() {
        #expect(PacingZone.onTrack.semanticNSColor == .systemBlue)
    }

    @Test("PacingZone.warning has systemOrange semanticNSColor")
    func pacingZoneWarningNSColorIsSystemOrange() {
        #expect(PacingZone.warning.semanticNSColor == .systemOrange)
    }

    @Test("PacingZone.hot has systemRed semanticNSColor")
    func pacingZoneHotNSColorIsSystemRed() {
        #expect(PacingZone.hot.semanticNSColor == .systemRed)
    }
}
