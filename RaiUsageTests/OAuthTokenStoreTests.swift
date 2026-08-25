import Testing
import Foundation

@Suite("OAuthTokenStore")
struct OAuthTokenStoreTests {

    // MARK: - File Store Helpers

    /// A store rooted in a unique temp file, with no legacy Keychain unless
    /// the test injects one. Never touches the real Keychain or home dir.
    private func makeFileStore(
        legacy: OAuthTokenStore.LegacyKeychain = .none
    ) throws -> (OAuthTokenStore, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthTokenStoreTests-\(UUID().uuidString)")
        let fileURL = dir.appendingPathComponent("oauth-tokens.json")
        return (OAuthTokenStore(fileURL: fileURL, legacyKeychain: legacy), fileURL, dir)
    }

    private static let sampleTokens = OAuthTokens(
        accessToken: "file-access",
        refreshToken: "file-refresh",
        expiresAt: Date(timeIntervalSince1970: 1783980000)
    )

    // MARK: - File Store

    @Test("save then load round-trips through the file")
    func fileSaveLoadRoundTrip() throws {
        let (store, _, dir) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(Self.sampleTokens)

        #expect(store.load() == Self.sampleTokens)
    }

    @Test("load returns nil when no file and no legacy item exist")
    func fileLoadEmpty() throws {
        let (store, _, _) = try makeFileStore()
        #expect(store.load() == nil)
    }

    @Test("saved token file is user-only (0600)")
    func fileSavePermissions() throws {
        let (store, fileURL, dir) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(Self.sampleTokens)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test("save overwrites the previous token set")
    func fileSaveOverwrite() throws {
        let (store, _, dir) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(Self.sampleTokens)
        let newer = OAuthTokens(accessToken: "newer-access", refreshToken: "newer-refresh", expiresAt: Date(timeIntervalSince1970: 1784000000))
        try store.save(newer)

        #expect(store.load() == newer)
    }

    @Test("clear removes the file and deletes the legacy Keychain item")
    func fileClearRemovesFileAndLegacy() throws {
        var legacyDeleted = false
        let legacy = OAuthTokenStore.LegacyKeychain(load: { nil }, delete: { legacyDeleted = true })
        let (store, fileURL, dir) = try makeFileStore(legacy: legacy)
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(Self.sampleTokens)
        store.clear()

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(store.load() == nil)
        #expect(legacyDeleted == true)
    }

    @Test("a corrupt token file loads as nil rather than crashing")
    func fileCorruptLoadsNil() throws {
        let (store, fileURL, dir) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        #expect(store.load() == nil)
    }

    // MARK: - Legacy Keychain Migration

    @Test("load migrates a legacy Keychain item into the file and deletes the item")
    func migratesLegacyKeychainItem() throws {
        var legacyDeleted = false
        let legacyData = try OAuthTokenStore.encode(Self.sampleTokens)
        let legacy = OAuthTokenStore.LegacyKeychain(
            load: { legacyData },
            delete: { legacyDeleted = true }
        )
        let (store, fileURL, dir) = try makeFileStore(legacy: legacy)
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = store.load()

        #expect(loaded == Self.sampleTokens)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == true) // persisted to file
        #expect(legacyDeleted == true) // keychain item retired after successful write
    }

    @Test("once migrated, load reads the file without consulting the legacy item")
    func migrationRunsOnce() throws {
        var legacyLoadCount = 0
        let legacyData = try OAuthTokenStore.encode(Self.sampleTokens)
        let legacy = OAuthTokenStore.LegacyKeychain(
            load: { legacyLoadCount += 1; return legacyData },
            delete: {}
        )
        let (store, _, dir) = try makeFileStore(legacy: legacy)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = store.load() // migrates
        _ = store.load() // file hit

        #expect(legacyLoadCount == 1)
    }

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
