import Testing
import Foundation

@Suite("OAuthTokenStore")
struct OAuthTokenStoreTests {

    // MARK: - Codec Tests

    @Test("Codec decodes the epoch-seconds fixture byte-compatibly")
    func codecDecodeFixture() {
        let fixtureJSON = "{\"accessToken\":\"a\",\"refreshToken\":\"r\",\"expiresAt\":1783980000}".data(using: .utf8)!

        let tokens = OAuthTokenStore.decode(fixtureJSON)

        #expect(tokens != nil)
        if let tokens = tokens {
            #expect(tokens.accessToken == "a")
            #expect(tokens.refreshToken == "r")
            #expect(abs(tokens.expiresAt.timeIntervalSince1970 - 1783980000) < 0.1)
        }
    }

    @Test("Codec round-trips tokens to JSON and back")
    func codecRoundTrip() throws {
        let original = OAuthTokens(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            expiresAt: Date(timeIntervalSince1970: 1783980000)
        )

        let encoded = try OAuthTokenStore.encode(original)
        let decoded = OAuthTokenStore.decode(encoded)

        #expect(decoded != nil)
        if let decoded = decoded {
            #expect(decoded.accessToken == original.accessToken)
            #expect(decoded.refreshToken == original.refreshToken)
            #expect(abs(decoded.expiresAt.timeIntervalSince1970 - original.expiresAt.timeIntervalSince1970) < 0.1)
        }
    }

    @Test("Codec handles tokens with special characters")
    func codecSpecialCharacters() throws {
        let original = OAuthTokens(
            accessToken: "access-token-with-special!@#$%",
            refreshToken: "refresh-token-with-special!@#$%",
            expiresAt: Date(timeIntervalSince1970: 1234567890)
        )

        let encoded = try OAuthTokenStore.encode(original)
        let decoded = OAuthTokenStore.decode(encoded)

        #expect(decoded != nil)
        #expect(decoded?.accessToken == original.accessToken)
        #expect(decoded?.refreshToken == original.refreshToken)
    }

    @Test("Codec returns nil for invalid JSON")
    func codecInvalidJSON() {
        let invalidJSON = "{invalid json content}".data(using: .utf8)!

        let decoded = OAuthTokenStore.decode(invalidJSON)
        #expect(decoded == nil)
    }

    @Test("Codec returns nil for JSON missing required fields")
    func codecMissingFields() {
        let incompleteJSON = "{\"accessToken\":\"a\"}".data(using: .utf8)!

        let decoded = OAuthTokenStore.decode(incompleteJSON)
        #expect(decoded == nil)
    }

    // MARK: - Mock Semantics

    @Test("Mock save and load round-trip")
    func mockSaveAndLoad() throws {
        let mock = MockOAuthTokenStore()
        let tokens = OAuthTokens(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            expiresAt: Date(timeIntervalSince1970: 1783980000)
        )

        try mock.save(tokens)
        let loaded = mock.load()

        #expect(loaded?.accessToken == tokens.accessToken)
        #expect(loaded?.refreshToken == tokens.refreshToken)
        #expect(abs((loaded?.expiresAt ?? .distantPast).timeIntervalSince1970 - tokens.expiresAt.timeIntervalSince1970) < 0.1)
    }

    @Test("Mock load returns nil when empty")
    func mockLoadEmpty() {
        let mock = MockOAuthTokenStore()
        let loaded = mock.load()
        #expect(loaded == nil)
    }

    @Test("Mock clear removes stored tokens")
    func mockClear() throws {
        let mock = MockOAuthTokenStore()
        let tokens = OAuthTokens(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            expiresAt: Date()
        )

        try mock.save(tokens)
        #expect(mock.load() != nil)

        mock.clear()
        #expect(mock.load() == nil)
    }

    @Test("Mock save overwrites previous tokens")
    func mockSaveOverwrite() throws {
        let mock = MockOAuthTokenStore()
        let tokens1 = OAuthTokens(
            accessToken: "first-access",
            refreshToken: "first-refresh",
            expiresAt: Date(timeIntervalSince1970: 1000000)
        )
        let tokens2 = OAuthTokens(
            accessToken: "second-access",
            refreshToken: "second-refresh",
            expiresAt: Date(timeIntervalSince1970: 2000000)
        )

        try mock.save(tokens1)
        try mock.save(tokens2)

        let loaded = mock.load()
        #expect(loaded?.accessToken == "second-access")
        #expect(loaded?.refreshToken == "second-refresh")
    }
}
