import Foundation

final class MockTokenProvider: TokenProviderProtocol, @unchecked Sendable {
    var token: String?
    var currentTokenCallCount = 0
    var invalidateCallCount = 0
    var disconnectOAuthCallCount = 0
    var refreshOAuthTokenIfNeededCallCount = 0
    var handleUnauthorizedOAuthCallCount = 0
    var completeOAuthLoginCallCount = 0
    var lastCompletedOAuthLogin: OAuthTokens?
    /// When set, `completeOAuthLogin` throws this instead of recording the tokens.
    var completeOAuthLoginError: Error?
    /// What `hasOwnOAuthLogin()` returns. Tests flip this to simulate a
    /// durable "Sign in with Claude" login vs. signed-out.
    var _hasOwnOAuthLogin = false
    /// What the async OAuth-refresh seams return. Default false = no login.
    var oauthRefreshedProactively = false
    var oauthRefreshedOnUnauthorized = false
    /// What `needsReauthorization` returns. Tests flip this to simulate a dead session.
    var needsReauthorization = false
    var sessionExpiresAt: Date?

    func currentToken() -> String? {
        currentTokenCallCount += 1
        return token
    }

    func invalidateToken() {
        invalidateCallCount += 1
    }

    func refreshOAuthTokenIfNeeded() async -> Bool {
        refreshOAuthTokenIfNeededCallCount += 1
        return oauthRefreshedProactively
    }

    func handleUnauthorizedOAuth() async -> Bool {
        handleUnauthorizedOAuthCallCount += 1
        return oauthRefreshedOnUnauthorized
    }

    func disconnectOAuth() {
        disconnectOAuthCallCount += 1
    }

    func completeOAuthLogin(_ tokens: OAuthTokens) throws {
        completeOAuthLoginCallCount += 1
        if let error = completeOAuthLoginError { throw error }
        lastCompletedOAuthLogin = tokens
        token = tokens.accessToken
    }

    func hasOwnOAuthLogin() -> Bool {
        _hasOwnOAuthLogin
    }
}
