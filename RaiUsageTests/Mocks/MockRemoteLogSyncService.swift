import Foundation

/// Records the instances asked to sync and returns a canned outcome, so store
/// tests never actually ssh.
final class MockRemoteLogSyncService: RemoteLogSyncServiceProtocol, @unchecked Sendable {
    var outcome: RemoteSyncOutcome
    private(set) var syncedInstances: [RemoteInstance] = []

    init(outcome: RemoteSyncOutcome = .ok(fileCount: 1, date: Date())) {
        self.outcome = outcome
    }

    func sync(_ instance: RemoteInstance) async -> RemoteSyncOutcome {
        syncedInstances.append(instance)
        return outcome
    }
}
