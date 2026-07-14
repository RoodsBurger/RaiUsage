import SwiftUI

/// The main window's `NavigationSplitView` sidebar column. Lists the two
/// top-level spaces (Monitoring, History) then a Settings group with one row
/// per `SettingsSection`. Selection paints a pastel tinted row
/// (`DS.Pastel.card` fill) -> no system accent capsule, no glow.
struct SidebarNav: View {
    @Binding var selection: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                VStack(spacing: DS.Spacing.xxs) {
                    ForEach(SidebarItem.topLevel, id: \.self) { item in
                        row(for: item)
                    }
                }

                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(String(localized: "sidebar.settings").uppercased())
                        .font(DS.Typography.micro)
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, DS.Spacing.sm)
                        .padding(.bottom, DS.Spacing.xxs)

                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        row(for: .settings(section))
                    }
                }
            }
            .padding(DS.Spacing.sm)
        }
        .background(DS.Pastel.base)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }

    private func row(for item: SidebarItem) -> some View {
        SidebarRow(item: item, isSelected: selection == item) {
            selection = item
        }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: item.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, alignment: .center)
                Text(item.label)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.input, style: .continuous)
            .fill(isSelected ? DS.Pastel.card : (isHovering ? DS.Pastel.card.opacity(0.5) : .clear))
    }
}
