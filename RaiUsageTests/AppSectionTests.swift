import Testing

@Suite("SidebarItem")
struct SidebarItemTests {
    @Test("Top-level order is Monitoring then History")
    func topLevelOrder() {
        #expect(SidebarItem.topLevel == [.monitoring, .history])
    }

    @Test("Top-level items expose their own icon")
    func topLevelIcons() {
        #expect(SidebarItem.monitoring.iconName == "gauge.high")
        #expect(SidebarItem.history.iconName == "clock.arrow.circlepath")
    }

    @Test("Settings rows delegate icon and label key to their section", arguments: SettingsSection.allCases)
    func settingsDelegatesToSection(section: SettingsSection) {
        let item = SidebarItem.settings(section)
        #expect(item.iconName == section.iconName)
        #expect(item.labelKey == section.labelKey)
    }

    @Test("Settings group order is General, Menu Bar, Popover, Pacing, Notifications")
    func settingsGroupOrder() {
        #expect(SettingsSection.allCases == [.general, .menuBar, .popover, .pacing, .notifications])
    }
}

@Suite("NavigationTarget.parse")
struct NavigationTargetParseTests {
    @Test("Top-level payloads resolve to their sidebar item")
    func topLevel() {
        #expect(NavigationTarget.parse("monitoring")?.item == .monitoring)
        #expect(NavigationTarget.parse("history")?.item == .history)
    }

    @Test("Bare settings payload defaults to the General row")
    func bareSettings() {
        #expect(NavigationTarget.parse("settings")?.item == .settings(.general))
    }

    @Test("Nested settings payloads resolve to their section", arguments: SettingsSection.allCases)
    func nestedSettings(section: SettingsSection) {
        #expect(NavigationTarget.parse("settings.\(section.rawValue)")?.item == .settings(section))
    }

    @Test("Unknown or malformed payloads return nil")
    func unknown() {
        #expect(NavigationTarget.parse("bogus") == nil)
        #expect(NavigationTarget.parse("settings.bogus") == nil)
        #expect(NavigationTarget.parse("settings.") == nil)
        #expect(NavigationTarget.parse("") == nil)
    }
}
