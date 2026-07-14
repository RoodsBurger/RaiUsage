import Testing
import Foundation

@Suite("RemoteLogSyncService argv + errors")
struct RemoteLogSyncServiceTests {

    // MARK: - Argument vector (injection safety)

    @Test("rsync argv is an array with literal user@host and cache destination")
    func rsyncArgumentVector() {
        let cacheDir = URL(fileURLWithPath: "/cache/remote-logs/10.63.7.150")
        let args = RemoteLogSyncService.rsyncArguments(
            user: "ubuntu", host: "10.63.7.150", cacheDirectory: cacheDir
        )

        #expect(args == [
            "-az",
            "--timeout=20",
            "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new",
            "--include=*/",
            "--include=*.jsonl",
            "--exclude=*",
            "ubuntu@10.63.7.150:.claude/projects/",
            "/cache/remote-logs/10.63.7.150/"
        ])
    }

    @Test("the ssh options are a single argv element after -e")
    func sshOptionsAreOneElement() {
        let args = RemoteLogSyncService.rsyncArguments(
            user: "ubuntu", host: "h", cacheDirectory: URL(fileURLWithPath: "/c")
        )
        let eIndex = args.firstIndex(of: "-e")
        #expect(eIndex != nil)
        #expect(args[eIndex! + 1] == RemoteLogSyncService.sshOptions)
    }

    @Test("no argv element is a shell string or interpolates the host into one")
    func noShellString() {
        let args = RemoteLogSyncService.rsyncArguments(
            user: "ubuntu", host: "10.63.7.150", cacheDirectory: URL(fileURLWithPath: "/c")
        )
        // The target is its own literal element, never wrapped in a shell call.
        #expect(args.contains("ubuntu@10.63.7.150:.claude/projects/"))
        for arg in args {
            #expect(!arg.contains("&&"))
            #expect(!arg.contains(";"))
            #expect(!arg.contains("|"))
            #expect(!arg.hasPrefix("/bin/sh"))
            #expect(arg != "-c")
        }
    }

    @Test("cache directory carries the sanitized host as a path component")
    func cacheDirSanitizesHost() {
        // IPv6 colon is not a good path component -> mapped to underscore.
        let dir = RemoteLogCache.directory(forHost: "fe80::1", root: URL(fileURLWithPath: "/root"))
        #expect(dir.lastPathComponent == "fe80__1")
        #expect(RemoteLogCache.sanitizedComponent("10.63.7.150") == "10.63.7.150")
        #expect(RemoteLogCache.sanitizedComponent("host name!") == "host_name_")
    }

    // MARK: - Failure classification

    @Test("classifies common ssh/rsync failures into friendly categories")
    func classifiesFailures() {
        #expect(RemoteLogSyncService.classify(exitCode: 255, standardError: "ssh: connect to host 1.2.3.4 port 22: Operation timed out") == .timedOut)
        #expect(RemoteLogSyncService.classify(exitCode: 255, standardError: "Permission denied (publickey).") == .permissionDenied)
        #expect(RemoteLogSyncService.classify(exitCode: 127, standardError: "bash: rsync: command not found") == .rsyncMissing)
        #expect(RemoteLogSyncService.classify(exitCode: 255, standardError: "@@@ REMOTE HOST IDENTIFICATION HAS CHANGED! @@@") == .hostKeyChanged)
        #expect(RemoteLogSyncService.classify(exitCode: 255, standardError: "ssh: Could not resolve hostname foo: nodename nor servname provided") == .unreachable)
        #expect(RemoteLogSyncService.classify(exitCode: 23, standardError: "some other rsync warning about partial transfer") == .other(23))
    }

    // MARK: - End-to-end via injected runner (no real ssh)

    @Test("sync builds the rsync command via the runner and reports success")
    func syncUsesRunnerAndSucceeds() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("raiusage-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let captured = CapturedInvocation()
        let runner: RemoteProcessRunner = { launchPath, arguments in
            await captured.record(launchPath: launchPath, arguments: arguments)
            return RemoteProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let service = RemoteLogSyncService(runner: runner, cacheRoot: tmp)
        let instance = RemoteInstance(host: "10.63.7.150", user: "ubuntu", nickname: "prod")

        let outcome = await service.sync(instance)

        let launchPath = await captured.launchPath
        let arguments = await captured.arguments
        #expect(launchPath == "/usr/bin/rsync")
        #expect(arguments.contains("ubuntu@10.63.7.150:.claude/projects/"))
        // Destination is the per-host cache under the injected root.
        #expect(arguments.last?.contains("/10.63.7.150/") == true)
        if case .ok = outcome { } else { Issue.record("expected .ok, got \(outcome)") }
    }

    @Test("sync maps a runner failure to the friendly permission-denied string")
    func syncMapsFailure() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("raiusage-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let runner: RemoteProcessRunner = { _, _ in
            RemoteProcessResult(exitCode: 255, standardOutput: "", standardError: "Permission denied (publickey).")
        }
        let service = RemoteLogSyncService(runner: runner, cacheRoot: tmp)
        let outcome = await service.sync(RemoteInstance(host: "h", user: "ubuntu"))
        #expect(outcome == .failed(RemoteLogSyncService.message(for: .permissionDenied)))
    }

    @Test("sync refuses an instance with an invalid host without spawning a runner")
    func syncRefusesInvalidInstance() async {
        let captured = CapturedInvocation()
        let runner: RemoteProcessRunner = { launchPath, arguments in
            await captured.record(launchPath: launchPath, arguments: arguments)
            return RemoteProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let service = RemoteLogSyncService(runner: runner)
        // Host validation happens BEFORE any cache/runner work.
        let outcome = await service.sync(RemoteInstance(host: "bad;host", user: "ubuntu"))
        #expect(outcome == .failed(RemoteLogSyncService.message(for: .invalidInstance)))
        let didRun = await captured.didRun
        #expect(!didRun)
    }

    /// Actor to safely capture the runner invocation across the await boundary.
    private actor CapturedInvocation {
        private(set) var launchPath = ""
        private(set) var arguments: [String] = []
        private(set) var didRun = false
        func record(launchPath: String, arguments: [String]) {
            self.launchPath = launchPath
            self.arguments = arguments
            self.didRun = true
        }
    }
}
