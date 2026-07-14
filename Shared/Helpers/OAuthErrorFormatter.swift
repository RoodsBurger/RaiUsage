import Foundation

/// Localized, user-facing messages for `OAuthError`. Shared by the Settings
/// Connection card and the onboarding hero's "Sign in with Claude" flow.
enum OAuthErrorFormatter {
    static func message(for error: OAuthError) -> String {
        switch error {
        case .stateMismatch:
            return String(localized: "connect.oauth.error.statemismatch")
        case .malformedCallback:
            return String(localized: "connect.oauth.error.malformedcallback")
        case .exchangeFailed(let status):
            return String(format: String(localized: "connect.oauth.error.exchangefailed"), status)
        case .refreshFailed(let status):
            return String(format: String(localized: "connect.oauth.error.refreshfailed"), status)
        case .cancelled:
            return String(localized: "connect.oauth.error.cancelled")
        case .listenerFailed:
            return String(localized: "connect.oauth.error.listenerfailed")
        }
    }
}
