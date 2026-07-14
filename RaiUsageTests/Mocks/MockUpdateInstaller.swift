import Foundation

final class MockUpdateInstaller: UpdateInstallerProtocol, @unchecked Sendable {
    var stubbedDownloadError: Error?
    var stubbedInstallError: Error?
    /// Progress fractions replayed into `onProgress` during `download`.
    var progressEvents: [Double?] = []
    /// While true, `download` spins (yielding) before returning, so a test
    /// can observe the store mid-download.
    var holdDownload = false

    private(set) var downloadedURLs: [URL] = []
    private(set) var installedDMGs: [URL] = []
    private(set) var relaunchCallCount = 0

    func download(from url: URL, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        downloadedURLs.append(url)
        if let stubbedDownloadError { throw stubbedDownloadError }
        for event in progressEvents {
            onProgress(event)
            // Drain the main actor so the store's progress hop lands while
            // the download is still in flight (deterministic state capture).
            await MainActor.run {}
        }
        while holdDownload { await Task.yield() }
        return URL(fileURLWithPath: "/tmp/mock-update.dmg")
    }

    func install(dmgAt dmgURL: URL) async throws {
        installedDMGs.append(dmgURL)
        if let stubbedInstallError { throw stubbedInstallError }
    }

    func relaunchInstalledApp() {
        relaunchCallCount += 1
    }
}
