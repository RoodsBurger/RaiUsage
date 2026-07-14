import Foundation

final class MockUpdateChecker: UpdateCheckerProtocol, @unchecked Sendable {
    var stubbedInfo: UpdateInfo?
    var stubbedError: Error?
    private(set) var checkCallCount = 0

    func checkLatest() async throws -> UpdateInfo? {
        checkCallCount += 1
        if let stubbedError { throw stubbedError }
        return stubbedInfo
    }
}
