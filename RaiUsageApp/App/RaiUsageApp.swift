import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var usageStore: UsageStore!
    var settingsStore: SettingsStore!
    var vendorStatusStore: VendorStatusStore!
    var activityStore: ActivityStore!
    var updateStore: UpdateStore!

    private var statusBarController: StatusBarController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        statusBarController = StatusBarController(
            usageStore: usageStore,
            settingsStore: settingsStore,
            vendorStatusStore: vendorStatusStore,
            activityStore: activityStore,
            updateStore: updateStore
        )
        updateStore.startAutoCheck()
    }
}

@main
struct RaiUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let usageStore: UsageStore
    private let settingsStore: SettingsStore
    private let vendorStatusStore: VendorStatusStore
    private let activityStore: ActivityStore
    private let updateStore: UpdateStore

    init() {
        let tokenProvider = TokenProvider(
            oauthService: OAuthService(),
            oauthTokenStore: OAuthTokenStore()
        )
        self.usageStore = UsageStore(tokenProvider: tokenProvider)
        self.settingsStore = SettingsStore()
        self.vendorStatusStore = VendorStatusStore()
        self.activityStore = ActivityStore()
        self.updateStore = UpdateStore()

        NotificationService().setupDelegate()
        appDelegate.usageStore = usageStore
        appDelegate.settingsStore = settingsStore
        appDelegate.vendorStatusStore = vendorStatusStore
        appDelegate.activityStore = activityStore
        appDelegate.updateStore = updateStore
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
