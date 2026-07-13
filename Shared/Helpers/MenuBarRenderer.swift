import AppKit

enum MenuBarRenderer {
    /// Everything the renderer needs to draw one frame of the status item.
    /// Pure value type - no store references - so `buildLine(data:)` and
    /// `render(_:)` are unit-testable without touching AppKit's live status
    /// bar or any `@MainActor` store.
    struct RenderData: Equatable {
        let menuBarConfig: MenuBarConfig
        /// Index into the visible-pins list for `.rotate` display mode.
        /// Wrapped modulo the visible count, so any non-negative value works.
        let rotateIndex: Int

        let hasConfig: Bool
        let hasError: Bool
        let thresholds: UsageThresholds
        let smartColorEnabled: Bool
        let smartColorProfile: SmartColorProfile
        let pacingMargin: Double

        let fiveHourPct: Int
        let sevenDayPct: Int
        let sonnetPct: Int
        let designPct: Int
        let fablePct: Int
        let extraCreditsPct: Int

        /// True once the API has returned a `five_hour` bucket at all -
        /// independent of whether `resetsAt` is populated, since Anthropic can
        /// return the bucket with `utilization: 0` and no reset date between
        /// two 5h windows. Keeps session-scoped pins visible with a neutral
        /// placeholder instead of vanishing during a lull.
        let hasFiveHourBucket: Bool
        let hasWeeklyPacing: Bool
        let hasSessionPacing: Bool
        let hasDesign: Bool
        let hasFable: Bool
        let hasExtraCredits: Bool

        let fiveHourResetDate: Date?
        let sevenDayResetDate: Date?
        let sonnetResetDate: Date?
        let designResetDate: Date?
        let fableResetDate: Date?

        /// Relative countdown text ("1h39", ...), appended after the value
        /// when a pin's `showCountdown` is on.
        let fiveHourReset: String
        let sevenDayReset: String
        let sonnetReset: String
        let designReset: String
        let fableReset: String

        let sessionPacingDelta: Int
        let sessionPacingZone: PacingZone
        let weeklyPacingDelta: Int
        let weeklyPacingZone: PacingZone
        let sessionPacingDisplayMode: PacingDisplayMode
        let weeklyPacingDisplayMode: PacingDisplayMode

        /// Extra Credits pool usage in the currency's minor unit (e.g. cents),
        /// formatted through `CurrencyFormatter` when a pin's value style is
        /// `.dollars`.
        let extraCreditsUsedMinorUnits: Double
        let extraCreditsCurrency: String

        // Outage badge - set by StatusBarController from VendorStatusStore.
        let outageActive: Bool
        let outageHealth: VendorHealth
        let nextPollSeconds: Int?
    }

    private static var cachedImage: NSImage?
    private static var cachedData: RenderData?

    static func render(_ data: RenderData) -> NSImage {
        if let cached = cachedImage, let prev = cachedData, prev == data {
            return cached
        }

        let image = renderUncached(data)
        cachedImage = image
        cachedData = data
        return image
    }

    /// Same rendering pipeline as `render(_:)` but never touches or updates
    /// the static cache. Useful for live previews that may differ from the
    /// status bar's current state and shouldn't poison it.
    static func renderUncached(_ data: RenderData) -> NSImage {
        if data.outageActive {
            return renderWithOutageBadge(data)
        }
        if !data.hasConfig || data.hasError {
            return renderLogoTemplate()
        }
        return renderPinnedMetrics(data)
    }

    // MARK: - Color helpers

    /// Resolves the gauge colour for a flat percentage.
    ///
    /// Smart Color is a *time-aware* risk model: it projects current usage
    /// against the time left in a reset window. A metric with no reset window
    /// (e.g. the Extra Credits pool) has nothing to project against, so it
    /// falls back to the static warning/critical threshold ladder. This is the
    /// rule that keeps Extra Credits coloured identically in the menu bar, the
    /// popover, and the dashboard. Internal (not private) so the
    /// windowless-fallback rule is unit-testable in isolation; `now` is
    /// injectable for deterministic tests.
    static func gaugeColor(
        pct: Int,
        resetDate: Date?,
        windowDuration: TimeInterval,
        monochrome: Bool,
        smartEnabled: Bool,
        thresholds: UsageThresholds,
        pacingMargin: Double,
        smartColorProfile: SmartColorProfile,
        now: Date = Date()
    ) -> NSColor {
        if monochrome { return .labelColor }
        return GaugeColorResolver.nsColor(
            mode: GaugeColorResolver.mode(smartColorEnabled: smartEnabled, windowDuration: windowDuration),
            utilization: pct,
            resetDate: resetDate,
            windowDuration: windowDuration,
            thresholds: thresholds,
            pacingMargin: pacingMargin,
            now: now,
            profile: smartColorProfile
        )
    }

    private static func metricColor(pct: Int, resetDate: Date?, windowDuration: TimeInterval, data: RenderData) -> NSColor {
        gaugeColor(
            pct: pct,
            resetDate: resetDate,
            windowDuration: windowDuration,
            monochrome: data.menuBarConfig.colorMode == .monochrome,
            smartEnabled: data.smartColorEnabled,
            thresholds: data.thresholds,
            pacingMargin: data.pacingMargin,
            smartColorProfile: data.smartColorProfile
        )
    }

    private static func pacingColor(_ zone: PacingZone, hasData: Bool, data: RenderData) -> NSColor {
        if data.menuBarConfig.colorMode == .monochrome { return .labelColor }
        return hasData ? zone.semanticNSColor : .tertiaryLabelColor
    }

    /// 0/1/2 risk rank for a metric's own zone, independent of `colorMode` -
    /// `highestRisk` selection is driven by real usage risk even when the
    /// display renders monochrome.
    private static func zoneRank(pct: Int, resetDate: Date?, windowDuration: TimeInterval, data: RenderData) -> Int {
        let mode = GaugeColorResolver.mode(smartColorEnabled: data.smartColorEnabled, windowDuration: windowDuration)
        let zone = GaugeColorResolver.zone(
            mode: mode,
            utilization: pct,
            resetDate: resetDate,
            windowDuration: windowDuration,
            thresholds: data.thresholds,
            pacingMargin: data.pacingMargin,
            profile: data.smartColorProfile
        )
        switch zone {
        case .ok: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    private static func pacingRank(_ zone: PacingZone) -> Int {
        switch zone {
        case .chill, .onTrack: return 0
        case .warning: return 1
        case .hot: return 2
        }
    }

    private static func windowDuration(for metric: MetricID) -> TimeInterval {
        switch metric {
        case .fiveHour: return 5 * 3600
        case .sevenDay, .sonnet, .design, .fable: return 7 * 86_400
        default: return 0
        }
    }

    // MARK: - Outage badge

    /// Composite an outage glyph + mm:ss countdown ahead of the normal content.
    /// When usage data isn't usable (no config / usage error), show the badge
    /// alone - avoids compositing a template logo into a coloured image.
    private static func renderWithOutageBadge(_ data: RenderData) -> NSImage {
        let badge = renderOutageBadgeImage(data)
        let hasMetrics = data.hasConfig && !data.hasError
        guard hasMetrics else { return badge }
        let base = renderPinnedMetrics(data)
        return horizontallyCompose(left: badge, right: base, gap: 5)
    }

    private static func renderOutageBadgeImage(_ data: RenderData) -> NSImage {
        let height: CGFloat = 22
        let tint: NSColor = data.outageHealth == .down ? .systemRed : .systemOrange

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let glyph = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        let glyphSize = glyph?.size ?? NSSize(width: 12, height: 12)

        var countdown: NSAttributedString?
        if let secs = data.nextPollSeconds {
            let clamped = max(0, secs)
            let text = String(format: "%d:%02d", clamped / 60, clamped % 60)
            countdown = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: tint,
            ])
        }

        let gap: CGFloat = 3
        let textWidth = countdown?.size().width ?? 0
        let width = glyphSize.width + (countdown != nil ? gap + textWidth : 0)
        let img = NSImage(size: NSSize(width: ceil(width) + 2, height: height), flipped: false) { _ in
            glyph?.draw(at: NSPoint(x: 1, y: (height - glyphSize.height) / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
            if let countdown {
                let ts = countdown.size()
                countdown.draw(at: NSPoint(x: 1 + glyphSize.width + gap, y: (height - ts.height) / 2))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func horizontallyCompose(left: NSImage, right: NSImage, gap: CGFloat) -> NSImage {
        let height: CGFloat = 22
        let width = left.size.width + gap + right.size.width
        let img = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            left.draw(at: NSPoint(x: 0, y: (height - left.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
            right.draw(at: NSPoint(x: left.size.width + gap, y: (height - right.size.height) / 2),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: - Pin visibility

    /// The configured pins, filtered down to the ones that currently have
    /// something to show. Order is preserved from `menuBarConfig.pinned`.
    static func visiblePins(_ data: RenderData) -> [PinnedMetricConfig] {
        data.menuBarConfig.pinned.filter { pin in
            switch pin.id {
            case .fiveHour, .sessionReset, .sessionPacing: return data.hasFiveHourBucket
            case .sevenDay: return true
            case .sonnet: return true
            case .design: return data.hasDesign
            case .fable: return data.hasFable
            case .extraCredits: return data.hasExtraCredits
            case .weeklyPacing: return data.hasWeeklyPacing
            case .serviceStatus: return true
            }
        }
    }

    // MARK: - Line building (pure, testable)

    /// Builds the full attributed line for the current display mode, without
    /// touching AppKit imaging. Empty when nothing is pinned/visible.
    static func buildLine(data: RenderData) -> NSAttributedString {
        let visible = visiblePins(data)
        guard !visible.isEmpty else { return NSAttributedString() }

        switch data.menuBarConfig.displayMode {
        case .all:
            return buildAllLine(visible, data: data)
        case .highestRisk:
            guard let pin = highestRiskPin(visible, data: data) else { return NSAttributedString() }
            return buildSingle(pin, data: data, worstCase: false)
        case .rotate:
            let index = ((data.rotateIndex % visible.count) + visible.count) % visible.count
            return buildSingle(visible[index], data: data, worstCase: false)
        }
    }

    /// The widest this configuration's line could ever render, used to pad
    /// the status item to a stable width (`fixedWidth`). "All" mode measures
    /// the full worst-case line; single-pin modes take the max width across
    /// every pinned metric's own worst case, since rotation/highest-risk can
    /// land on any of them.
    static func fixedWidthMeasurement(data: RenderData) -> CGFloat {
        let visible = visiblePins(data)
        guard !visible.isEmpty else { return 0 }
        switch data.menuBarConfig.displayMode {
        case .all:
            return ceil(buildAllLine(visible, data: data, worstCase: true).size().width)
        case .highestRisk, .rotate:
            return visible.map { ceil(buildSingle($0, data: data, worstCase: true).size().width) }.max() ?? 0
        }
    }

    private static func buildAllLine(_ pins: [PinnedMetricConfig], data: RenderData, worstCase: Bool = false) -> NSAttributedString {
        let str = NSMutableAttributedString()
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for (i, pin) in pins.enumerated() {
            if i > 0 {
                str.append(NSAttributedString(string: " \(data.menuBarConfig.separator) ", attributes: sepAttrs))
            }
            str.append(buildSingle(pin, data: data, worstCase: worstCase))
        }
        return str
    }

    /// Picks the pinned metric with the highest risk rank. Ties keep pinned
    /// order (strict `>` only replaces the running best).
    private static func highestRiskPin(_ pins: [PinnedMetricConfig], data: RenderData) -> PinnedMetricConfig? {
        var best: PinnedMetricConfig?
        var bestScore = -1
        for pin in pins {
            let score = riskScore(pin, data: data)
            if score > bestScore {
                bestScore = score
                best = pin
            }
        }
        return best
    }

    private static func riskScore(_ pin: PinnedMetricConfig, data: RenderData) -> Int {
        switch pin.id {
        case .fiveHour:
            return zoneRank(pct: data.fiveHourPct, resetDate: data.fiveHourResetDate, windowDuration: windowDuration(for: .fiveHour), data: data)
        case .sevenDay:
            return zoneRank(pct: data.sevenDayPct, resetDate: data.sevenDayResetDate, windowDuration: windowDuration(for: .sevenDay), data: data)
        case .sonnet:
            return zoneRank(pct: data.sonnetPct, resetDate: data.sonnetResetDate, windowDuration: windowDuration(for: .sonnet), data: data)
        case .design:
            return zoneRank(pct: data.designPct, resetDate: data.designResetDate, windowDuration: windowDuration(for: .design), data: data)
        case .fable:
            return zoneRank(pct: data.fablePct, resetDate: data.fableResetDate, windowDuration: windowDuration(for: .fable), data: data)
        case .extraCredits:
            return zoneRank(pct: data.extraCreditsPct, resetDate: nil, windowDuration: 0, data: data)
        case .sessionPacing:
            return data.hasSessionPacing ? pacingRank(data.sessionPacingZone) : 0
        case .weeklyPacing:
            return data.hasWeeklyPacing ? pacingRank(data.weeklyPacingZone) : 0
        case .serviceStatus:
            return data.outageHealth.rawValue
        case .sessionReset:
            return zoneRank(pct: data.fiveHourPct, resetDate: data.fiveHourResetDate, windowDuration: windowDuration(for: .fiveHour), data: data)
        }
    }

    // MARK: - Per-pin rendering

    private static func buildSingle(_ pin: PinnedMetricConfig, data: RenderData, worstCase: Bool) -> NSAttributedString {
        switch pin.id {
        case .fiveHour:
            return buildPercentMetric(pin, pct: data.fiveHourPct, resetDate: data.fiveHourResetDate, windowDuration: windowDuration(for: .fiveHour), countdown: data.fiveHourReset, data: data, worstCase: worstCase)
        case .sevenDay:
            return buildPercentMetric(pin, pct: data.sevenDayPct, resetDate: data.sevenDayResetDate, windowDuration: windowDuration(for: .sevenDay), countdown: data.sevenDayReset, data: data, worstCase: worstCase)
        case .sonnet:
            return buildPercentMetric(pin, pct: data.sonnetPct, resetDate: data.sonnetResetDate, windowDuration: windowDuration(for: .sonnet), countdown: data.sonnetReset, data: data, worstCase: worstCase)
        case .design:
            return buildPercentMetric(pin, pct: data.designPct, resetDate: data.designResetDate, windowDuration: windowDuration(for: .design), countdown: data.designReset, data: data, worstCase: worstCase)
        case .fable:
            return buildPercentMetric(pin, pct: data.fablePct, resetDate: data.fableResetDate, windowDuration: windowDuration(for: .fable), countdown: data.fableReset, data: data, worstCase: worstCase)
        case .extraCredits:
            return buildExtraCreditsMetric(pin, data: data, worstCase: worstCase)
        case .sessionPacing:
            return buildPacingMetric(pin, hasData: data.hasSessionPacing, delta: data.sessionPacingDelta, zone: data.sessionPacingZone, mode: data.sessionPacingDisplayMode, data: data)
        case .weeklyPacing:
            return buildPacingMetric(pin, hasData: true, delta: data.weeklyPacingDelta, zone: data.weeklyPacingZone, mode: data.weeklyPacingDisplayMode, data: data)
        case .serviceStatus:
            return buildServiceStatus(pin, data: data)
        case .sessionReset:
            return buildCountdownOnly(data: data)
        }
    }

    /// `label + value%` for a simple percentage metric (5h/7d/Sonnet/Design/
    /// Fable). `worstCase` forces the value to "100" - the widest a percent
    /// value can ever render - for `fixedWidthMeasurement`.
    private static func buildPercentMetric(
        _ pin: PinnedMetricConfig,
        pct: Int,
        resetDate: Date?,
        windowDuration: TimeInterval,
        countdown: String,
        data: RenderData,
        worstCase: Bool
    ) -> NSAttributedString {
        let str = NSMutableAttributedString()
        appendPrefix(pin, to: str, data: data)

        let displayPct: Int
        if worstCase {
            displayPct = 100
        } else if pin.value == .percentRemaining {
            displayPct = max(0, 100 - pct)
        } else {
            displayPct = pct
        }
        let color = metricColor(pct: pct, resetDate: resetDate, windowDuration: windowDuration, data: data)
        str.append(NSAttributedString(string: "\(displayPct)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ]))

        if pin.showCountdown, !countdown.isEmpty {
            str.append(NSAttributedString(string: " \(countdown)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return str
    }

    /// Extra Credits is the only metric `.dollars` renders for; any other
    /// value style still falls back to a plain percentage.
    private static func buildExtraCreditsMetric(_ pin: PinnedMetricConfig, data: RenderData, worstCase: Bool) -> NSAttributedString {
        let str = NSMutableAttributedString()
        appendPrefix(pin, to: str, data: data)

        let color = metricColor(pct: data.extraCreditsPct, resetDate: nil, windowDuration: 0, data: data)
        let text: String
        switch pin.value {
        case .dollars:
            text = worstCase
                ? "$100"
                : CurrencyFormatter.formatMinorUnits(
                    data.extraCreditsUsedMinorUnits,
                    currencyCode: data.extraCreditsCurrency,
                    locale: Locale(identifier: "en_US")
                )
        case .percentRemaining:
            text = "\(worstCase ? 100 : max(0, 100 - data.extraCreditsPct))%"
        case .percentUsed:
            text = "\(worstCase ? 100 : data.extraCreditsPct)%"
        }
        str.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ]))
        return str
    }

    /// Session/weekly pacing row: dot / dot+delta / delta per
    /// `PacingDisplayMode`. The dot glyph is a fixed "\u{25CF}".
    private static let pacingGlyph = "\u{25CF}"

    private static func buildPacingMetric(
        _ pin: PinnedMetricConfig,
        hasData: Bool,
        delta: Int,
        zone: PacingZone,
        mode: PacingDisplayMode,
        data: RenderData
    ) -> NSAttributedString {
        let str = NSMutableAttributedString()
        appendPrefix(pin, to: str, data: data)

        let color = pacingColor(zone, hasData: hasData, data: data)
        let dotAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: color,
        ]
        let deltaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: color,
        ]
        let sign = delta >= 0 ? "+" : ""
        switch mode {
        case .dot:
            str.append(NSAttributedString(string: pacingGlyph, attributes: dotAttrs))
        case .dotDelta:
            str.append(NSAttributedString(string: pacingGlyph, attributes: dotAttrs))
            str.append(NSAttributedString(string: hasData ? " \(sign)\(delta)%" : " -", attributes: deltaAttrs))
        case .delta:
            str.append(NSAttributedString(string: hasData ? "\(sign)\(delta)%" : "-", attributes: deltaAttrs))
        }
        return str
    }

    private static func buildServiceStatus(_ pin: PinnedMetricConfig, data: RenderData) -> NSAttributedString {
        let str = NSMutableAttributedString()
        let mono = data.menuBarConfig.colorMode == .monochrome
        let symbolName: String
        let color: NSColor
        let fallbackText: String
        switch data.outageHealth {
        case .healthy:  symbolName = "checkmark.circle.fill";         color = mono ? .labelColor : .systemGreen;  fallbackText = "OK"
        case .degraded: symbolName = "exclamationmark.triangle.fill"; color = mono ? .labelColor : .systemOrange; fallbackText = "!"
        case .down:     symbolName = "exclamationmark.triangle.fill"; color = mono ? .labelColor : .systemRed;    fallbackText = "!"
        }

        if data.menuBarConfig.showIcon {
            appendSymbol(symbolName, color: color, to: str)
        } else {
            str.append(NSAttributedString(string: fallbackText, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: color,
            ]))
        }

        if data.outageHealth == .down, let secs = data.nextPollSeconds {
            let clamped = max(0, secs)
            let text = String(format: " %d:%02d", clamped / 60, clamped % 60)
            str.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: color,
            ]))
        }
        return str
    }

    /// `sessionReset` is not offered in the "add a pin" menu - a percentage
    /// pin's `showCountdown` flag covers that role instead. This case only
    /// exists so the switch stays exhaustive if a config is ever decoded with
    /// that id; it renders countdown text alone, no value.
    private static func buildCountdownOnly(data: RenderData) -> NSAttributedString {
        let text = data.fiveHourReset.isEmpty ? "-" : data.fiveHourReset
        let color = metricColor(pct: data.fiveHourPct, resetDate: data.fiveHourResetDate, windowDuration: windowDuration(for: .fiveHour), data: data)
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ])
    }

    // MARK: - Prefix (icon / short label)

    private static func appendPrefix(_ pin: PinnedMetricConfig, to str: NSMutableAttributedString, data: RenderData) {
        switch pin.prefix {
        case .none:
            return
        case .shortLabel:
            appendShortLabel(pin.id, to: str)
        case .symbol:
            if data.menuBarConfig.showIcon {
                appendSymbol(pin.id.menuBarSymbolName, color: .secondaryLabelColor, to: str)
                str.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 9)]))
            } else {
                appendShortLabel(pin.id, to: str)
            }
        }
    }

    private static func appendShortLabel(_ id: MetricID, to str: NSMutableAttributedString) {
        let label = id.shortLabel
        guard !label.isEmpty else { return }
        str.append(NSAttributedString(string: "\(label) ", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    }

    /// SF Symbol prefix, sized to the surrounding text's cap height so it
    /// sits centered on the baseline instead of towering over/under the text.
    private static func appendSymbol(_ name: String, color: NSColor, to str: NSMutableAttributedString, pointSize: CGFloat = 11) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let capHeight = NSFont.systemFont(ofSize: pointSize).capHeight
        let attachment = NSTextAttachment()
        attachment.image = glyph
        attachment.bounds = CGRect(x: 0, y: (capHeight - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
        str.append(NSAttributedString(attachment: attachment))
    }

    // MARK: - Imaging

    private static func renderPinnedMetrics(_ data: RenderData) -> NSImage {
        let line = buildLine(data: data)
        guard line.length > 0 else { return renderLogoTemplate() }

        let height: CGFloat = 22
        var contentWidth = ceil(line.size().width)
        if data.menuBarConfig.fixedWidth {
            contentWidth = max(contentWidth, fixedWidthMeasurement(data: data))
        }

        let imgSize = NSSize(width: contentWidth + 2, height: height)
        let lineSize = line.size()
        let img = NSImage(size: imgSize, flipped: false) { _ in
            line.draw(at: NSPoint(x: 1, y: (height - lineSize.height) / 2))
            return true
        }
        img.isTemplate = false
        return img
    }

    /// App logo silhouette for menu bar (template - macOS renders white/black automatically).
    private static func renderLogoTemplate() -> NSImage {
        let s: CGFloat = 16
        let height: CGFloat = 22
        let imgSize = NSSize(width: s + 2, height: height)
        let scale = s / 300.0
        let yOff = (height - s) / 2

        let img = NSImage(size: imgSize, flipped: true) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: 1, y: yOff)
            ctx.scaleBy(x: scale, y: scale)

            NSColor.black.setFill()

            let lPath = CGMutablePath()
            let r: CGFloat = 32
            lPath.addRoundedRect(in: CGRect(x: 0, y: 0, width: 300, height: 122), cornerWidth: r, cornerHeight: r)
            lPath.addRoundedRect(in: CGRect(x: 0, y: 0, width: 122, height: 300), cornerWidth: r, cornerHeight: r)
            ctx.addPath(lPath)
            ctx.fillPath(using: .winding)

            let bar1 = CGRect(x: 142, y: 142, width: 158, height: 70)
            let bar2 = CGRect(x: 142, y: 230, width: 158, height: 70)
            let barR: CGFloat = 24
            ctx.addPath(CGPath(roundedRect: bar1, cornerWidth: barR, cornerHeight: barR, transform: nil))
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: bar2, cornerWidth: barR, cornerHeight: barR, transform: nil))
            ctx.fillPath()

            return true
        }
        img.isTemplate = true
        return img
    }
}
