import SwiftUI

// MARK: - Glass Card

func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
}

// MARK: - Section Title

/// Unified header used by every settings section. Big display-weight title +
/// optional subtitle. Always leave 20pt of top breathing room.
func sectionTitle(_ text: String, subtitle: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(text)
            .font(.system(size: 24, weight: .black, design: .rounded))
            .foregroundStyle(.white)
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
    .padding(.top, 8)
    .padding(.bottom, 4)
}

// MARK: - Card Label

func cardLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
}

// MARK: - Dark Toggle

func darkToggle(_ label: String, isOn: Binding<Bool>) -> some View {
    HStack {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .tint(DS.Palette.accentSettings)
            .labelsHidden()
        Text(label)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.8))
        Spacer()
    }
}

// MARK: - Dark Button (secondary)

func darkButton(_ titleKey: LocalizedStringResource, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(titleKey)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.white.opacity(0.08))
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
            )
    }
    .buttonStyle(.plain)
}

// MARK: - Dark Primary Button

func darkPrimaryButton(_ titleKey: LocalizedStringResource, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(titleKey)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(.white.opacity(0.15))
                    .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
            )
    }
    .buttonStyle(.plain)
}

// MARK: - Click Chip

/// Generic click-to-toggle chip. Two visual styles:
/// - `.compact`  -> short pill for header / inline use
/// - `.tile`     -> larger card-like surface for grouped grids
struct ClickChip: View {
    enum Style { case compact, tile }

    let label: String
    let icon: String?
    let isActive: Bool
    let accent: Color
    var style: Style = .tile
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: style == .compact ? 5 : 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: style == .compact ? 9 : 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: style == .compact ? 10 : 12, weight: .medium))
            }
            .foregroundStyle(isActive ? accent : .white.opacity(0.55))
            .padding(.horizontal, style == .compact ? 9 : 12)
            .padding(.vertical, style == .compact ? 5 : 8)
            .frame(maxWidth: style == .tile ? .infinity : nil)
            .background(chipBackground)
            .scaleEffect(hovering ? 1.02 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hovering)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var chipBackground: some View {
        let radius: CGFloat = style == .compact ? 7 : 9
        RoundedRectangle(cornerRadius: radius)
            .fill(isActive ? accent.opacity(0.18) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(isActive ? accent.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

// MARK: - Reset Section Button

/// Bottom-of-section reset control with a destructive confirmation alert.
/// Shared across settings sub-sections so the visual + interaction is
/// identical everywhere (Themes, Display, Popover, Notifications,
/// Performance). Caller passes the localised confirmation title and the
/// closure that performs the actual reset.
struct ResetSectionButton: View {
    let confirmTitle: String
    let onReset: () -> Void

    @State private var showAlert = false

    var body: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                showAlert = true
            } label: {
                Text(String(localized: "settings.section.reset"))
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .alert(confirmTitle, isPresented: $showAlert) {
                Button(String(localized: "settings.section.reset.cancel"), role: .cancel) { }
                Button(String(localized: "settings.section.reset.action"), role: .destructive) {
                    onReset()
                }
            }
        }
    }
}
