import SwiftUI
import AppKit

/// Data-point risk → semantic system color. The single source of gauge color.
enum RiskZone: String, Sendable, CaseIterable {
    case ok, warning, critical

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: .systemGreen
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    /// Threshold ladder used when Smart Color is off (percent used vs user thresholds).
    static func forPercent(_ pct: Int, thresholds: UsageThresholds) -> RiskZone {
        if pct >= thresholds.criticalPercent { return .critical }
        if pct >= thresholds.warningPercent { return .warning }
        return .ok
    }
}

extension PacingZone {
    /// chill=green, onTrack=blue (active/info), warning=orange, hot=red.
    var semanticColor: Color {
        switch self {
        case .chill: .green
        case .onTrack: .blue
        case .warning: .orange
        case .hot: .red
        }
    }

    var semanticNSColor: NSColor {
        switch self {
        case .chill: .systemGreen
        case .onTrack: .systemBlue
        case .warning: .systemOrange
        case .hot: .systemRed
        }
    }
}
