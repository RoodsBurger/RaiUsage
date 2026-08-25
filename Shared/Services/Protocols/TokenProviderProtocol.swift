import Foundation

protocol TokenProviderProtocol: Sendable {
    /// Current access token from the app-owned store, or nil when signed out.
    /// Synchronous and network-free.
    func currentToken() -> String?
    /// Clear cached token - call after 401 so the next read re-checks the store.
    func invalidateToken()
    /// Proactively refreshes the app-owned OAuth token when it exists and is
    /// near expiry, awaiting the network exchange. Returns true when a usable
    /// OAuth access token is available afterwards. No-op returning false when
    /// no login exists. Callers await this once per refresh tick, before
    /// reading the token.
    func refreshOAuthTokenIfNeeded() async -> Bool
    /// Forces one OAuth refresh after a 401, regardless of local expiry. On
    /// success saves + caches the new token so the caller's immediate retry
    /// reads it. Returns true when a refreshed token is available. No-op
    /// returning false when no login exists.
    func handleUnauthorizedOAuth() async -> Bool
    /// Signs out: clears the stored OAuth tokens and the cache.
    func disconnectOAuth()
    /// Persists tokens obtained from a fresh OAuth login (`OAuthService.beginLogin`
    /// or `completeManualLogin`) into the app-owned store and caches the access
    /// token so the next `currentToken()` read returns it immediately.
    func completeOAuthLogin(_ tokens: OAuthTokens) throws
    /// Whether the app currently owns an OAuth token set (a durable "Sign in
    /// with Claude" login).
    func hasOwnOAuthLogin() -> Bool
}
