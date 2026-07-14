import Foundation

/// A newer release published on GitHub, resolved by `UpdateChecker`.
struct UpdateInfo: Equatable {
    /// Normalized version with no leading "v" (e.g. "5.9.0").
    let version: String
    /// The release's GitHub page (release notes).
    let releaseURL: URL
    /// Direct download URL of the release's `.dmg` asset.
    let dmgURL: URL
}

/// Update pipeline state published by `UpdateStore`.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateInfo)
    /// Download in flight; fraction is 0...1, nil while the size is unknown.
    case downloading(Double?)
    case installing
    case failed(String)
}

/// Subset of the GitHub REST "get latest release" payload the updater needs.
struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}
