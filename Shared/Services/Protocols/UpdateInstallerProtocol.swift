import Foundation

enum UpdateInstallerError: LocalizedError {
    case downloadFailed(String)
    case appNotFoundInDMG
    case commandFailed(tool: String, message: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            String(format: String(localized: "update.error.download"), detail)
        case .appNotFoundInDMG:
            String(localized: "update.error.noappindmg")
        case .commandFailed(let tool, let message):
            String(format: String(localized: "update.error.command"), tool, message)
        }
    }
}

protocol UpdateInstallerProtocol: Sendable {
    /// Downloads the DMG to a temporary file and returns its location.
    /// `onProgress` receives a 0...1 fraction, or nil while the total size is
    /// unknown; it may be called from any thread.
    func download(from url: URL, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL
    /// Mounts the DMG and swap-installs the app bundle into /Applications.
    func install(dmgAt dmgURL: URL) async throws
    /// Spawns a detached relauncher for the installed app, then terminates
    /// this process. Only called after `install` succeeds.
    func relaunchInstalledApp()
}
