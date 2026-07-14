import Foundation

final class MockOAuthTokenStore: OAuthTokenStoreProtocol, @unchecked Sendable {
    private var storedTokens: OAuthTokens?
    /// When set, `save` throws this instead of storing the tokens.
    var saveError: Error?

    func load() -> OAuthTokens? {
        storedTokens
    }

    func save(_ tokens: OAuthTokens) throws {
        if let saveError { throw saveError }
        storedTokens = tokens
    }

    func clear() {
        storedTokens = nil
    }
}
