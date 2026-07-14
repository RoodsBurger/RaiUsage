import SwiftUI

/// Owns the in-app update pipeline: a throttled automatic check against the
/// pinned GitHub repo's releases, the manual "Check for updates", and the
/// download -> install -> relaunch flow. See `UpdateChecker` for the trust
/// model and `UpdateInstaller` for the swap-install mechanics.
@MainActor
final class UpdateStore: ObservableObject {
    @Published private(set) var state: UpdateState = .idle

    /// The running app's short version, for the Settings "current version" row.
    let currentVersion: String

    /// Courtesy floor between automatic checks (manual checks bypass it).
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60
    /// Cadence at which the running app re-evaluates whether a check is due.
    static let autoCheckPollInterval: TimeInterval = 60 * 60
    /// Launch delay before the first auto-check attempt.
    static let launchCheckDelay: TimeInterval = 15
    static let lastCheckKey = "updateLastCheckAt"

    private let checker: UpdateCheckerProtocol
    private let installer: UpdateInstallerProtocol
    private let defaults: UserDefaults
    private var autoCheckTask: Task<Void, Never>?

    init(
        checker: UpdateCheckerProtocol = UpdateChecker(),
        installer: UpdateInstallerProtocol = UpdateInstaller(),
        defaults: UserDefaults = .standard,
        currentVersion: String? = nil
    ) {
        self.checker = checker
        self.installer = installer
        self.defaults = defaults
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    // MARK: - Scheduling

    /// Launch-time auto-check (after a small delay) plus a low-frequency loop
    /// that re-checks once `autoCheckInterval` has elapsed while running.
    func startAutoCheck() {
        guard autoCheckTask == nil else { return }
        autoCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchCheckDelay))
            while !Task.isCancelled {
                guard let self else { return }
                await self.autoCheckIfDue()
                try? await Task.sleep(for: .seconds(Self.autoCheckPollInterval))
            }
        }
    }

    func stopAutoCheck() {
        autoCheckTask?.cancel()
        autoCheckTask = nil
    }

    /// Automatic check, throttled to at most once per `autoCheckInterval`.
    /// Returns whether a check actually ran.
    @discardableResult
    func autoCheckIfDue(now: Date = Date()) async -> Bool {
        let last = defaults.double(forKey: Self.lastCheckKey)
        guard now.timeIntervalSince1970 - last >= Self.autoCheckInterval else { return false }
        await performCheck(now: now)
        return true
    }

    /// Manual "Check for updates": bypasses the 24h throttle.
    func checkNow() async {
        await performCheck(now: Date())
    }

    private func performCheck(now: Date) async {
        // Never stomp an install already in flight.
        switch state {
        case .downloading, .installing: return
        default: break
        }
        state = .checking
        // Recorded per attempt (not per success) so repeated failures never
        // hammer the unauthenticated GitHub API.
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
        do {
            if let info = try await checker.checkLatest() {
                state = .available(info)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    // MARK: - Install

    /// Download + install + relaunch for the currently-available update.
    /// No-op unless `state` is `.available`. Every failure lands in
    /// `.failed` with a user-readable message; the relaunch (which terminates
    /// this process) only happens after the swap-install fully succeeded.
    func installAvailableUpdate() async {
        guard case .available(let info) = state else { return }
        state = .downloading(nil)
        do {
            let dmg = try await installer.download(from: info.dmgURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.noteDownloadProgress(fraction)
                }
            }
            state = .installing
            try await installer.install(dmgAt: dmg)
            installer.relaunchInstalledApp()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Late progress callbacks (already-hopped tasks) are dropped once the
    /// pipeline has moved past the download phase.
    private func noteDownloadProgress(_ fraction: Double?) {
        guard case .downloading = state else { return }
        state = .downloading(fraction)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
