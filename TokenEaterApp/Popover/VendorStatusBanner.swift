import SwiftUI

/// Popover banner shown when a monitored vendor is degraded/down. Uses the
/// same semantic risk tint as `PopoverErrorBanner` (RiskZone.critical for
/// down, RiskZone.warning for degraded) - no raw colors.
struct VendorStatusBanner: View {
    @EnvironmentObject private var vendorStatusStore: VendorStatusStore

    var body: some View {
        if vendorStatusStore.isDegraded, let status = vendorStatusStore.claudeStatus {
            content(for: status)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(tint(status.health).opacity(0.08))
        }
    }

    private func tint(_ health: VendorHealth) -> Color {
        health == .down ? RiskZone.critical.color : RiskZone.warning.color
    }

    @ViewBuilder
    private func content(for status: VendorStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint(status.health))
                Text(headline(for: status.health))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Link(String(localized: "status.banner.view"), destination: status.statusPageURL)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint(status.health))
            }
            if let incident = status.activeIncidents.first {
                Text(incident.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func headline(for health: VendorHealth) -> String {
        health == .down
            ? String(localized: "status.banner.down")
            : String(localized: "status.banner.degraded")
    }
}
