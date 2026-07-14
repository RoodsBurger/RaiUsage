import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.tokeneater.app", category: "TokenProvider")

final class TokenProvider: TokenProviderProtocol, @unchecked Sendable {
    private let securityCLIReader: SecurityCLIReaderProtocol
    private let credentialsFileReader: CredentialsFileReaderProtocol
    private let configReader: ClaudeConfigReaderProtocol
    private let decryptionService: ElectronDecryptionServiceProtocol
    private let keychainReader: KeychainTokenReader
    private let oauthService: OAuthServiceProtocol
    private let oauthTokenStore: OAuthTokenStoreProtocol

    /// In-memory token cache - avoids hitting the Keychain on every refresh.
    /// Cleared on 401 (token expired) via `invalidateToken()` and on
    /// `disconnectOAuth()`.
    private var cachedToken: String?

    /// Closure type for reading from the Keychain. `silent` = use kSecUseAuthenticationUISkip.
    typealias KeychainTokenReader = (_ silent: Bool) -> String?

    init(
        securityCLIReader: SecurityCLIReaderProtocol = SecurityCLIReader(),
        credentialsFileReader: CredentialsFileReaderProtocol = CredentialsFileReader(),
        configReader: ClaudeConfigReaderProtocol = ClaudeConfigReader(),
        decryptionService: ElectronDecryptionServiceProtocol = ElectronDecryptionService(),
        keychainReader: KeychainTokenReader? = nil,
        oauthService: OAuthServiceProtocol = OAuthService(),
        oauthTokenStore: OAuthTokenStoreProtocol = OAuthTokenStore(),
        oauthImportFileURL: URL? = nil
    ) {
        self.securityCLIReader = securityCLIReader
        self.credentialsFileReader = credentialsFileReader
        self.configReader = configReader
        self.decryptionService = decryptionService
        self.keychainReader = keychainReader ?? Self.defaultKeychainReader
        self.oauthService = oauthService
        self.oauthTokenStore = oauthTokenStore
        Self.importPendingOAuthTokensIfNeeded(
            fileURL: oauthImportFileURL ?? Self.defaultOAuthImportFileURL(),
            store: oauthTokenStore
        )
    }

    var isBootstrapped: Bool { true }

    func hasTokenSource() -> Bool {
        if oauthTokenStore.load() != nil { return true }
        if cachedToken != nil { return true }
        if securityCLIReader.readToken() != nil { return true }
        if credentialsFileReader.readToken() != nil { return true }
        if configReader.readEncryptedToken() != nil { return true }
        if keychainReader(true) != nil { return true }
        return false
    }

    /// Returns the current token. OAuth tokens (source 0, this app's own
    /// authorization) take priority whenever they exist, refreshing them
    /// first if they're near expiry. Only when no OAuth tokens exist at all
    /// does this fall back to the borrowed source chain, using the in-memory
    /// cache so the Keychain is only read when the cache is empty (app start,
    /// or after `invalidateToken()`).
    ///
    /// Borrowed source priority (v5.0+):
    /// 1. `/usr/bin/security` shell-out (primary - works for all modern Claude Code macOS users,
    ///    no popups across app updates because `security` has a stable Apple signing identity)
    /// 2. `.credentials.json` (legacy Claude Code fallback - still present on Linux/Windows and
    ///    on very old macOS Claude Code installs)
    /// 3. Claude Desktop `config.json` decryption (for users without Claude Code CLI at all)
    /// 4. Direct `SecItemCopyMatching` (last resort - the Claude Code Keychain ACL doesn't
    ///    whitelist us directly, but kept for defence-in-depth)
    func currentToken() -> String? {
        if let token = cachedToken { return token }

        if let tokens = oauthTokenStore.load() {
            let resolved = resolveOAuthAccessToken(tokens)
            cachedToken = resolved
            return resolved
        }

        let token = readFromSources()
        cachedToken = token
        return token
    }

    /// Returns `tokens.accessToken`, refreshing first when near expiry. A
    /// refresh failure keeps serving the existing access token rather than
    /// falling back to the borrowed sources - once OAuth tokens exist they
    /// are authoritative until an explicit `disconnectOAuth()`.
    private func resolveOAuthAccessToken(_ tokens: OAuthTokens) -> String {
        guard tokens.needsRefresh() else { return tokens.accessToken }
        guard let refreshed = synchronousRefresh(tokens) else {
            logger.info("OAuth refresh failed - keeping existing access token until a hard 401")
            return tokens.accessToken
        }
        try? oauthTokenStore.save(refreshed)
        logger.info("OAuth token refreshed proactively (near expiry)")
        return refreshed.accessToken
    }

    /// Reads the token from all sources in priority order, bypassing the
    /// in-memory cache. Returns the freshest token currently on the system.
    private func readFromSources() -> String? {
        if let token = securityCLIReader.readToken() {
            logger.info("Token read via /usr/bin/security")
            return token
        }

        if let token = credentialsFileReader.readToken() {
            return token
        }

        if let token = tokenFromConfigJSON() {
            return token
        }

        if let token = keychainReader(true) {
            logger.info("Token read from Keychain (silent)")
            return token
        }

        return nil
    }

    /// Re-reads the token from its sources and updates the cache when it
    /// changed. The file watcher only sees `config.json` / `.credentials.json`,
    /// but on modern macOS the active token lives in the Keychain - so a
    /// `cswap`/`claude login` account swap rotates the Keychain item with no
    /// filesystem event and the cache would otherwise keep serving the previous
    /// account's token until a 401. Polling here (on the auto-refresh tick)
    /// closes that gap. Returns true only on an actual change between two
    /// non-nil tokens; first population and transient read failures return false
    /// so a working token is never dropped.
    func refreshTokenIfChanged() -> Bool {
        guard let fresh = readFromSources() else { return false }
        let previous = cachedToken
        cachedToken = fresh
        guard let previous else { return false }
        if previous != fresh {
            logger.info("Token changed on Keychain/disk - cache refreshed for new account")
            return true
        }
        return false
    }

    /// Try to decrypt config.json. If key is missing, attempt silent re-bootstrap.
    private func tokenFromConfigJSON() -> String? {
        guard let encrypted = configReader.readEncryptedToken() else { return nil }

        if decryptionService.hasEncryptionKey,
           let token = decryptFromConfigJSON(encrypted) {
            return token
        }

        if decryptionService.trySilentRebootstrap(),
           let token = decryptFromConfigJSON(encrypted) {
            logger.info("Token recovered via silent re-bootstrap of decryption key")
            return token
        }

        return nil
    }

    /// Call this after a 401. When OAuth tokens are present this makes one
    /// synchronous refresh attempt: success saves the new tokens and caches
    /// the new access token so the caller's immediate retry picks it up;
    /// failure clears the cache and leaves the stored OAuth tokens as-is, so
    /// the next `currentToken()` sees the same still-unrefreshed access token
    /// and the caller's existing "no improvement" handling surfaces the
    /// token-expired error path. With no OAuth tokens, clears the cache so
    /// the next `currentToken()` re-reads the borrowed sources.
    func invalidateToken() {
        if let tokens = oauthTokenStore.load() {
            if let refreshed = synchronousRefresh(tokens) {
                try? oauthTokenStore.save(refreshed)
                cachedToken = refreshed.accessToken
                logger.info("OAuth token refreshed after a 401")
            } else {
                cachedToken = nil
                logger.info("OAuth refresh failed after a 401 - token expired")
            }
            return
        }
        cachedToken = nil
        logger.info("Token cache invalidated - next read will check Keychain")
    }

    /// Signs out of the app-owned OAuth tokens. The next `currentToken()`
    /// falls back to the borrowed source chain.
    func disconnectOAuth() {
        oauthTokenStore.clear()
        cachedToken = nil
        logger.info("OAuth disconnected - falling back to borrowed token sources")
    }

    // MARK: - OAuth Refresh (sync bridge)

    /// Bridges `oauthService.refresh`'s completion-based API to a bounded
    /// synchronous return. `OAuthService` always delivers its completion via
    /// `DispatchQueue.main.async` once its transport responds on a background
    /// queue, so a plain semaphore wait here would deadlock (or just burn the
    /// full timeout) when called from the main thread - the main queue can't
    /// drain that block while this call blocks it. On the main thread this
    /// pumps the run loop instead, which still processes queued main-queue
    /// blocks; off the main thread a semaphore wait is used as normal.
    private func synchronousRefresh(_ tokens: OAuthTokens, timeout: TimeInterval = 15) -> OAuthTokens? {
        if Thread.isMainThread {
            return synchronousRefreshOnMainThread(tokens, timeout: timeout)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var refreshed: OAuthTokens?
        oauthService.refresh(tokens) { result in
            if case .success(let newTokens) = result { refreshed = newTokens }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return refreshed
    }

    private func synchronousRefreshOnMainThread(_ tokens: OAuthTokens, timeout: TimeInterval) -> OAuthTokens? {
        var finished = false
        var refreshed: OAuthTokens?
        oauthService.refresh(tokens) { result in
            if case .success(let newTokens) = result { refreshed = newTokens }
            finished = true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.02), deadline))
        }
        return refreshed
    }

    // MARK: - One-Time OAuth Import

    /// Imports a pre-minted OAuth token file dropped at `fileURL` (same JSON
    /// shape `OAuthTokenStore` persists) into `store`, then deletes the file
    /// so the import runs exactly once. Leaves the file untouched on any
    /// read/decode/save failure. Never logs token material.
    private static func importPendingOAuthTokensIfNeeded(fileURL: URL, store: OAuthTokenStoreProtocol) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let tokens = OAuthTokenStore.decode(data) else { return }
        do {
            try store.save(tokens)
        } catch {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// `~/Library/Application Support/com.tokeneater.shared/oauth-import.json`,
    /// resolved via the real home directory (`getpwuid`) rather than
    /// `FileManager.homeDirectoryForCurrentUser`, which returns the sandbox
    /// container path inside the widget - see `SharedFileService`.
    private static func defaultOAuthImportFileURL() -> URL {
        let home: String
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent("com.tokeneater.shared")
            .appendingPathComponent("oauth-import.json")
    }

    func bootstrap() throws {
        if let token = keychainReader(false) {
            cachedToken = token
            logger.info("Bootstrap succeeded via interactive Keychain read")
        }

        do {
            try decryptionService.bootstrapEncryptionKey()
        } catch {
            logger.info("Decryption key bootstrap skipped: \(error)")
        }
    }

    // MARK: - Keychain (static, no instance state)

    private static func defaultKeychainReader(silent: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if silent {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }

        return token
    }

    // MARK: - Config.json Decryption (fallback)

    private func decryptFromConfigJSON(_ encrypted: String) -> String? {
        do {
            let data = try decryptionService.decrypt(encrypted)
            return Self.extractToken(from: data)
        } catch {
            return nil
        }
    }

    private static func extractToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        for (_, value) in json {
            if let entry = value as? [String: Any],
               let token = entry["token"] as? String,
               token.hasPrefix("sk-ant-") {
                return token
            }
        }
        return nil
    }
}
