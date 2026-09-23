import Foundation
import os.log

private let logger = Logger(subsystem: "com.raiusage.app", category: "TokenProvider")

/// Resolves the app's own "Sign in with Claude" OAuth tokens - the single
/// auth path. Borrowing Claude Code / Claude Desktop credentials is gone:
/// serving another app's token invited expiry races, and its refresh token
/// could never be redeemed safely (refresh tokens rotate on use, so a
/// redemption invalidates the owner's copy and the reuse-detection fallout
/// kills both token families - the login-rate-limit storm this replaced).
final class TokenProvider: TokenProviderProtocol, @unchecked Sendable {
    private let oauthService: OAuthServiceProtocol
    private let oauthTokenStore: OAuthTokenStoreProtocol
    private let now: () -> Date

    /// In-memory access-token cache - avoids re-reading the store on every
    /// call. Cleared on 401 via `invalidateToken()` and on `disconnectOAuth()`.
    /// `TokenProvider` is `@unchecked Sendable` and `performOAuthRefresh`'s
    /// completion can resume off the calling actor, so reads/writes go through
    /// `cacheLock` rather than the bare property.
    private let cacheLock = NSLock()
    private var _cachedToken: String?
    private var cachedToken: String? {
        get { cacheLock.lock(); defer { cacheLock.unlock() }; return _cachedToken }
        set { cacheLock.lock(); defer { cacheLock.unlock() }; _cachedToken = newValue }
    }

    init(
        oauthService: OAuthServiceProtocol = OAuthService(),
        oauthTokenStore: OAuthTokenStoreProtocol = OAuthTokenStore(),
        oauthImportFileURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.oauthService = oauthService
        self.oauthTokenStore = oauthTokenStore
        self.now = now
        Self.importPendingOAuthTokensIfNeeded(
            fileURL: oauthImportFileURL ?? Self.defaultOAuthImportFileURL(),
            store: oauthTokenStore
        )
    }

    /// Returns the current access token. Synchronous and network-free: the
    /// stored access token is returned as-is even near expiry - the
    /// proactive/reactive refresh runs on the async paths
    /// (`refreshOAuthTokenIfNeeded`, `handleUnauthorizedOAuth`), not here.
    func currentToken() -> String? {
        if let token = cachedToken { return token }
        guard let tokens = oauthTokenStore.load() else { return nil }
        cachedToken = tokens.accessToken
        return tokens.accessToken
    }

    /// Proactively refreshes the OAuth token when it's near expiry. Callers
    /// await this once per refresh tick before reading the token so a
    /// near-expiry token is renewed ahead of the fetch. No-op returning false
    /// when no login exists.
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
    /// future. No-op returning false when no login exists.
    func handleUnauthorizedOAuth() async -> Bool {
        guard let tokens = oauthTokenStore.load() else { return false }
        cacheLock.lock()
        _rejectedAccessToken = tokens.accessToken
        cacheLock.unlock()
        return await performOAuthRefresh(tokens)
    }

    // MARK: - Refresh Failure Gate

    /// Backoff state for token-endpoint refresh exchanges, guarded by
    /// `cacheLock`. Without it, a dead refresh token turns every tick into
    /// 1-2 token-endpoint POSTs (proactive + 401 handler) forever - enough to
    /// trip Anthropic's account-level login rate limit and block the user's
    /// own re-authorization ("you have reached the rate limit for login").
    ///
    /// Every field is tied to the refresh token it describes, not to this
    /// instance. Settings signs in through its own `TokenProvider`, so a new
    /// login lands in the shared store without calling anything here; keying
    /// on the token means that new refresh token is simply a fresh one, never
    /// blocked by the old one's verdict.
    private var _deadRefreshToken: String?
    private var _backoffRefreshToken: String?
    private var _consecutiveRefreshFailures = 0
    private var _refreshRetryAt: Date?
    /// An access token the server answered 401 to, even if its local expiry
    /// is still in the future.
    private var _rejectedAccessToken: String?

    /// Transient-failure ladder: 60s doubling to a 1h cap.
    private static let refreshBackoffBase: TimeInterval = 60
    private static let refreshBackoffCap: TimeInterval = 3600

    /// Whether `tokens.refreshToken` is known to be unredeemable: rejected by
    /// the server, or past the lifetime the server stated for it.
    private func refreshTokenIsDead(_ tokens: OAuthTokens) -> Bool {
        if let end = tokens.refreshTokenExpiresAt, end <= now() { return true }
        cacheLock.lock(); defer { cacheLock.unlock() }
        return _deadRefreshToken == tokens.refreshToken
    }

    /// Whether a refresh exchange for `tokens` may hit the network right now.
    private func refreshGateAllows(_ tokens: OAuthTokens) -> Bool {
        if refreshTokenIsDead(tokens) { return false }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if _backoffRefreshToken == tokens.refreshToken, let retryAt = _refreshRetryAt, now() < retryAt {
            return false
        }
        return true
    }

    /// Records a refresh outcome for `refreshToken`. Only a definitive 400/401
    /// marks it dead (invalid_grant / expired / revoked - retrying can never
    /// succeed). Everything else - transport failures, 5xx, 429, and
    /// ambiguous statuses like 403 that the endpoint can return while
    /// rate-limiting - is transient and backs off exponentially, so a
    /// server-side blip never strands the app on "Authorization needed".
    private func noteRefreshOutcome(_ result: Result<OAuthTokens, OAuthError>, for refreshToken: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        switch result {
        case .success:
            _deadRefreshToken = nil
            _backoffRefreshToken = nil
            _consecutiveRefreshFailures = 0
            _refreshRetryAt = nil
            _rejectedAccessToken = nil
        case .failure(let error):
            if case .refreshFailed(let status) = error, status == 400 || status == 401 {
                _deadRefreshToken = refreshToken
                logger.info("OAuth refresh rejected (\(status)) - refresh token is dead, stopping automatic retries")
                return
            }
            if _backoffRefreshToken != refreshToken {
                _backoffRefreshToken = refreshToken
                _consecutiveRefreshFailures = 0
            }
            _consecutiveRefreshFailures += 1
            let exponent = Double(_consecutiveRefreshFailures - 1)
            let delay = min(Self.refreshBackoffBase * pow(2, exponent), Self.refreshBackoffCap)
            _refreshRetryAt = now().addingTimeInterval(delay)
            logger.info("OAuth refresh failed transiently - backing off \(Int(delay))s")
        }
    }

    /// Clears all failure history after a login or sign-out on this instance.
    private func resetRefreshGate() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        _deadRefreshToken = nil
        _backoffRefreshToken = nil
        _consecutiveRefreshFailures = 0
        _refreshRetryAt = nil
        _rejectedAccessToken = nil
    }

    /// True when the stored session can no longer produce a working access
    /// token without the user signing in again: the access token is expired
    /// (or the server rejected it) and its refresh token is dead. Callers stop
    /// polling on this - every request with a dead session is a guaranteed 401
    /// that still counts against the usage endpoint's rate limit.
    var needsReauthorization: Bool {
        guard let tokens = oauthTokenStore.load() else { return false }
        let accessRejected: Bool = {
            cacheLock.lock(); defer { cacheLock.unlock() }
            return _rejectedAccessToken == tokens.accessToken
        }()
        guard tokens.expiresAt <= now() || accessRejected else { return false }
        return refreshTokenIsDead(tokens)
    }

    /// When the stored sign-in session ends, if the server said.
    var sessionExpiresAt: Date? {
        oauthTokenStore.load()?.refreshTokenExpiresAt
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
        guard refreshGateAllows(tokens) else { return false }
        let result: Result<OAuthTokens, OAuthError> = await withCheckedContinuation { continuation in
            self.oauthService.refresh(tokens) { result in
                if case .success(let newTokens) = result {
                    try? self.oauthTokenStore.save(newTokens)
                }
                continuation.resume(returning: result)
            }
        }
        noteRefreshOutcome(result, for: tokens.refreshToken)
        guard case .success(let refreshed) = result else {
            logger.info("OAuth refresh failed - keeping existing access token")
            return false
        }
        cachedToken = refreshed.accessToken
        logger.info("OAuth token refreshed")
        return true
    }

    /// Call this after a 401 - clears the in-memory cache so the next
    /// `currentToken()` re-reads the store (possibly just renewed by
    /// `handleUnauthorizedOAuth`). Synchronous and network-free.
    func invalidateToken() {
        cachedToken = nil
        logger.info("Token cache invalidated - next read will check the store")
    }

    /// Signs out: clears the stored tokens and the cache.
    func disconnectOAuth() {
        oauthTokenStore.clear()
        cachedToken = nil
        resetRefreshGate()
        logger.info("OAuth disconnected - token store cleared")
    }

    /// Saves tokens from a just-completed "Sign in with Claude" login and
    /// updates the in-memory cache so the access token is available
    /// immediately. A save failure leaves the cache untouched and propagates
    /// to the caller so the Connect UI can surface it.
    func completeOAuthLogin(_ tokens: OAuthTokens) throws {
        try oauthTokenStore.save(tokens)
        cachedToken = tokens.accessToken
        resetRefreshGate()
        logger.info("OAuth login completed - tokens saved to app-owned store")
    }

    /// Whether the app currently holds a token set.
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
    /// `FileManager.homeDirectoryForCurrentUser`, which can return a sandbox
    /// container path - see `SharedFileService`.
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
}
