import Foundation

/// Outcome of one instance sync, surfaced to the store for the status line.
enum RemoteSyncOutcome: Sendable, Equatable {
    case ok(fileCount: Int, date: Date)
    case failed(String)
}

/// Pulls a remote instance's `~/.claude/projects` JSONL logs into its local
/// cache dir over SSH. Fully async and off the main actor; never prompts and
/// never hangs (BatchMode + connect/transfer timeouts).
protocol RemoteLogSyncServiceProtocol: Sendable {
    func sync(_ instance: RemoteInstance) async -> RemoteSyncOutcome
}
