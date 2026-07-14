import Testing
import Foundation

@Suite("OAuthErrorFormatter")
struct OAuthErrorFormatterTests {

    @Test("stateMismatch has a non-empty localized message")
    func stateMismatch() {
        #expect(!OAuthErrorFormatter.message(for: .stateMismatch).isEmpty)
    }

    @Test("malformedCallback has a non-empty localized message")
    func malformedCallback() {
        #expect(!OAuthErrorFormatter.message(for: .malformedCallback).isEmpty)
    }

    // Localized string resolution (and therefore %d interpolation) isn't
    // reliable in the unit test bundle - see `NotificationBodyFormatterTests`
    // for the same constraint - so these only assert non-emptiness, matching
    // that established pattern, rather than asserting on interpolated content.

    @Test("exchangeFailed has a non-empty localized message")
    func exchangeFailed() {
        #expect(!OAuthErrorFormatter.message(for: .exchangeFailed(500)).isEmpty)
    }

    @Test("refreshFailed has a non-empty localized message")
    func refreshFailed() {
        #expect(!OAuthErrorFormatter.message(for: .refreshFailed(401)).isEmpty)
    }

    @Test("cancelled has a non-empty localized message")
    func cancelled() {
        #expect(!OAuthErrorFormatter.message(for: .cancelled).isEmpty)
    }

    @Test("listenerFailed has a non-empty localized message")
    func listenerFailed() {
        #expect(!OAuthErrorFormatter.message(for: .listenerFailed).isEmpty)
    }
}
