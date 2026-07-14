import SwiftUI

// MARK: - Shared color helpers
//
// PopoverView needs the same gauge/pacing colours in several places, so we
// centralise the lookups here instead of duplicating them at each call site.

@MainActor
enum PopoverColors {
    /// Resolves the semantic risk zone for a metric - Smart Color when enabled
    /// and the window has a duration to project over, the threshold ladder
    /// otherwise. Single source of truth so every popover surface agrees.
    static func riskZone(pct: Int, resetDate: Date?, windowDuration: TimeInterval, settings: SettingsStore) -> RiskZone {
        GaugeColorResolver.zone(
            mode: GaugeColorResolver.mode(smartColorEnabled: settings.smartColorEnabled, windowDuration: windowDuration),
            utilization: pct,
            resetDate: resetDate,
            windowDuration: windowDuration,
            thresholds: settings.thresholds,
            pacingMargin: Double(settings.pacingMargin),
            profile: settings.smartColorProfile
        )
    }

    static func zone(_ zone: PacingZone) -> Color {
        zone.semanticColor
    }

    static func zoneGradient(_ zone: PacingZone) -> LinearGradient {
        let base = zone.semanticColor
        return LinearGradient(colors: [base, base.lighter()], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Error banner

struct PopoverErrorBanner: View {
    @EnvironmentObject private var usageStore: UsageStore

    var body: some View {
        Group {
            switch usageStore.errorState {
            case .tokenUnavailable:
                expiredContent
            case .rateLimited:
                rateLimitedContent
            case .networkError:
                networkErrorContent
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bannerTint.opacity(0.08))
    }

    private var bannerTint: Color {
        switch usageStore.errorState {
        case .tokenUnavailable: RiskZone.critical.color
        case .rateLimited, .networkError: RiskZone.warning.color
        case .none: .clear
        }
    }

    /// Deliberately discreet single-line banner (#160): a soft warning glyph, a
    /// short label, and one subtle inline action. No long hint sentence and no
    /// diagnostic button: re-auth is a one-tap recovery, not a debug surface.
    @ViewBuilder private var expiredContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RiskZone.critical.color)
            Text(String(localized: "error.banner.reauth"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                Task { await usageStore.reauthenticate() }
            } label: {
                Text(String(localized: "error.banner.reauth.button"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RiskZone.critical.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(RiskZone.critical.color.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var rateLimitedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "error.banner.apiunavailable"), systemImage: "icloud.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RiskZone.warning.color)
            Text(String(localized: "error.banner.apiunavailable.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let last = usageStore.lastUpdate {
                Text(String(format: String(localized: "error.banner.lastupdate"),
                            last.formatted(.relative(presentation: .named))))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                primaryActionButton(
                    title: String(localized: "error.banner.retry.button"),
                    disabled: usageStore.isLoading
                ) {
                    usageStore.handleTokenChange()
                    Task { await usageStore.refresh(force: true) }
                }
                CopyDiagnosticButton()
                Button {
                    if let url = URL(string: "https://github.com/anthropics/claude-code/issues/31637") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                        Text(String(localized: "error.banner.apiunavailable.learnmore"))
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var networkErrorContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "error.network.generic"), systemImage: "wifi.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RiskZone.warning.color)
            HStack(spacing: 6) {
                primaryActionButton(
                    title: String(localized: "error.banner.retry.button"),
                    disabled: usageStore.isLoading
                ) {
                    Task { await usageStore.refresh(force: true) }
                }
                CopyDiagnosticButton()
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func primaryActionButton(
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(RiskZone.warning.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(RiskZone.warning.color.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Secondary action that copies a Markdown diagnostic report to the clipboard.
/// Appears next to the primary action in `PopoverErrorBanner` for every error
/// state, so users can paste raw debug context into GitHub issues.
struct CopyDiagnosticButton: View {
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var copied = false

    var body: some View {
        Button {
            let report = DiagnosticReporter.makeReport(
                usageStore: usageStore,
                settingsStore: settingsStore
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(report, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 9))
                Text(copied
                     ? String(localized: "error.banner.diagnostic.copied")
                     : String(localized: "error.banner.diagnostic.button"))
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
    }
}
