import Foundation

/// GitHub Releases update check.
///
/// Trust model: the check and the download both target the pinned
/// RoodsBurger/RaiUsage repository over HTTPS (api.github.com). Releases
/// are ad-hoc-signed DMGs with no notarization and no signature feed, so TLS
/// plus the hardcoded owner/repo is the whole chain of trust - acceptable
/// for a personal fork, not for broad distribution.
final class UpdateChecker: UpdateCheckerProtocol, @unchecked Sendable {
    /// GitHub REST "get latest release" for the pinned repo. Unauthenticated;
    /// `UpdateStore`'s 24h auto-check throttle keeps usage far below the
    /// anonymous rate limit.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/RoodsBurger/RaiUsage/releases/latest")!

    private let currentVersion: String

    init(currentVersion: String? = nil) {
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    func checkLatest() async throws -> UpdateInfo? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckerError.badResponse
        }
        // 403/429 with an exhausted anonymous quota is the common case on a
        // shared (corporate NAT) IP - surface it as its own message rather
        // than a scary generic failure. GitHub signals it via the
        // x-ratelimit-remaining header.
        if http.statusCode == 403 || http.statusCode == 429 {
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if remaining == "0" || http.statusCode == 429 {
                throw UpdateCheckerError.rateLimited
            }
            throw UpdateCheckerError.httpStatus(http.statusCode)
        }
        guard http.statusCode == 200 else {
            throw UpdateCheckerError.httpStatus(http.statusCode)
        }
        return try Self.updateInfo(from: data, currentVersion: currentVersion)
    }

    /// Pure decode + version-compare step, separated from the network call so
    /// tests can drive it with fixture JSON.
    static func updateInfo(from data: Data, currentVersion: String) throws -> UpdateInfo? {
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw UpdateCheckerError.badResponse
        }
        guard UpdateVersion.isNewer(release.tagName, than: currentVersion) else { return nil }
        guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            throw UpdateCheckerError.noDMGAsset
        }
        return UpdateInfo(
            version: UpdateVersion.normalized(release.tagName),
            releaseURL: release.htmlURL,
            dmgURL: dmg.browserDownloadURL
        )
    }
}
