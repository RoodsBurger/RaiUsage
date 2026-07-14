import Foundation
import os.log

private let logger = Logger(subsystem: "com.raiusage.app", category: "RemoteLogSync")

/// Result of a spawned process, returned by the injectable runner seam so tests
/// can stub the rsync invocation without actually shelling out.
struct RemoteProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// Injectable process runner. The real one spawns the given tool; tests
/// substitute a closure that records the argv and returns a canned result.
typealias RemoteProcessRunner = @Sendable (_ launchPath: String, _ arguments: [String]) async -> RemoteProcessResult

/// Classified sync failure. Kept separate from the localized message so the
/// classifier is unit-testable without depending on string resources.
enum RemoteSyncFailure: Sendable, Equatable {
    case invalidInstance
    case cacheUnavailable
    case timedOut
    case permissionDenied
    case rsyncMissing
    case hostKeyChanged
    case unreachable
    case other(Int32)
}

/// Per-host local cache under the app's shared support dir. Shared by the sync
/// service (write target) and the History/Activity scan (read source).
enum RemoteLogCache {
    /// `~/Library/Application Support/com.raiusage.shared/remote-logs`.
    /// Resolves the REAL home via `getpwuid` (not a sandbox container), the
    /// same trick `SharedFileService` / `SessionHistoryService` use.
    static var root: URL {
        let home: URL
        if let dir = getpwuid(getuid())?.pointee.pw_dir.flatMap({ String(cString: $0) }), !dir.isEmpty {
            home = URL(fileURLWithPath: dir)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("com.raiusage.shared", isDirectory: true)
            .appendingPathComponent("remote-logs", isDirectory: true)
    }

    /// Per-host cache dir, host reduced to a filesystem-safe path component.
    static func directory(forHost host: String, root: URL = RemoteLogCache.root) -> URL {
        root.appendingPathComponent(sanitizedComponent(host), isDirectory: true)
    }

    /// Reduce a host to a safe directory name. The host is already charset-
    /// validated, but a `:` from an IPv6 literal is a poor path component, so
    /// map anything outside `[A-Za-z0-9._-]` to `_`.
    static func sanitizedComponent(_ host: String) -> String {
        let mapped = host.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let result = String(mapped)
        return result.isEmpty ? "_" : result
    }

    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars)
}

/// rsync-over-ssh pull of a remote instance's session logs.
///
/// Security model:
/// - The argv is an ARRAY passed straight to `Process` — host/user are literal
///   elements, never interpolated into a shell string, so a hostile host/user
///   value can't inject a command (and they're charset-validated anyway).
/// - `ssh -o BatchMode=yes` → key-only; never prompts for a password and fails
///   fast if no key works.
/// - `ConnectTimeout=10` + rsync `--timeout=20` → an unreachable box can't hang.
/// - `StrictHostKeyChecking=accept-new` → a brand-new host is trusted on first
///   connect, but a CHANGED key still aborts (surfaced as "Host key changed").
final class RemoteLogSyncService: RemoteLogSyncServiceProtocol, @unchecked Sendable {
    static let rsyncPath = "/usr/bin/rsync"
    static let sshOptions = "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

    private let runner: RemoteProcessRunner
    private let cacheRoot: URL

    init(runner: @escaping RemoteProcessRunner = RemoteLogSyncService.defaultRunner,
         cacheRoot: URL = RemoteLogCache.root) {
        self.runner = runner
        self.cacheRoot = cacheRoot
    }

    func sync(_ instance: RemoteInstance) async -> RemoteSyncOutcome {
        guard RemoteInstanceValidation.isValidHost(instance.host),
              RemoteInstanceValidation.isValidUser(instance.user) else {
            return .failed(Self.message(for: .invalidInstance))
        }

        let cacheDir = RemoteLogCache.directory(forHost: instance.host, root: cacheRoot)
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            logger.error("cache dir create failed: \(error.localizedDescription, privacy: .public)")
            return .failed(Self.message(for: .cacheUnavailable))
        }

        let args = Self.rsyncArguments(user: instance.user, host: instance.host, cacheDirectory: cacheDir)
        let result = await runner(Self.rsyncPath, args)

        guard result.exitCode == 0 else {
            return .failed(Self.message(for: Self.classify(exitCode: result.exitCode, standardError: result.standardError)))
        }
        return .ok(fileCount: Self.jsonlFileCount(in: cacheDir), date: Date())
    }

    // MARK: - Argument vector (pure, unit-tested)

    /// The exact rsync argv. Pure + static so the security-critical argument
    /// vector is testable without spawning a process. `-e` and the ssh options
    /// are two elements (flag + value); `<user>@<host>:...` and the local
    /// destination are their own literal elements — never a shell string.
    static func rsyncArguments(user: String, host: String, cacheDirectory: URL) -> [String] {
        let destination = cacheDirectory.path.hasSuffix("/") ? cacheDirectory.path : cacheDirectory.path + "/"
        return [
            "-az",
            "--timeout=20",
            "-e", sshOptions,
            "--include=*/",
            "--include=*.jsonl",
            "--exclude=*",
            "\(user)@\(host):.claude/projects/",
            destination
        ]
    }

    // MARK: - Failure classification (pure, unit-tested)

    /// Maps an rsync/ssh non-zero exit + stderr to a friendly failure. Keyed on
    /// stderr text because rsync/ssh exit codes overlap across failure modes.
    static func classify(exitCode: Int32, standardError: String) -> RemoteSyncFailure {
        let err = standardError.lowercased()
        if err.contains("host key") || err.contains("host identification has changed")
            || err.contains("remote host identification") {
            return .hostKeyChanged
        }
        if err.contains("permission denied") || err.contains("publickey")
            || err.contains("authentication failed") || err.contains("no more authentication methods") {
            return .permissionDenied
        }
        if err.contains("timed out") || err.contains("timeout") || err.contains("connection timed out") {
            return .timedOut
        }
        if err.contains("command not found") || err.contains("rsync: not found")
            || (err.contains("rsync") && err.contains("no such file")) {
            return .rsyncMissing
        }
        if err.contains("could not resolve") || err.contains("name or service not known")
            || err.contains("no route to host") || err.contains("could not connect")
            || err.contains("connection refused") {
            return .unreachable
        }
        return .other(exitCode)
    }

    /// Localizes a classified failure for the status line.
    static func message(for failure: RemoteSyncFailure) -> String {
        switch failure {
        case .invalidInstance:   return String(localized: "remote.error.invalid")
        case .cacheUnavailable:  return String(localized: "remote.error.cache")
        case .timedOut:          return String(localized: "remote.error.timeout")
        case .permissionDenied:  return String(localized: "remote.error.permission")
        case .rsyncMissing:      return String(localized: "remote.error.norsync")
        case .hostKeyChanged:    return String(localized: "remote.error.hostkey")
        case .unreachable:       return String(localized: "remote.error.unreachable")
        case .other(let code):   return String(format: String(localized: "remote.error.generic"), code)
        }
    }

    // MARK: - Helpers

    private static func jsonlFileCount(in dir: URL) -> Int {
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in en where url.pathExtension == "jsonl" { count += 1 }
        return count
    }

    /// Spawns the tool and captures stdout/stderr + exit code. Runs off the
    /// main actor via the cooperative pool; the termination handler resumes the
    /// continuation once the child exits (or fails to launch).
    static let defaultRunner: RemoteProcessRunner = { launchPath, arguments in
        await withCheckedContinuation { (continuation: CheckedContinuation<RemoteProcessResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let out = Pipe()
            let errPipe = Pipe()
            process.standardOutput = out
            process.standardError = errPipe
            process.terminationHandler = { finished in
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: RemoteProcessResult(
                    exitCode: finished.terminationStatus,
                    standardOutput: String(data: outData, encoding: .utf8) ?? "",
                    standardError: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: RemoteProcessResult(
                    exitCode: -1, standardOutput: "", standardError: error.localizedDescription
                ))
            }
        }
    }
}
