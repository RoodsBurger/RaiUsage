import Foundation

/// Sub-sections inside the Settings group. Every configuration screen lives
/// here -> order drives the sidebar's Settings group.
enum SettingsSection: String, CaseIterable {
    case general
    case menuBar
    case popover
    case pacing
    case notifications

    var labelKey: String {
        switch self {
        case .general:       "sidebar.general"
        case .menuBar:       "sidebar.display"
        case .popover:       "sidebar.popover"
        case .pacing:        "sidebar.pacing"
        case .notifications: "sidebar.notifications"
        }
    }

    var label: String { String(localized: String.LocalizationValue(labelKey)) }

    var iconName: String {
        switch self {
        case .general:       "slider.horizontal.3"
        case .menuBar:       "menubar.rectangle"
        case .popover:       "rectangle.inset.filled"
        case .pacing:        "speedometer"
        case .notifications: "bell.fill"
        }
    }
}

/// Selection for the main window's `NavigationSplitView` sidebar -> the two
/// top-level spaces plus one case per `SettingsSection`. A single unified
/// type so the sidebar, the detail router, and `.navigateToSection` postings
/// all speak the same selection value.
enum SidebarItem: Hashable {
    case monitoring
    case history
    case settings(SettingsSection)

    /// Top-level rows shown above the Settings group, in display order.
    static let topLevel: [SidebarItem] = [.monitoring, .history]

    var labelKey: String {
        switch self {
        case .monitoring: "sidebar.monitoring"
        case .history:    "sidebar.history"
        case .settings(let section): section.labelKey
        }
    }

    var label: String { String(localized: String.LocalizationValue(labelKey)) }

    var iconName: String {
        switch self {
        case .monitoring: "gauge.high"
        case .history:    "clock.arrow.circlepath"
        case .settings(let section): section.iconName
        }
    }
}

/// Parsed navigation target sent via `Notification.Name.navigateToSection`.
struct NavigationTarget: Equatable {
    let item: SidebarItem

    /// Parse from a payload string. Recognised values :
    /// - `"monitoring"`, `"history"` -> the matching top-level sidebar item
    /// - `"settings"` -> the General settings row (default landing tab)
    /// - `"settings.general"`, `"settings.menuBar"`, ... -> a specific settings row
    static func parse(_ payload: String) -> NavigationTarget? {
        if payload == "settings" {
            return NavigationTarget(item: .settings(.general))
        }
        if payload.hasPrefix("settings.") {
            let sub = String(payload.dropFirst("settings.".count))
            guard let section = SettingsSection(rawValue: sub) else { return nil }
            return NavigationTarget(item: .settings(section))
        }
        switch payload {
        case "monitoring": return NavigationTarget(item: .monitoring)
        case "history":    return NavigationTarget(item: .history)
        default:           return nil
        }
    }
}
