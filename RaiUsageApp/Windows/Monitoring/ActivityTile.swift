import SwiftUI

/// Descriptor for one history-derived activity tile ("5H ACTIVITY" /
/// "7D ACTIVITY") in the enterprise dashboard grid. `tokens`/`sessions` are
/// nil until the local JSONL cache has loaded (or when there is no history).
struct ActivityTileDescriptor {
    let id: String
    let label: String
    let icon: String
    let tokens: Int?
    let sessions: Int?
    /// True once `ActivityStore` finished its first load - flips the
    /// placeholder from "Loading" to "No local history".
    let loaded: Bool
    /// Optional secondary line shown in place of the session count (e.g. a
    /// per-model share "34% of 7d"). When set it wins over sessions/loading.
    var subtitle: String? = nil
}

/// Enterprise stand-in for a hidden untracked window tile: shows the local
/// activity total ("301k") with the session count as the secondary line.
/// Same card chrome and vertical rhythm as `MetricTile` so mixed grid rows
/// stay visually aligned; static (no expand) - the History page carries the
/// full drill-down.
struct ActivityTile: View {
    let descriptor: ActivityTileDescriptor

    /// Neutral info accent: a raw activity count carries no risk zone, so it
    /// never borrows the gauge's green/amber/coral ladder.
    private let accent = DS.Pastel.blue

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: descriptor.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.8))
                    .frame(width: 14)
                Text(descriptor.label.uppercased())
                    .font(DS.Typography.micro)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(descriptor.tokens.map(TokenFormatter.compact) ?? "\u{2014}")
                    .font(.system(size: 30, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                if descriptor.tokens != nil {
                    Text(String(localized: "activity.tokens.unit"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent.opacity(0.55))
                        .baselineOffset(3)
                }
            }

            Spacer(minLength: 0)

            Group {
                if let subtitle = descriptor.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if let sessions = descriptor.sessions {
                    HStack(spacing: 5) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(ActivityWindowCalculator.sessionsLabel(sessions))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(descriptor.loaded
                         ? String(localized: "activity.noData")
                         : String(localized: "activity.loading"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Pastel.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Pastel.border, lineWidth: 1)
        )
    }
}
