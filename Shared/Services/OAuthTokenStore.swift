import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.raiusage.app", category: "OAuthTokenStore")

enum OAuthTokenStoreError: Error, Equatable, CustomStringConvertible {
    case encodeFailed
    case fileWriteFailed(String)

    var description: String {
        switch self {
        case .encodeFailed: return "Failed to encode OAuth tokens"
        case .fileWriteFailed(let reason): return "Token file write failed (\(reason))"
        }
    }
}

/// File-backed store for the app-owned "Sign in with Claude" tokens.
///
/// The tokens live in a 0600 JSON file instead of the Keychain because the
/// app has no stable code-signing identity (ad-hoc signatures change on every
/// build/update), so a Keychain item's ACL stops matching after each update
/// and silent reads fail - which used to drop the login. A user-only file
/// survives re-signing; this matches how Claude Code itself stores
/// `~/.claude/.credentials.json` on non-Keychain platforms. A legacy Keychain
/// item from earlier versions is migrated into the file on first load, then
/// deleted.
final class OAuthTokenStore: OAuthTokenStoreProtocol {
    // MARK: - Legacy Keychain (migration only)

    /// Seam for the pre-file-store Keychain item, injectable for tests.
    struct LegacyKeychain {
        let load: () -> Data?
        let delete: () -> Void

        static let real = LegacyKeychain(
            load: {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacyService,
                    kSecAttrAccount as String: legacyAccount,
                    kSecReturnData as String: true,
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
                ]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else { return nil }
                return data
            },
            delete: {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacyService,
                    kSecAttrAccount as String: legacyAccount
                ]
                _ = SecItemDelete(query as CFDictionary)
            }
        )

        static let none = LegacyKeychain(load: { nil }, delete: {})
    }

    private static let legacyService = "com.raiusage.oauth"
    private static let legacyAccount = "claude"

    // MARK: - State

    private let fileURL: URL
    private let legacyKeychain: LegacyKeychain

    init(fileURL: URL = OAuthTokenStore.defaultFileURL(), legacyKeychain: LegacyKeychain = .real) {
        self.fileURL = fileURL
        self.legacyKeychain = legacyKeychain
    }

    /// `~/Library/Application Support/com.raiusage.auth/oauth-tokens.json`.
    /// Deliberately NOT inside `com.raiusage.shared`: that directory is a
    /// wipeable cache (the dev build-nuke flow deletes it), and the login must
    /// survive a cache wipe. Real home via `getpwuid` - see `SharedFileService`.
    static func defaultFileURL() -> URL {
        let home: String
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent("com.raiusage.auth")
            .appendingPathComponent("oauth-tokens.json")
    }

    // MARK: - Protocol Methods

    func load() -> OAuthTokens? {
        if let data = try? Data(contentsOf: fileURL), let tokens = Self.decode(data) {
            return tokens
        }
        return migrateFromLegacyKeychain()
    }

    func save(_ tokens: OAuthTokens) throws {
        guard let data = try? Self.encode(tokens) else {
            throw OAuthTokenStoreError.encodeFailed
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
            // Atomic replace creates a fresh file; restrict it to the user.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw OAuthTokenStoreError.fileWriteFailed(error.localizedDescription)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        legacyKeychain.delete()
    }

    // MARK: - Legacy Migration

    /// One-time move of tokens saved by earlier Keychain-backed versions into
    /// the file. The Keychain item is deleted only after the file write
    /// succeeds, so a failed write never loses the tokens.
    private func migrateFromLegacyKeychain() -> OAuthTokens? {
        guard let data = legacyKeychain.load(), let tokens = Self.decode(data) else { return nil }
        do {
            try save(tokens)
        } catch {
            logger.info("Legacy Keychain migration deferred - file write failed")
            return tokens
        }
        legacyKeychain.delete()
        logger.info("OAuth tokens migrated from Keychain to file store")
        return tokens
    }

    // MARK: - Internal Codec

    /// Encodes OAuthTokens to JSON Data using epoch-seconds date strategy.
    static func encode(_ tokens: OAuthTokens) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(tokens)
    }

    /// Decodes OAuthTokens from JSON Data using epoch-seconds date strategy.
    /// Returns nil if decoding fails.
    static func decode(_ data: Data) -> OAuthTokens? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(OAuthTokens.self, from: data)
    }
}
