import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.raiusage.app", category: "TokenProvider")

final class TokenProvider: TokenProviderProtocol, @unchecked Sendable {
    private let securityCLIReader: SecurityCLIReaderProtocol
    private let credentialsFileReader: CredentialsFileReaderProtocol
    private let configReader: ClaudeConfigReaderProtocol
    private let decryptionService: ElectronDecryptionServiceProtocol
    private let keychainReader: KeychainTokenReader
    private let oauthService: OAuthServiceProtocol
    private let oauthTokenStore: OAuthTokenStoreProtocol
    private let now: () -> Date

    /// In-memory token cache - avoids hitting the Keychain on every refresh.
    /// Cleared on 401 (token expired) via `invalidateToken()` and on
    /// `disconnectOAuth()`. `TokenProvider` is `@unchecked Sendable` and
    /// `performOAuthRefresh`'s completion can resume off the calling actor,
    /// so reads/writes go through `cacheLock` rather than the bare property.
    private let cacheLock = NSLock()
    private var _cachedToken: String?
    private var cachedToken: String? {
        get { cacheLock.lock(); defer { cacheLock.unlock() }; return _cachedToken }
        set { cacheLock.lock(); defer { cacheLock.unlock() }; _cachedToken = newValue }
    }

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
        oauthImportFileURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.securityCLIReader = securityCLIReader
        self.credentialsFileReader = credentialsFileReader
        self.configReader = configReader
        self.decryptionService = decryptionService
        self.keychainReader = keychainReader ?? Self.defaultKeychainReader
        self.oauthService = oauthService
        self.oauthTokenStore = oauthTokenStore
        self.now = now
        Self.importPendingOAuthTokensIfNeeded(
            fileURL: oauthImportFileURL ?? Self.defaultOAuthImportFileURL(),
            store: oauthTokenStore
        )
    }

    var isBootstrapped: Bool { true }

    /// Whether any usable token source exists. A borrowed credential is only
    /// counted while it is not hard-expired: borrowed refresh tokens are never
    /// redeemed (see `firstUsableBorrowedCredential`), so an expired credential
    /// resolves to nil in `currentToken()` and onboarding must not report
    /// "Claude Code detected" for it.
    ///
    /// The config.json source stays a presence check (`readEncryptedToken`)
    /// rather than a decrypt-and-inspect, so a present Claude Desktop config
    /// is never hidden just because its decryption key hasn't been loaded
    /// yet. A config credential that decrypts to a dead token is therefore
    /// still counted here - a narrower version of the same inconsistency,
    /// deferred.
    func hasTokenSource() -> Bool {
        if oauthTokenStore.load() != nil { return true }
        if cachedToken != nil { return true }
        if securityCLIReader.readCredential()?.isExpired() == false { return true }
        if credentialsFileReader.readCredential()?.isExpired() == false { return true }
        if configReader.readEncryptedToken() != nil { return true }
        if keychainReader(true) != nil { return true }
        return false
    }

    /// Returns the current token. This is synchronous and never touches the
    /// network: OAuth tokens (source 0, this app's own authorization) take
    /// priority whenever they exist and the stored access token is returned
    /// as-is, even if near expiry - the proactive/reactive refresh runs on the
    /// async paths (`refreshOAuthTokenIfNeeded`, `handleUnauthorizedOAuth`),
    /// not here. Only when no OAuth tokens exist at all does this fall back to
    /// the borrowed source chain, using the in-memory cache so the Keychain is
    /// only read when the cache is empty (app start, or after
    /// `invalidateToken()`).
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
            cachedToken = tokens.accessToken
            return tokens.accessToken
        }

        let token = readFromSources()
        cachedToken = token
        return token
    }

    /// Proactively refreshes the OAuth token when it's near expiry. Callers
    /// await this once per refresh tick before reading the token so a
    /// near-expiry token is renewed ahead of the fetch. Borrowed sources are
    /// strictly read-only - their refresh tokens belong to Claude Code /
    /// Claude Desktop and redeeming one would invalidate it server-side for
    /// that app (refresh tokens rotate on use), so with no app-owned tokens
    /// this is a pure no-op returning false.
    func refreshOAuthTokenIfNeeded() async -> Bool {
        guard let tokens = oauthTokenStore.load() else { return false }
        guard tokens.needsRefresh() else {
            cachedToken = tokens.accessToken
            return true
        }
        return await performOAuthRefresh(tokens)
    }

    /// Forces one OAuth refresh after a 401, regardless of local expiry: the
    /// server rejected a token whose local `expiresAt` may still be in the
    /// future. No-op returning false for borrowed sources - the 401 caller
    /// then falls back to `invalidateToken` + a borrowed re-read.
    func handleUnauthorizedOAuth() async -> Bool {
        guard let tokens = oauthTokenStore.load() else { return false }
        return await performOAuthRefresh(tokens)
    }

    // MARK: - Refresh Failure Gate

    /// Backoff state for token-endpoint refresh exchanges, guarded by
    /// `cacheLock`. Without it, a dead refresh token turns every tick into
    /// 1-2 token-endpoint POSTs (proactive + 401 handler) forever - enough to
    /// trip Anthropic's account-level login rate limit and block the user's
    /// own re-authorization ("you have reached the rate limit for login").
    private var _refreshTokenDead = false
    private var _consecutiveRefreshFailures = 0
    private var _refreshRetryAt: Date?

    /// Transient-failure ladder: 60s doubling to a 1h cap.
    private static let refreshBackoffBase: TimeInterval = 60
    private static let refreshBackoffCap: TimeInterval = 3600

    /// Whether a refresh exchange may hit the network right now.
    private func refreshGateAllows() -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if _refreshTokenDead { return false }
        if let retryAt = _refreshRetryAt, now() < retryAt { return false }
        return true
    }

    /// Records a refresh outcome. A definitive 4xx (except 429) means the
    /// refresh token is dead - invalid_grant or revoked - and retrying can
    /// never succeed, so the gate closes until a new login or disconnect.
    /// Everything else (transport failure, 5xx, 429) is transient and backs
    /// off exponentially.
    private func noteRefreshOutcome(_ result: Result<OAuthTokens, OAuthError>) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        switch result {
        case .success:
            _refreshTokenDead = false
            _consecutiveRefreshFailures = 0
            _refreshRetryAt = nil
        case .failure(let error):
            if case .refreshFailed(let status) = error, (400...499).contains(status), status != 429 {
                _refreshTokenDead = true
                logger.info("OAuth refresh rejected (\(status)) - refresh token is dead, stopping automatic retries")
                return
            }
            _consecutiveRefreshFailures += 1
            let exponent = Double(_consecutiveRefreshFailures - 1)
            let delay = min(Self.refreshBackoffBase * pow(2, exponent), Self.refreshBackoffCap)
            _refreshRetryAt = now().addingTimeInterval(delay)
            logger.info("OAuth refresh failed transiently - backing off \(Int(delay))s")
        }
    }

    /// Reopens the gate after the stored token set changes (fresh login or
    /// sign-out): the failure history belonged to the previous refresh token.
    private func resetRefreshGate() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        _refreshTokenDead = false
        _consecutiveRefreshFailures = 0
        _refreshRetryAt = nil
    }

    /// Runs one OAuth refresh exchange, awaiting the completion-based
    /// `oauthService.refresh` via a checked continuation - no run-loop pump,
    /// no semaphore. Skipped without network while the failure gate is closed
    /// (dead refresh token, or inside a transient backoff window). The new
    /// tokens are saved to the store inside the completion so a
    /// slow-but-successful refresh can never be dropped by a timeout. On
    /// success the in-memory cache is updated so the next `currentToken()`
    /// returns the fresh access token. A failure leaves the stored tokens
    /// untouched (the access token keeps being served until a hard 401).
    private func performOAuthRefresh(_ tokens: OAuthTokens) async -> Bool {
        guard refreshGateAllows() else { return false }
        let result: Result<OAuthTokens, OAuthError> = await withCheckedContinuation { continuation in
            self.oauthService.refresh(tokens) { result in
                if case .success(let newTokens) = result {
                    try? self.oauthTokenStore.save(newTokens)
                }
                continuation.resume(returning: result)
            }
        }
        noteRefreshOutcome(result)
        guard case .success(let refreshed) = result else {
            logger.info("OAuth refresh failed - keeping existing access token")
            return false
        }
        cachedToken = refreshed.accessToken
        logger.info("OAuth token refreshed")
        return true
    }

    /// Reads the token from all sources in priority order, bypassing the
    /// in-memory cache. Returns the freshest usable token currently on the
    /// system - an expired source is skipped in favor of a live one further
    /// down the chain rather than being returned as-is.
    private func readFromSources() -> String? {
        firstUsableBorrowedCredential()?.accessToken
    }

    /// Walks the borrowed sources in priority order (`/usr/bin/security`,
    /// `.credentials.json`, Claude Desktop `config.json`, direct Keychain
    /// read) and returns the first non-expired credential, skipping any whose
    /// `expiresAt` is already in the past so a dead token never wins over a
    /// live one further down the chain. The direct-Keychain last resort
    /// carries no expiry information, so it is always usable when present.
    ///
    /// Strictly read-only: a borrowed credential's refresh token is NEVER
    /// exchanged. Refresh tokens rotate on use, so redeeming one invalidates
    /// it for the app that minted it (Claude Code / Claude Desktop) - that
    /// app's next refresh then trips the server's reuse detection, both token
    /// families die, and the resulting re-login storm hits Anthropic's login
    /// rate limit. An expired borrowed source simply resolves to nil until
    /// its owner refreshes it.
    private func firstUsableBorrowedCredential() -> BorrowedCredential? {
        // Each source is read at its own call site (not collected into a
        // literal array first) so a hit on an earlier source short-circuits
        // before a later source's work runs - notably, config.json decryption
        // must not run when the security CLI or credentials file already
        // produced a usable credential.
        func consider(_ label: String, _ credential: BorrowedCredential?) -> BorrowedCredential? {
            guard let credential else { return nil }
            guard !credential.isExpired() else {
                logger.info("Skipping expired borrowed token from \(label, privacy: .public)")
                return nil
            }
            logger.info("Token read via \(label, privacy: .public)")
            return credential
        }

        return consider("/usr/bin/security", securityCLIReader.readCredential())
            ?? consider(".credentials.json", credentialsFileReader.readCredential())
            ?? consider("config.json", credentialFromConfigJSON())
            ?? keychainReader(true).map { token in
                logger.info("Token read from Keychain (silent)")
                return BorrowedCredential(accessToken: token, refreshToken: nil, expiresAt: nil)
            }
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
    ///
    /// OAuth tokens are authoritative: while they exist this never reconciles
    /// against the borrowed chain (nor reads it), so a borrowed token from a
    /// *different* account can never silently replace the app's own OAuth token
    /// on a tick.
    func refreshTokenIfChanged() -> Bool {
        if oauthTokenStore.load() != nil { return false }
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

    /// Try to decrypt config.json and surface the full credential (including
    /// expiry, when the decrypted blob carries `claudeAiOauth.expiresAt`). If
    /// key is missing, attempt silent re-bootstrap.
    private func credentialFromConfigJSON() -> BorrowedCredential? {
        guard let encrypted = configReader.readEncryptedToken() else { return nil }

        if decryptionService.hasEncryptionKey,
           let credential = decryptCredentialFromConfigJSON(encrypted) {
            return credential
        }

        if decryptionService.trySilentRebootstrap(),
           let credential = decryptCredentialFromConfigJSON(encrypted) {
            logger.info("Token recovered via silent re-bootstrap of decryption key")
            return credential
        }

        return nil
    }

    /// Call this after a 401 - clears the in-memory cache so the next
    /// `currentToken()` re-reads its source (a rotated borrowed token, or the
    /// stored OAuth token, possibly just renewed by `handleUnauthorizedOAuth`).
    /// Synchronous and network-free: the OAuth refresh-on-401 is a separate
    /// async step the caller awaits, so non-401 callers (`handleTokenChange`,
    /// "Retry now") that only invalidate never rotate the refresh token.
    func invalidateToken() {
        cachedToken = nil
        logger.info("Token cache invalidated - next read will check its source")
    }

    /// Signs out of the app-owned OAuth tokens. The next `currentToken()`
    /// falls back to the borrowed source chain.
    func disconnectOAuth() {
        oauthTokenStore.clear()
        cachedToken = nil
        resetRefreshGate()
        logger.info("OAuth disconnected - falling back to borrowed token sources")
    }

    /// Saves tokens from a just-completed "Sign in with Claude" login and
    /// updates the in-memory cache so the access token is available
    /// immediately, ahead of any borrowed-source cache invalidation. A save
    /// failure (e.g. a Keychain error) leaves the cache untouched and
    /// propagates to the caller so the Connect UI can surface it.
    func completeOAuthLogin(_ tokens: OAuthTokens) throws {
        try oauthTokenStore.save(tokens)
        cachedToken = tokens.accessToken
        resetRefreshGate()
        logger.info("OAuth login completed - tokens saved to app-owned store")
    }

    /// Whether the app-owned OAuth store currently holds a token set.
    func hasOwnOAuthLogin() -> Bool {
        oauthTokenStore.load() != nil
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

    /// `~/Library/Application Support/com.raiusage.shared/oauth-import.json`,
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
            .appendingPathComponent("com.raiusage.shared")
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

    private func decryptCredentialFromConfigJSON(_ encrypted: String) -> BorrowedCredential? {
        do {
            let data = try decryptionService.decrypt(encrypted)
            return Self.extractCredential(from: data)
        } catch {
            return nil
        }
    }

    /// Parses the decrypted config.json blob. The primary shape carries
    /// `claudeAiOauth.{accessToken,refreshToken,expiresAt}` (`expiresAt` in
    /// milliseconds since epoch, like the other borrowed sources); the
    /// UUID-keyed fallback shape only ever carries a bare token with no
    /// expiry or refresh token, so it's surfaced as always-usable, matching
    /// prior behavior.
    private static func extractCredential(from data: Data) -> BorrowedCredential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            let refreshToken = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return BorrowedCredential(accessToken: token, refreshToken: refreshToken, expiresAt: expiresAt)
        }
        for (_, value) in json {
            if let entry = value as? [String: Any],
               let token = entry["token"] as? String,
               token.hasPrefix("sk-ant-") {
                return BorrowedCredential(accessToken: token, refreshToken: nil, expiresAt: nil)
            }
        }
        return nil
    }
}
