import Foundation

final class MockTokenProvider: TokenProviderProtocol, @unchecked Sendable {
    var token: String?
    var _isBootstrapped: Bool = true
    var _hasTokenSource: Bool = true
    var bootstrapError: Error?
    var bootstrapCallCount = 0
    var currentTokenCallCount = 0
    var invalidateCallCount = 0
    var refreshTokenIfChangedCallCount = 0
    var disconnectOAuthCallCount = 0
    var refreshOAuthTokenIfNeededCallCount = 0
    var handleUnauthorizedOAuthCallCount = 0
    var completeOAuthLoginCallCount = 0
    var lastCompletedOAuthLogin: OAuthTokens?
    /// When set, `completeOAuthLogin` throws this instead of recording the tokens.
    var completeOAuthLoginError: Error?
    /// What `hasOwnOAuthLogin()` returns. Tests flip this to simulate a
    /// durable "Sign in with Claude" login vs. a borrowed-only session.
    var _hasOwnOAuthLogin = false
    /// What `refreshTokenIfChanged()` returns. Tests flip this to simulate an
    /// account swap detected on the Keychain.
    var tokenDidChange = false
    /// What the async OAuth-refresh seams return. Default false = borrowed
    /// sources (no OAuth tokens), matching the pre-OAuth test baseline.
    var oauthRefreshedProactively = false
    var oauthRefreshedOnUnauthorized = false

    var isBootstrapped: Bool { _isBootstrapped }

    func currentToken() -> String? {
        currentTokenCallCount += 1
        return token
    }

    func hasTokenSource() -> Bool {
        _hasTokenSource
    }

    func invalidateToken() {
        invalidateCallCount += 1
    }

    func refreshTokenIfChanged() -> Bool {
        refreshTokenIfChangedCallCount += 1
        return tokenDidChange
    }

    func refreshOAuthTokenIfNeeded() async -> Bool {
        refreshOAuthTokenIfNeededCallCount += 1
        return oauthRefreshedProactively
    }

    func handleUnauthorizedOAuth() async -> Bool {
        handleUnauthorizedOAuthCallCount += 1
        return oauthRefreshedOnUnauthorized
    }

    func bootstrap() throws {
        bootstrapCallCount += 1
        if let error = bootstrapError { throw error }
        _isBootstrapped = true
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
