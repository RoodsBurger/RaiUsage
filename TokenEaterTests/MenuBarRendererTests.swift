import Testing
import Foundation
import AppKit

/// Regression coverage for `MenuBarRenderer.gaugeColor`'s smart-mode path,
/// expressed against validated (u, e) scenarios from `SmartColorTests` so the
/// expected zone is grounded in the risk model rather than hand-picked.
/// `gaugeColor` takes its inputs directly (no `RenderData`), so this suite is
/// untouched by the menu-bar engine rewrite.
@Suite("MenuBarRenderer.gaugeColor smart-mode regression")
struct MenuBarRendererSmartRegressionTests {

    private let thresholds = UsageThresholds.default // warning: 60, critical: 85
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let window: TimeInterval = 5 * 3600 // 300 min

    private func reset(_ minutesAway: Double) -> Date {
        now.addingTimeInterval(minutesAway * 60)
    }

    private func color(_ utilization: Int, minutesRemaining: Double) -> NSColor {
        MenuBarRenderer.gaugeColor(
            pct: utilization,
            resetDate: reset(minutesRemaining),
            windowDuration: window,
            monochrome: false,
            smartEnabled: true,
            thresholds: thresholds,
            pacingMargin: 10,
            smartColorProfile: .balanced,
            now: now
        )
    }

    @Test("100% utilization is always critical, regardless of time remaining")
    func hardCapAlwaysCritical() {
        #expect(color(100, minutesRemaining: 20) == RiskZone.critical.nsColor)
        #expect(color(100, minutesRemaining: 240) == RiskZone.critical.nsColor)
    }

    @Test("95% with 5 min remaining is critical (matches SmartColorTests u=0.95 e=0.983 -> hot)")
    func criticalLowTime() {
        #expect(color(95, minutesRemaining: 5) == RiskZone.critical.nsColor)
    }

    @Test("low utilization near reset stays ok")
    func lowUtilizationStaysOk() {
        #expect(color(30, minutesRemaining: 15) == RiskZone.ok.nsColor)
    }

    @Test("80% used at 50% elapsed is critical (matches SmartColorTests u=0.80 e=0.50 -> hot)")
    func highUtilizationAheadOfPaceEscalates() {
        // e=0.50 on a 300min window -> 150min remaining.
        #expect(color(80, minutesRemaining: 150) == RiskZone.critical.nsColor)
    }

    @Test("72% with calm pacing stays ok (matches SmartColorTests u=0.72 e=0.84 -> chill)")
    func highAbsoluteCalmPacingStaysOk() {
        // e=0.84 on a 300min window -> 48min remaining.
        #expect(color(72, minutesRemaining: 48) == RiskZone.ok.nsColor)
    }
}

/// Covers the windowless-metric colouring rule that keeps Extra Credits in
/// agreement across the menu bar, popover, and dashboard: Smart Color
/// is time-aware, so a metric with no reset window must use the static
/// threshold ladder instead of the profile-based absolute-risk colour.
/// `gaugeColor` is untouched by the engine rewrite, so this suite is too.
@Suite("MenuBarRenderer.gaugeColor (windowless fallback)")
struct MenuBarGaugeColorTests {

    private let thresholds = UsageThresholds.default // warning 60, critical 85
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("windowless metric uses the threshold ladder even when Smart Color is on")
    func windowlessUsesThresholds() {
        let observed = MenuBarRenderer.gaugeColor(
            pct: 67, resetDate: nil, windowDuration: 0,
            monochrome: false, smartEnabled: true,
            thresholds: thresholds,
            pacingMargin: 10, smartColorProfile: .balanced, now: now
        )
        #expect(observed == RiskZone.forPercent(67, thresholds: thresholds).nsColor)
        let risk = SmartColor.risk(
            utilization: 67, resetDate: nil, windowDuration: 0,
            pacingMargin: 10, now: now, profile: .balanced
        )
        let smartWindowless = SmartColor.riskZone(forRisk: risk, params: SmartColorProfile.balanced.parameters).nsColor
        #expect(observed != smartWindowless)
    }

    @Test("windowed metric still uses Smart Color when enabled")
    func windowedUsesSmart() {
        let reset = now.addingTimeInterval(180 * 60) // 3h left on a 5h window
        let observed = MenuBarRenderer.gaugeColor(
            pct: 80, resetDate: reset, windowDuration: 5 * 3600,
            monochrome: false, smartEnabled: true,
            thresholds: thresholds,
            pacingMargin: 10, smartColorProfile: .balanced, now: now
        )
        let risk = SmartColor.risk(
            utilization: 80, resetDate: reset, windowDuration: 5 * 3600,
            pacingMargin: 10, now: now, profile: .balanced
        )
        let expectedSmart = SmartColor.riskZone(forRisk: risk, params: SmartColorProfile.balanced.parameters).nsColor
        #expect(observed == expectedSmart)
    }

    @Test("smart disabled always uses the threshold ladder")
    func smartDisabledUsesThresholds() {
        let reset = now.addingTimeInterval(180 * 60)
        let observed = MenuBarRenderer.gaugeColor(
            pct: 80, resetDate: reset, windowDuration: 5 * 3600,
            monochrome: false, smartEnabled: false,
            thresholds: thresholds,
            pacingMargin: 10, smartColorProfile: .balanced, now: now
        )
        #expect(observed == RiskZone.forPercent(80, thresholds: thresholds).nsColor)
    }

    @Test("monochrome wins over everything")
    func monochromeWins() {
        let observed = MenuBarRenderer.gaugeColor(
            pct: 67, resetDate: nil, windowDuration: 0,
            monochrome: true, smartEnabled: true,
            thresholds: thresholds,
            pacingMargin: 10, smartColorProfile: .balanced, now: now
        )
        #expect(observed == NSColor.labelColor)
    }
}

/// Shared factory for `MenuBarRenderer.RenderData` in the buildLine/imaging
/// suites below - a fully-populated, deterministic baseline (threshold mode,
/// not smart) with every override a test needs exposed as a parameter.
private func makeRenderData(
    pinned: [PinnedMetricConfig] = [.init(id: .fiveHour, prefix: .none), .init(id: .sevenDay, prefix: .none)],
    displayMode: MenuBarDisplayMode = .all,
    rotateSeconds: Int = 5,
    colorMode: MenuBarColorMode = .risk,
    showIcon: Bool = true,
    separator: String = "|",
    fixedWidth: Bool = false,
    rotateIndex: Int = 0,
    hasConfig: Bool = true,
    hasError: Bool = false,
    smartColorEnabled: Bool = false,
    fiveHourPct: Int = 30,
    sevenDayPct: Int = 30,
    sonnetPct: Int = 30,
    designPct: Int = 30,
    fablePct: Int = 30,
    extraCreditsPct: Int = 30,
    hasFiveHourBucket: Bool = true,
    hasWeeklyPacing: Bool = true,
    hasSessionPacing: Bool = true,
    hasDesign: Bool = true,
    hasFable: Bool = true,
    hasExtraCredits: Bool = true,
    sessionPacingDelta: Int = 0,
    sessionPacingZone: PacingZone = .onTrack,
    weeklyPacingDelta: Int = 0,
    weeklyPacingZone: PacingZone = .onTrack,
    extraCreditsUsedMinorUnits: Double = 4200,
    extraCreditsCurrency: String = "USD",
    outageActive: Bool = false,
    outageHealth: VendorHealth = .healthy,
    nextPollSeconds: Int? = nil
) -> MenuBarRenderer.RenderData {
    MenuBarRenderer.RenderData(
        menuBarConfig: MenuBarConfig(
            pinned: pinned,
            displayMode: displayMode,
            rotateSeconds: rotateSeconds,
            colorMode: colorMode,
            showIcon: showIcon,
            separator: separator,
            fixedWidth: fixedWidth
        ),
        rotateIndex: rotateIndex,
        hasConfig: hasConfig,
        hasError: hasError,
        thresholds: .default,
        smartColorEnabled: smartColorEnabled,
        smartColorProfile: .balanced,
        pacingMargin: 10,
        fiveHourPct: fiveHourPct,
        sevenDayPct: sevenDayPct,
        sonnetPct: sonnetPct,
        designPct: designPct,
        fablePct: fablePct,
        extraCreditsPct: extraCreditsPct,
        hasFiveHourBucket: hasFiveHourBucket,
        hasWeeklyPacing: hasWeeklyPacing,
        hasSessionPacing: hasSessionPacing,
        hasDesign: hasDesign,
        hasFable: hasFable,
        hasExtraCredits: hasExtraCredits,
        fiveHourResetDate: nil,
        sevenDayResetDate: nil,
        sonnetResetDate: nil,
        designResetDate: nil,
        fableResetDate: nil,
        fiveHourReset: "1h39",
        sevenDayReset: "3d",
        sonnetReset: "3d",
        designReset: "3d",
        fableReset: "3d",
        sessionPacingDelta: sessionPacingDelta,
        sessionPacingZone: sessionPacingZone,
        weeklyPacingDelta: weeklyPacingDelta,
        weeklyPacingZone: weeklyPacingZone,
        sessionPacingDisplayMode: .dotDelta,
        weeklyPacingDisplayMode: .dotDelta,
        extraCreditsUsedMinorUnits: extraCreditsUsedMinorUnits,
        extraCreditsCurrency: extraCreditsCurrency,
        outageActive: outageActive,
        outageHealth: outageHealth,
        nextPollSeconds: nextPollSeconds
    )
}

@Suite("MenuBarRenderer.buildLine")
struct MenuBarBuildLineTests {

    @Test("all mode renders every visible pin in pinned order, separator-joined")
    func allModeOrderAndSeparator() {
        let data = makeRenderData(
            pinned: [
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            ],
            displayMode: .all,
            separator: "|",
            fiveHourPct: 12,
            sevenDayPct: 77
        )
        let line = MenuBarRenderer.buildLine(data: data)
        #expect(line.string == "12% | 77%")
    }

    @Test("all mode respects a custom separator")
    func allModeCustomSeparator() {
        let data = makeRenderData(
            pinned: [
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            ],
            displayMode: .all,
            separator: "\u{2022}",
            fiveHourPct: 5,
            sevenDayPct: 6
        )
        let line = MenuBarRenderer.buildLine(data: data)
        #expect(line.string == "5% \u{2022} 6%")
    }

    @Test("highestRisk picks the pin whose zone is riskiest")
    func highestRiskPicksMaxZone() {
        // Threshold mode (smartColorEnabled: false): warning 60, critical 85.
        // fiveHour=30 -> ok, sevenDay=90 -> critical. sevenDay must win.
        let data = makeRenderData(
            pinned: [
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            ],
            displayMode: .highestRisk,
            fiveHourPct: 30,
            sevenDayPct: 90
        )
        let line = MenuBarRenderer.buildLine(data: data)
        #expect(line.string == "90%")
    }

    @Test("highestRisk ties keep pinned order (first pin wins)")
    func highestRiskTiesKeepPinnedOrder() {
        let data = makeRenderData(
            pinned: [
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
            ],
            displayMode: .highestRisk,
            fiveHourPct: 90,
            sevenDayPct: 90
        )
        let line = MenuBarRenderer.buildLine(data: data)
        // Both are critical (90% >= 85 threshold); sevenDay is first in `pinned`.
        #expect(line.string == "90%")
        // Disambiguate which metric actually rendered via distinct percentages.
        let reordered = makeRenderData(
            pinned: [
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
            ],
            displayMode: .highestRisk,
            fiveHourPct: 99,
            sevenDayPct: 86
        )
        // Both still critical (>= 85), tie keeps pinned order -> sevenDay (86%), not fiveHour (99%).
        #expect(MenuBarRenderer.buildLine(data: reordered).string == "86%")
    }

    @Test("rotate wraps the index by the visible pin count")
    func rotateWrapsByIndex() {
        let pins: [PinnedMetricConfig] = [
            .init(id: .fiveHour, prefix: .none, value: .percentUsed),
            .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            .init(id: .sonnet, prefix: .none, value: .percentUsed),
        ]
        let values = [0: "11%", 1: "22%", 2: "33%", 3: "11%", 4: "22%"]
        for (index, expected) in values {
            let data = makeRenderData(
                pinned: pins,
                displayMode: .rotate,
                rotateIndex: index,
                fiveHourPct: 11, sevenDayPct: 22, sonnetPct: 33
            )
            #expect(MenuBarRenderer.buildLine(data: data).string == expected, "index \(index)")
        }
    }

    @Test("dollars value style renders only for extraCredits")
    func dollarsOnlyForExtraCredits() {
        let ecData = makeRenderData(
            pinned: [.init(id: .extraCredits, prefix: .none, value: .dollars)],
            displayMode: .all,
            extraCreditsUsedMinorUnits: 4200,
            extraCreditsCurrency: "USD"
        )
        let ecLine = MenuBarRenderer.buildLine(data: ecData).string
        #expect(ecLine.hasPrefix("$"))
        #expect(!ecLine.contains("%"))

        // A non-extraCredits pin with `.dollars` set (never offered by the UI,
        // but decodable) falls back to a plain percentage instead.
        let fiveHourData = makeRenderData(
            pinned: [.init(id: .fiveHour, prefix: .none, value: .dollars)],
            displayMode: .all,
            fiveHourPct: 42
        )
        #expect(MenuBarRenderer.buildLine(data: fiveHourData).string == "42%")
    }

    @Test("percentRemaining is 100 minus the used percentage")
    func percentRemaining() {
        let data = makeRenderData(
            pinned: [.init(id: .fiveHour, prefix: .none, value: .percentRemaining)],
            displayMode: .all,
            fiveHourPct: 30
        )
        #expect(MenuBarRenderer.buildLine(data: data).string == "70%")
    }

    @Test("percentRemaining clamps at 0 when used exceeds 100")
    func percentRemainingClamps() {
        let data = makeRenderData(
            pinned: [.init(id: .fiveHour, prefix: .none, value: .percentRemaining)],
            displayMode: .all,
            fiveHourPct: 140
        )
        #expect(MenuBarRenderer.buildLine(data: data).string == "0%")
    }

    @Test("monochrome ignores risk zones - no zone color renders, values use labelColor")
    func monochromeIgnoresZones() {
        let data = makeRenderData(
            pinned: [
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            ],
            displayMode: .all,
            colorMode: .monochrome,
            fiveHourPct: 10,   // would be ok (green) in risk mode
            sevenDayPct: 95    // would be critical (red) in risk mode
        )
        let line = MenuBarRenderer.buildLine(data: data)
        var colors = Set<NSColor>()
        line.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        // The separator itself is intentionally a neutral gray in both color
        // modes (never zone-colored), so this checks for the *absence* of
        // zone colors rather than asserting every span is exactly labelColor.
        #expect(!colors.contains(RiskZone.ok.nsColor))
        #expect(!colors.contains(RiskZone.critical.nsColor))
        #expect(colors.contains(NSColor.labelColor))
    }

    @Test("risk color mode uses distinct colors for distinct zones")
    func riskModeUsesZoneColors() {
        let data = makeRenderData(
            pinned: [
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            ],
            displayMode: .all,
            colorMode: .risk,
            fiveHourPct: 10,   // ok
            sevenDayPct: 95    // critical
        )
        let line = MenuBarRenderer.buildLine(data: data)
        var colors = Set<NSColor>()
        line.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        #expect(colors.contains(RiskZone.ok.nsColor))
        #expect(colors.contains(RiskZone.critical.nsColor))
    }

    @Test("no visible pins renders an empty line")
    func emptyWhenNothingVisible() {
        let data = makeRenderData(
            pinned: [.init(id: .design, prefix: .none)],
            hasDesign: false
        )
        #expect(MenuBarRenderer.buildLine(data: data).length == 0)
    }
}

@Suite("MenuBarRenderer.fixedWidthMeasurement")
struct MenuBarFixedWidthTests {

    @Test("adding a pin never shrinks the worst-case width (all mode)")
    func monotonicInAllMode() {
        let onePin = makeRenderData(
            pinned: [.init(id: .fiveHour, prefix: .none, value: .percentUsed)],
            displayMode: .all,
            fixedWidth: true
        )
        let twoPins = makeRenderData(
            pinned: [
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            ],
            displayMode: .all,
            fixedWidth: true
        )
        #expect(MenuBarRenderer.fixedWidthMeasurement(data: twoPins) >= MenuBarRenderer.fixedWidthMeasurement(data: onePin))
    }

    @Test("adding a pin never shrinks the worst-case width (rotate mode)")
    func monotonicInRotateMode() {
        let onePin = makeRenderData(
            pinned: [.init(id: .fiveHour, prefix: .none, value: .percentUsed)],
            displayMode: .rotate,
            fixedWidth: true
        )
        let twoPins = makeRenderData(
            pinned: [
                .init(id: .fiveHour, prefix: .none, value: .percentUsed),
                .init(id: .sevenDay, prefix: .none, value: .percentUsed),
            ],
            displayMode: .rotate,
            fixedWidth: true
        )
        #expect(MenuBarRenderer.fixedWidthMeasurement(data: twoPins) >= MenuBarRenderer.fixedWidthMeasurement(data: onePin))
    }

    @Test("worst-case width is at least as wide as the natural rendered line")
    func worstCaseAtLeastNatural() {
        let data = makeRenderData(
            pinned: [.init(id: .fiveHour, prefix: .none, value: .percentUsed)],
            displayMode: .all,
            fixedWidth: true,
            fiveHourPct: 4 // narrow "4%" - worst case "100%" must be >= this
        )
        let naturalWidth = MenuBarRenderer.buildLine(data: data).size().width
        #expect(MenuBarRenderer.fixedWidthMeasurement(data: data) >= naturalWidth)
    }
}

@Suite("MenuBarRenderer.outageBadge")
struct MenuBarOutageBadgeTests {

    @Test("outage badge widens the rendered image vs. no badge")
    func outageBadgeRenders() {
        let base = makeRenderData(outageActive: false)
        let badged = makeRenderData(outageActive: true, outageHealth: .down, nextPollSeconds: 65)

        let baseImg = MenuBarRenderer.renderUncached(base)
        let badgedImg = MenuBarRenderer.renderUncached(badged)

        #expect(badgedImg.isTemplate == false)
        #expect(badgedImg.size.width > baseImg.size.width)
    }

    @Test("pinned serviceStatus with .down is non-template and wider than .healthy")
    func pinnedServiceStatusDownWiderThanHealthy() {
        let healthy = makeRenderData(
            pinned: [.init(id: .serviceStatus)],
            outageHealth: .healthy,
            nextPollSeconds: nil
        )
        let down = makeRenderData(
            pinned: [.init(id: .serviceStatus)],
            outageHealth: .down,
            nextPollSeconds: 125
        )

        let healthyImg = MenuBarRenderer.renderUncached(healthy)
        let downImg = MenuBarRenderer.renderUncached(down)

        #expect(downImg.isTemplate == false)
        #expect(downImg.size.width > healthyImg.size.width)
    }

    @Test("no config or error falls back to the template logo, even with an active outage badge underneath")
    func noConfigFallsBackToLogoBadgeOnly() {
        let data = makeRenderData(hasConfig: false, outageActive: true, outageHealth: .down, nextPollSeconds: 30)
        let image = MenuBarRenderer.renderUncached(data)
        // Outage badge alone (not composited with the logo) - still non-template.
        #expect(image.isTemplate == false)
    }
}

/// Covers the pin gating: Extra Credits renders in the menu bar only when the
/// paid pool is enabled, otherwise the item must not silently vanish.
@Suite("MenuBarRenderer Extra Credits gating")
struct MenuBarExtraCreditsRenderTests {

    @Test("EC pinned + pool enabled renders a value (non-template image)")
    func renderedWhenEnabled() {
        let data = makeRenderData(
            pinned: [.init(id: .extraCredits)],
            hasExtraCredits: true
        )
        let image = MenuBarRenderer.renderUncached(data)
        #expect(image.isTemplate == false)
        #expect(image.size.width > 0)
    }

    @Test("EC pinned but pool disabled falls back to the logo (template image)")
    func logoFallbackWhenDisabled() {
        let data = makeRenderData(
            pinned: [.init(id: .extraCredits)],
            hasExtraCredits: false
        )
        let image = MenuBarRenderer.renderUncached(data)
        #expect(image.isTemplate == true)
    }
}
