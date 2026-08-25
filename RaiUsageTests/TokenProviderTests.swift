import Testing
import Foundation

@Suite("TokenProvider")
struct TokenProviderTests {

    // MARK: - Helpers

    /// A per-call, guaranteed-nonexistent import file path. Every `TokenProvider`
    /// construction in this suite must pass an explicit import URL (never the
    /// real default) so tests never touch the real filesystem.
    private static var noImportFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenProviderTests-\(UUID().uuidString)")
            .appendingPathComponent("oauth-import.json")
    }

    /// Mutable clock injected as TokenProvider's `now` so backoff tests can
    /// advance time deterministically.
    private final class TestClock: @unchecked Sendable {
        var now = Date()
    }

    private func makeSUT(
        oauthTokens: OAuthTokens? = nil,
        oauthRefreshResult: Result<OAuthTokens, OAuthError> = .failure(.cancelled),
        now: (() -> Date)? = nil
    ) -> (TokenProvider, MockOAuthTokenStore, MockOAuthService) {
        let oauthStore = MockOAuthTokenStore()
        if let oauthTokens {
            try? oauthStore.save(oauthTokens)
        }

        let oauthService = MockOAuthService()
        oauthService.stubbedRefreshResult = oauthRefreshResult

        let provider = TokenProvider(
            oauthService: oauthService,
            oauthTokenStore: oauthStore,
            oauthImportFileURL: Self.noImportFileURL,
            now: now ?? Date.init
        )

        return (provider, oauthStore, oauthService)
    }

    // MARK: - currentToken

    @Test("currentToken returns the stored access token")
    func currentTokenFromStore() {
        let tokens = OAuthTokens(accessToken: "oauth-access", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        let (provider, _, _) = makeSUT(oauthTokens: tokens)

        #expect(provider.currentToken() == "oauth-access")
    }

    @Test("currentToken returns nil when signed out")
    func currentTokenNilWhenSignedOut() {
        let (provider, _, _) = makeSUT()
        #expect(provider.currentToken() == nil)
    }

    @Test("currentToken returns the stored access token near expiry without touching the network")
    func currentTokenNearExpiryIsNonBlocking() {
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let (provider, _, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .success(OAuthTokens(accessToken: "fresh-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600)))
        )

        // currentToken() is synchronous and must never refresh: it serves the
        // stored access token as-is. The async path renews it.
        #expect(provider.currentToken() == "stale-access")
        #expect(oauthService.refreshCallCount == 0)
    }

    // MARK: - refreshOAuthTokenIfNeeded

    @Test("refreshOAuthTokenIfNeeded renews a near-expiry token exactly once and saves it")
    func refreshOAuthTokenIfNeededRenewsNearExpiry() async {
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let refreshedTokens = OAuthTokens(accessToken: "fresh-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600))
        let (provider, oauthStore, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .success(refreshedTokens)
        )

        let usable = await provider.refreshOAuthTokenIfNeeded()

        #expect(usable == true)
        #expect(oauthService.refreshCallCount == 1)
        #expect(oauthStore.load() == refreshedTokens)
        #expect(provider.currentToken() == "fresh-access")
    }

    @Test("refreshOAuthTokenIfNeeded is a no-op for a fresh token")
    func refreshOAuthTokenIfNeededSkipsFreshToken() async {
        let freshTokens = OAuthTokens(accessToken: "fresh-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600))
        let (provider, _, oauthService) = makeSUT(oauthTokens: freshTokens)

        let usable = await provider.refreshOAuthTokenIfNeeded()

        #expect(usable == true)
        #expect(oauthService.refreshCallCount == 0)
    }

    @Test("refreshOAuthTokenIfNeeded is a no-op returning false when signed out")
    func refreshOAuthTokenIfNeededNoOpWithoutTokens() async {
        let (provider, _, oauthService) = makeSUT()

        let usable = await provider.refreshOAuthTokenIfNeeded()

        #expect(usable == false)
        #expect(oauthService.refreshCallCount == 0)
    }

    @Test("refreshOAuthTokenIfNeeded failure keeps the stored token untouched")
    func refreshOAuthTokenIfNeededFailureKeepsToken() async {
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let (provider, oauthStore, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .failure(.refreshFailed(500))
        )

        let usable = await provider.refreshOAuthTokenIfNeeded()

        #expect(usable == false)
        #expect(oauthService.refreshCallCount == 1)
        #expect(oauthStore.load() == staleTokens) // failed refresh persisted nothing
        #expect(provider.currentToken() == "stale-access")
    }

    @Test("refreshOAuthTokenIfNeeded awaits a delayed, non-inline completion")
    func refreshOAuthTokenIfNeededAwaitsDelayedCompletion() async {
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let refreshedTokens = OAuthTokens(accessToken: "fresh-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600))
        let (provider, oauthStore, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .success(refreshedTokens)
        )
        // Deliver the completion off a background queue AFTER refresh() returns,
        // so a success dropped by the old timeout bridge would fail this test.
        oauthService.deliverRefreshAsynchronously = true

        let usable = await provider.refreshOAuthTokenIfNeeded()

        #expect(usable == true)
        #expect(oauthStore.load() == refreshedTokens)
        #expect(provider.currentToken() == "fresh-access")
    }

    // MARK: - handleUnauthorizedOAuth

    @Test("handleUnauthorizedOAuth forces a refresh regardless of expiry and saves it")
    func handleUnauthorizedOAuthForcesRefresh() async {
        // Token is NOT near expiry, yet a 401 means the server rejected it.
        let liveButRejected = OAuthTokens(accessToken: "old-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600))
        let newTokens = OAuthTokens(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600))
        let (provider, oauthStore, oauthService) = makeSUT(
            oauthTokens: liveButRejected,
            oauthRefreshResult: .success(newTokens)
        )

        let refreshed = await provider.handleUnauthorizedOAuth()

        #expect(refreshed == true)
        #expect(oauthService.refreshCallCount == 1)
        #expect(oauthStore.load() == newTokens)
        #expect(provider.currentToken() == "new-access")
    }

    @Test("handleUnauthorizedOAuth failure leaves the stored tokens untouched")
    func handleUnauthorizedOAuthFailureKeepsTokens() async {
        let oldTokens = OAuthTokens(accessToken: "old-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600))
        let (provider, oauthStore, oauthService) = makeSUT(
            oauthTokens: oldTokens,
            oauthRefreshResult: .failure(.refreshFailed(500))
        )

        let refreshed = await provider.handleUnauthorizedOAuth()

        #expect(refreshed == false)
        #expect(oauthService.refreshCallCount == 1)
        #expect(oauthStore.load() == oldTokens) // nothing persisted on failure
    }

    @Test("handleUnauthorizedOAuth is a no-op returning false when signed out")
    func handleUnauthorizedOAuthNoOpWithoutTokens() async {
        let (provider, _, oauthService) = makeSUT()

        let refreshed = await provider.handleUnauthorizedOAuth()

        #expect(refreshed == false)
        #expect(oauthService.refreshCallCount == 0)
    }

    // MARK: - OAuth refresh failure backoff (no token-endpoint hammer)

    @Test("a 400/401 refresh failure marks the refresh token dead - later ticks make no further network attempts")
    func deadRefreshTokenStopsFurtherAttempts() async {
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "dead-refresh", expiresAt: Date().addingTimeInterval(60))
        let (provider, _, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .failure(.refreshFailed(400))
        )

        #expect(await provider.refreshOAuthTokenIfNeeded() == false)
        #expect(oauthService.refreshCallCount == 1)

        // Every later tick: zero token-endpoint traffic until the user re-authorizes.
        #expect(await provider.refreshOAuthTokenIfNeeded() == false)
        #expect(await provider.handleUnauthorizedOAuth() == false)
        #expect(oauthService.refreshCallCount == 1)
    }

    @Test("a 403 refresh failure is transient (rate-limiter ambiguity), never a dead token")
    func forbiddenRefreshIsTransientNotDead() async {
        let clock = TestClock()
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let (provider, _, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .failure(.refreshFailed(403)),
            now: { clock.now }
        )

        #expect(await provider.refreshOAuthTokenIfNeeded() == false)
        #expect(await provider.refreshOAuthTokenIfNeeded() == false) // inside backoff window
        #expect(oauthService.refreshCallCount == 1)

        clock.now = clock.now.addingTimeInterval(61)
        _ = await provider.refreshOAuthTokenIfNeeded()
        #expect(oauthService.refreshCallCount == 2) // retried after the window
    }

    @Test("a transient refresh failure backs off instead of retrying every tick, then retries after the window")
    func transientRefreshFailureBacksOff() async {
        let clock = TestClock()
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let (provider, _, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .failure(.refreshFailed(-1)),
            now: { clock.now }
        )

        #expect(await provider.refreshOAuthTokenIfNeeded() == false)
        #expect(oauthService.refreshCallCount == 1)

        // Inside the backoff window: no network from either path.
        #expect(await provider.refreshOAuthTokenIfNeeded() == false)
        #expect(await provider.handleUnauthorizedOAuth() == false)
        #expect(oauthService.refreshCallCount == 1)

        // Past the first 60s window: one more attempt is allowed.
        clock.now = clock.now.addingTimeInterval(61)
        _ = await provider.refreshOAuthTokenIfNeeded()
        #expect(oauthService.refreshCallCount == 2)
    }

    @Test("a 429 refresh failure is transient (backs off) rather than a dead token")
    func rateLimitedRefreshBacksOffButRetriesLater() async {
        let clock = TestClock()
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let (provider, _, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .failure(.refreshFailed(429)),
            now: { clock.now }
        )

        #expect(await provider.refreshOAuthTokenIfNeeded() == false)
        #expect(await provider.refreshOAuthTokenIfNeeded() == false)
        #expect(oauthService.refreshCallCount == 1)

        clock.now = clock.now.addingTimeInterval(61)
        _ = await provider.refreshOAuthTokenIfNeeded()
        #expect(oauthService.refreshCallCount == 2) // retried, not permanently dead
    }

    @Test("a successful refresh resets the backoff ladder")
    func successResetsBackoffLadder() async throws {
        let clock = TestClock()
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60))
        let (provider, oauthStore, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .failure(.refreshFailed(-1)),
            now: { clock.now }
        )

        // Failure #1 arms a 60s window.
        _ = await provider.refreshOAuthTokenIfNeeded()
        #expect(oauthService.refreshCallCount == 1)

        // Past the window, the retry succeeds and must reset the ladder.
        clock.now = clock.now.addingTimeInterval(61)
        oauthService.stubbedRefreshResult = .success(OAuthTokens(accessToken: "fresh-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600)))
        #expect(await provider.refreshOAuthTokenIfNeeded() == true)
        #expect(oauthService.refreshCallCount == 2)

        // Put a near-expiry token set back and fail again: the next window must
        // be the initial 60s, not the doubled 120s a non-reset ladder would use.
        try oauthStore.save(OAuthTokens(accessToken: "stale-again", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(60)))
        provider.invalidateToken()
        oauthService.stubbedRefreshResult = .failure(.refreshFailed(-1))
        _ = await provider.refreshOAuthTokenIfNeeded()
        #expect(oauthService.refreshCallCount == 3)

        clock.now = clock.now.addingTimeInterval(61)
        _ = await provider.refreshOAuthTokenIfNeeded()
        #expect(oauthService.refreshCallCount == 4) // 61s > 60s window -> allowed
    }

    @Test("completeOAuthLogin clears the dead-refresh-token gate so a fresh login refreshes normally")
    func completeOAuthLoginClearsRefreshGate() async throws {
        let staleTokens = OAuthTokens(accessToken: "stale-access", refreshToken: "dead-refresh", expiresAt: Date().addingTimeInterval(60))
        let (provider, _, oauthService) = makeSUT(
            oauthTokens: staleTokens,
            oauthRefreshResult: .failure(.refreshFailed(401))
        )

        _ = await provider.refreshOAuthTokenIfNeeded()
        #expect(oauthService.refreshCallCount == 1) // gate is now dead

        // User re-authorizes: a brand-new near-expiry token set is saved.
        try provider.completeOAuthLogin(OAuthTokens(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(60)))
        oauthService.stubbedRefreshResult = .success(OAuthTokens(accessToken: "renewed-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600)))

        #expect(await provider.refreshOAuthTokenIfNeeded() == true)
        #expect(oauthService.refreshCallCount == 2) // the gate no longer blocks
        #expect(provider.currentToken() == "renewed-access")
    }

    // MARK: - invalidate / disconnect / login

    @Test("invalidateToken only clears the cache and never calls oauthService.refresh")
    func invalidateTokenDoesNotRefresh() {
        let tokens = OAuthTokens(accessToken: "oauth-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600))
        let (provider, oauthStore, oauthService) = makeSUT(
            oauthTokens: tokens,
            oauthRefreshResult: .success(OAuthTokens(accessToken: "should-not-appear", refreshToken: "x", expiresAt: Date().addingTimeInterval(3600)))
        )

        provider.invalidateToken()

        #expect(oauthService.refreshCallCount == 0) // no network on a bare invalidate
        #expect(oauthStore.load() == tokens) // store untouched
        #expect(provider.currentToken() == "oauth-access")
    }

    @Test("disconnectOAuth clears the store and the cache")
    func disconnectOAuthClearsEverything() {
        let tokens = OAuthTokens(accessToken: "oauth-access", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600))
        let (provider, oauthStore, _) = makeSUT(oauthTokens: tokens)

        #expect(provider.currentToken() == "oauth-access")

        provider.disconnectOAuth()

        #expect(oauthStore.load() == nil)
        #expect(provider.currentToken() == nil)
    }

    @Test("completeOAuthLogin saves tokens to the store and caches the access token")
    func completeOAuthLoginSavesAndCaches() throws {
        let (provider, oauthStore, _) = makeSUT()
        let tokens = OAuthTokens(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600))

        try provider.completeOAuthLogin(tokens)

        #expect(oauthStore.load() == tokens)
        #expect(provider.currentToken() == "new-access")
    }

    @Test("completeOAuthLogin propagates a store save failure and leaves the cache untouched")
    func completeOAuthLoginPropagatesSaveFailure() {
        let (provider, oauthStore, _) = makeSUT()
        struct SaveError: Error {}
        oauthStore.saveError = SaveError()
        let tokens = OAuthTokens(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600))

        #expect(throws: SaveError.self) {
            try provider.completeOAuthLogin(tokens)
        }
        #expect(oauthStore.load() == nil)
        #expect(provider.currentToken() == nil)
    }

    @Test("hasOwnOAuthLogin is false when the app-owned store is empty")
    func hasOwnOAuthLoginFalseWhenEmpty() {
        let (provider, _, _) = makeSUT()
        #expect(provider.hasOwnOAuthLogin() == false)
    }

    @Test("hasOwnOAuthLogin is true once the app-owned store holds tokens")
    func hasOwnOAuthLoginTrueWhenPresent() {
        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        let (provider, _, _) = makeSUT(oauthTokens: tokens)
        #expect(provider.hasOwnOAuthLogin() == true)
    }

    // MARK: - One-time OAuth import

    @Test("one-time import reads a pre-minted token file, saves it, and deletes the file")
    func oneTimeImportSavesAndDeletesFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let importURL = tempDir.appendingPathComponent("oauth-import.json")
        // Rounded to whole seconds - the epoch-seconds JSON codec drops
        // sub-second precision, so comparing against an unrounded Date below
        // would fail on the fractional part alone.
        let expiresAt = Date(timeIntervalSince1970: Date().addingTimeInterval(3600).timeIntervalSince1970.rounded())
        let tokens = OAuthTokens(accessToken: "imported-access", refreshToken: "imported-refresh", expiresAt: expiresAt)
        try OAuthTokenStore.encode(tokens).write(to: importURL)

        let oauthStore = MockOAuthTokenStore()
        _ = TokenProvider(
            oauthService: MockOAuthService(),
            oauthTokenStore: oauthStore,
            oauthImportFileURL: importURL
        )

        #expect(oauthStore.load() == tokens)
        #expect(FileManager.default.fileExists(atPath: importURL.path) == false)
    }

    @Test("missing import file is a no-op")
    func missingImportFileIsNoOp() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let importURL = tempDir.appendingPathComponent("oauth-import.json") // never created

        let oauthStore = MockOAuthTokenStore()
        _ = TokenProvider(
            oauthService: MockOAuthService(),
            oauthTokenStore: oauthStore,
            oauthImportFileURL: importURL
        )

        #expect(oauthStore.load() == nil)
    }

    @Test("import errors leave the file untouched")
    func malformedImportFileIsLeftInPlace() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let importURL = tempDir.appendingPathComponent("oauth-import.json")
        try Data("not valid json".utf8).write(to: importURL)

        let oauthStore = MockOAuthTokenStore()
        _ = TokenProvider(
            oauthService: MockOAuthService(),
            oauthTokenStore: oauthStore,
            oauthImportFileURL: importURL
        )

        #expect(oauthStore.load() == nil)
        #expect(FileManager.default.fileExists(atPath: importURL.path) == true)
    }
}
