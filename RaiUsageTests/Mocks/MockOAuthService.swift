import Foundation

final class MockOAuthService: OAuthServiceProtocol, @unchecked Sendable {
    var beginLoginCallCount = 0
    var completeManualLoginCallCount = 0
    var cancelLoginCallCount = 0
    var refreshCallCount = 0

    var lastManualPaste: String?
    var lastRefreshTokens: OAuthTokens?

    var stubbedLoginResult: Result<OAuthTokens, OAuthError> = .failure(.cancelled)
    var stubbedManualLoginResult: Result<OAuthTokens, OAuthError> = .failure(.cancelled)
    var stubbedRefreshResult: Result<OAuthTokens, OAuthError> = .failure(.cancelled)

    /// When true, `refresh` delivers its completion asynchronously off a
    /// background queue instead of inline, so tests exercise the real
    /// suspend/resume of the `withCheckedContinuation` bridge rather than an
    /// inline-only completion.
    var deliverRefreshAsynchronously = false

    /// When true, `beginLogin`/`completeManualLogin` stash their completion
    /// instead of calling it immediately, so tests can assert a caller's
    /// synchronous pre-completion state (e.g. "browser opened, waiting") before
    /// resolving the login via `resolvePendingLogin(_:)`.
    var deferLoginCompletion = false
    private(set) var pendingLoginCompletion: ((Result<OAuthTokens, OAuthError>) -> Void)?

    func beginLogin(completion: @escaping (Result<OAuthTokens, OAuthError>) -> Void) {
        beginLoginCallCount += 1
        if deferLoginCompletion {
            pendingLoginCompletion = completion
        } else {
            completion(stubbedLoginResult)
        }
    }

    func completeManualLogin(pasted: String, completion: @escaping (Result<OAuthTokens, OAuthError>) -> Void) {
        completeManualLoginCallCount += 1
        lastManualPaste = pasted
        if deferLoginCompletion {
            pendingLoginCompletion = completion
        } else {
            completion(stubbedManualLoginResult)
        }
    }

    /// Resolves a completion stashed by `deferLoginCompletion`. No-op if
    /// nothing is pending.
    func resolvePendingLogin(_ result: Result<OAuthTokens, OAuthError>) {
        let completion = pendingLoginCompletion
        pendingLoginCompletion = nil
        completion?(result)
    }

    func cancelLogin() {
        cancelLoginCallCount += 1
    }

    func refresh(_ tokens: OAuthTokens, completion: @escaping (Result<OAuthTokens, OAuthError>) -> Void) {
        refreshCallCount += 1
        lastRefreshTokens = tokens
        let result = stubbedRefreshResult
        if deliverRefreshAsynchronously {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                completion(result)
            }
        } else {
            completion(result)
        }
    }
}
