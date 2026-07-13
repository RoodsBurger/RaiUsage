import Foundation

/// Display / menu-bar domain slice of the user settings. Extracted from
/// SettingsStore as part of the fat-store split, same pattern as
/// `PacingSettingsStore` and `NotificationSettingsStore`.
///
/// Owns the menu-bar visibility + rendering config, the pinned metrics set
/// consumed by the popover, the reset / pacing display formats, the
/// smart-color settings, the gauge warning/critical thresholds, and the
/// popover satellite toggles. Each property persists itself to UserDefaults.
@MainActor
final class DisplaySettingsStore: ObservableObject {
    @Published var showMenuBar: Bool {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar") }
    }
    /// When true, the app starts in the menu bar only and skips auto-opening the
    /// dashboard window at launch (incl. at login). The window stays reachable
    /// from the menu bar (right-click > Open). Onboarding always force-opens
    /// regardless of this flag so a fresh install is never left with no UI (#198).
    @Published var launchInBackground: Bool {
        didSet { UserDefaults.standard.set(launchInBackground, forKey: "launchInBackground") }
    }
    @Published var pinnedMetrics: Set<MetricID> {
        didSet {
            UserDefaults.standard.set(pinnedMetrics.map(\.rawValue), forKey: "pinnedMetrics")
        }
    }
    @Published var resetDisplayFormat: ResetDisplayFormat {
        didSet { UserDefaults.standard.set(resetDisplayFormat.rawValue, forKey: "resetDisplayFormat") }
    }
    /// Global "Smart Color" theming. When ON, color codes throughout the app
    /// (gauges, reset countdowns) integrate the time-to-reset factor instead of
    /// raw thresholds. Example: 95% utilization with 2 minutes left to reset
    /// stays green rather than going red. Falls back to threshold-based coloring
    /// when no reset date is available.
    @Published var smartColorEnabled: Bool {
        didSet { UserDefaults.standard.set(smartColorEnabled, forKey: "smartColorEnabled") }
    }
    /// User-selected temperament for the smart color algorithm. Shifts
    /// when the gauge transitions from chill -> warning -> hot. See
    /// `SmartColorProfile` for the parameter mapping.
    @Published var smartColorProfile: SmartColorProfile {
        didSet { UserDefaults.standard.set(smartColorProfile.rawValue, forKey: "smartColorProfile") }
    }
    /// Threshold-mode warning percentage (used when Smart Color is off).
    @Published var warningThreshold: Int {
        didSet { UserDefaults.standard.set(warningThreshold, forKey: "warningThreshold") }
    }
    /// Threshold-mode critical percentage (used when Smart Color is off).
    @Published var criticalThreshold: Int {
        didSet { UserDefaults.standard.set(criticalThreshold, forKey: "criticalThreshold") }
    }
    @Published var sessionPacingDisplayMode: PacingDisplayMode {
        didSet { UserDefaults.standard.set(sessionPacingDisplayMode.rawValue, forKey: "sessionPacingDisplayMode") }
    }
    @Published var weeklyPacingDisplayMode: PacingDisplayMode {
        didSet { UserDefaults.standard.set(weeklyPacingDisplayMode.rawValue, forKey: "weeklyPacingDisplayMode") }
    }
    /// Full menu-bar rendering configuration (pins, order, per-pin format,
    /// display mode, color mode, icon/separator/fixed-width). Persisted as
    /// JSON; a decode failure or fresh install falls back to `MenuBarConfig()`.
    /// Deliberately not migrated from the old `pinnedMetrics` set - a settings
    /// reset on this one field is an acceptable cost for a personal fork.
    @Published var menuBarConfig: MenuBarConfig {
        didSet { saveMenuBarConfig() }
    }
    /// Controls whether the Sonnet satellite appears in the popover Classic
    /// variant AND in the dashboard constellation. The menu-bar visibility of
    /// Sonnet is driven by `pinnedMetrics.contains(.sonnet)`, independently.
    @Published var displaySonnet: Bool {
        didSet { UserDefaults.standard.set(displaySonnet, forKey: "displaySonnet") }
    }
    /// Same as `displaySonnet` but for Claude Design.
    @Published var displayDesign: Bool {
        didSet { UserDefaults.standard.set(displayDesign, forKey: "displayDesign") }
    }
    /// Same as `displayDesign` but for Claude Fable.
    @Published var displayFable: Bool {
        didSet { UserDefaults.standard.set(displayFable, forKey: "displayFable") }
    }
    /// Same as `displayDesign` but for the paid Extra Credits pool. Only
    /// surfaced in settings when `UsageStore.hasExtraCredits` is true.
    @Published var displayExtraCredits: Bool {
        didSet { UserDefaults.standard.set(displayExtraCredits, forKey: "displayExtraCredits") }
    }

    /// Resolved threshold ladder handed to `RiskZone.forPercent(_:thresholds:)`.
    var thresholds: UsageThresholds {
        UsageThresholds(warningPercent: warningThreshold, criticalPercent: criticalThreshold)
    }

    init() {
        self.showMenuBar = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true
        self.launchInBackground = SettingsDefaults.bool(key: "launchInBackground", default: false)

        self.resetDisplayFormat = ResetDisplayFormat(
            rawValue: UserDefaults.standard.string(forKey: "resetDisplayFormat") ?? "relative"
        ) ?? .relative

        // Default ON.
        self.smartColorEnabled = UserDefaults.standard.object(forKey: "smartColorEnabled") as? Bool ?? true
        self.smartColorProfile = SmartColorProfile(
            rawValue: UserDefaults.standard.string(forKey: "smartColorProfile") ?? SmartColorProfile.default.rawValue
        ) ?? .default
        self.warningThreshold = {
            let val = UserDefaults.standard.integer(forKey: "warningThreshold")
            return val > 0 ? val : 60
        }()
        self.criticalThreshold = {
            let val = UserDefaults.standard.integer(forKey: "criticalThreshold")
            return val > 0 ? val : 85
        }()
        self.sessionPacingDisplayMode = PacingDisplayMode(
            rawValue: UserDefaults.standard.string(forKey: "sessionPacingDisplayMode") ?? "dotDelta"
        ) ?? .dotDelta
        self.weeklyPacingDisplayMode = PacingDisplayMode(
            rawValue: UserDefaults.standard.string(forKey: "weeklyPacingDisplayMode") ?? "dotDelta"
        ) ?? .dotDelta

        if let data = UserDefaults.standard.data(forKey: "menuBarConfig"),
           let decoded = try? JSONDecoder().decode(MenuBarConfig.self, from: data) {
            self.menuBarConfig = decoded
        } else {
            self.menuBarConfig = MenuBarConfig()
        }

        if let saved = UserDefaults.standard.stringArray(forKey: "pinnedMetrics") {
            self.pinnedMetrics = Set(saved.compactMap { MetricID(rawValue: $0) })
        } else {
            self.pinnedMetrics = [.fiveHour, .sevenDay]
        }

        // displaySonnet and displayDesign default to false for everyone -
        // the satellites are opt-in. Users who had the old behaviour (sonnet
        // pinned automatically toggled displaySonnet to true) keep whatever
        // they had saved.
        if UserDefaults.standard.object(forKey: "displaySonnet") != nil {
            self.displaySonnet = UserDefaults.standard.bool(forKey: "displaySonnet")
        } else {
            self.displaySonnet = false
        }
        self.displayDesign = UserDefaults.standard.object(forKey: "displayDesign") != nil
            ? UserDefaults.standard.bool(forKey: "displayDesign")
            : false
        self.displayFable = UserDefaults.standard.object(forKey: "displayFable") != nil
            ? UserDefaults.standard.bool(forKey: "displayFable")
            : false
        self.displayExtraCredits = UserDefaults.standard.object(forKey: "displayExtraCredits") != nil
            ? UserDefaults.standard.bool(forKey: "displayExtraCredits")
            : false
    }

    private func saveMenuBarConfig() {
        guard let data = try? JSONEncoder().encode(menuBarConfig) else { return }
        UserDefaults.standard.set(data, forKey: "menuBarConfig")
    }
}
