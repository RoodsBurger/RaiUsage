import Foundation

enum UpdateCheckerError: LocalizedError, Equatable {
    case badResponse
    case noDMGAsset

    var errorDescription: String? {
        switch self {
        case .badResponse: String(localized: "update.error.badresponse")
        case .noDMGAsset:  String(localized: "update.error.noasset")
        }
    }
}

protocol UpdateCheckerProtocol: Sendable {
    /// The latest published release, resolved against the running version.
    /// nil means already up to date. Throws on network/decode failure and
    /// when a newer release carries no installable `.dmg` asset (fail-closed).
    func checkLatest() async throws -> UpdateInfo?
}
