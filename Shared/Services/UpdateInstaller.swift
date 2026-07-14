import AppKit

/// Downloads a release DMG and swap-installs /Applications/RaiUsage.app.
/// Fail-closed: every step throws a user-readable error, and the new bundle
/// lands under a temporary name first so an interrupted copy can never leave
/// a half-written bundle where the working install was.
final class UpdateInstaller: UpdateInstallerProtocol, @unchecked Sendable {
    static let installedAppURL = URL(fileURLWithPath: "/Applications/RaiUsage.app")
    /// Hidden staging name inside /Applications, swapped into place by a
    /// same-volume rename once the copy has fully succeeded.
    static let stagingAppURL = URL(fileURLWithPath: "/Applications/.RaiUsage.update.app")
    private static let appBundleName = "RaiUsage.app"

    // MARK: - Download

    func download(from url: URL, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("RaiUsage-update-\(UUID().uuidString).dmg")

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateInstallerError.downloadFailed("HTTP \(code)")
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        // -1 when the server sends no Content-Length -> indeterminate (nil).
        let expected = http.expectedContentLength
        var buffer = Data(capacity: 128 * 1024)
        var received: Int64 = 0
        onProgress(expected > 0 ? 0 : nil)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 128 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    onProgress(min(1, Double(received) / Double(expected)))
                }
            }
        }
        try handle.write(contentsOf: buffer)
        onProgress(expected > 0 ? 1 : nil)
        return destination
    }

    // MARK: - Install

    func install(dmgAt dmgURL: URL) async throws {
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory
            .appendingPathComponent("RaiUsage-mount-\(UUID().uuidString)")

        try await run("/usr/bin/hdiutil", ["attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        do {
            let newApp = mountPoint.appendingPathComponent(Self.appBundleName)
            guard fm.fileExists(atPath: newApp.path) else {
                throw UpdateInstallerError.appNotFoundInDMG
            }

            // Stage under a temp name, then swap: rm old + rename staged.
            try? fm.removeItem(at: Self.stagingAppURL)
            try await run("/bin/cp", ["-R", newApp.path, Self.stagingAppURL.path])
            if fm.fileExists(atPath: Self.installedAppURL.path) {
                try fm.removeItem(at: Self.installedAppURL)
            }
            try fm.moveItem(at: Self.stagingAppURL, to: Self.installedAppURL)
            // Ad-hoc-signed, non-notarized DMG: clear quarantine, or
            // Gatekeeper blocks the relaunched copy.
            try await run("/usr/bin/xattr", ["-cr", Self.installedAppURL.path])
        } catch {
            try? fm.removeItem(at: Self.stagingAppURL)
            try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fm.removeItem(at: dmgURL)
            throw error
        }
        try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        try? fm.removeItem(at: dmgURL)
    }

    // MARK: - Relaunch

    func relaunchInstalledApp() {
        // The detached shell outlives this process; the 1s sleep lets the old
        // instance fully exit before `open` starts the new one.
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 1; /usr/bin/open '\(Self.installedAppURL.path)'"]
        try? relauncher.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers

    /// Runs a tool to completion; throws with the tool's stderr on non-zero exit.
    private func run(_ toolPath: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = arguments
            process.standardOutput = Pipe()
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: UpdateInstallerError.commandFailed(
                        tool: (toolPath as NSString).lastPathComponent,
                        message: message.isEmpty ? "exit \(finished.terminationStatus)" : message
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
