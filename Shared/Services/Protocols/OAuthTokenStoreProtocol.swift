import Foundation

protocol OAuthTokenStoreProtocol: AnyObject {
    /// Loads stored OAuth tokens from the Keychain. Returns nil if no tokens exist.
    func load() -> OAuthTokens?

    /// Saves OAuth tokens to the Keychain. Creates or updates the item as needed.
    func save(_ tokens: OAuthTokens) throws

    /// Clears the stored OAuth tokens from the Keychain.
    func clear()
}
