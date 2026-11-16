import Foundation

/// Mounts a disk image read-only inside the private directory and detaches it again.
struct DiskImageMounter: Sendable {
    let runner: any CommandRunner
    let attachTimeout: Duration

    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    /// Attaches `image` at `<directory>/mnt`, runs `body` with the mount point, and detaches on every exit path,
    /// including when `body` throws. The attach uses `-nobrowse`, so Finder does not show the image,
    /// and it leaves checksum verification on, so `hdiutil` rejects a damaged image.
    func withMount<Value>(
        of image: URL,
        in directory: URL,
        body: (URL) async throws -> Value
    ) async throws -> Value {
        let mountPoint = directory.appendingPathComponent("mnt", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        } catch {
            throw InstallError.workingDirectoryFailed
        }
        let mounted: URL
        do {
            mounted = try await attach(image, at: mountPoint)
        } catch {
            await detach(mountPoint)
            throw error
        }
        do {
            let value = try await body(mounted)
            await detach(mountPoint)
            return value
        } catch {
            await detach(mountPoint)
            throw error
        }
    }

    private func attach(_ image: URL, at mountPoint: URL) async throws -> URL {
        let arguments = ["attach", "-nobrowse", "-readonly", "-noautoopen",
                         "-mountpoint", mountPoint.path, "-plist", image.path]
        let runner = self.runner
        let result: CommandResult?
        do {
            result = try await TimedCommand.run(timeout: attachTimeout) {
                try await runner.run(executable: Self.hdiutil, arguments: arguments)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InstallError.mountFailed(detail: "The hdiutil tool did not start.")
        }
        guard let result else { throw InstallError.mountTimedOut }
        guard result.exitCode == 0 else {
            throw InstallError.mountFailed(detail: ToolOutput.summary(of: result))
        }
        guard let reported = Self.mountPoint(inAttachPlist: result.stdout, expecting: mountPoint) else {
            throw InstallError.mountFailed(detail: "The hdiutil output did not name the mount point.")
        }
        return reported
    }

    /// Detaches `mountPoint`, and retries once with `-force` when the first try fails. A failure after the retry
    /// is not an error for the install, because the app is already copied or the install already failed.
    private func detach(_ mountPoint: URL) async {
        let first = try? await runner.run(executable: Self.hdiutil, arguments: ["detach", mountPoint.path])
        if first?.exitCode == 0 { return }
        _ = try? await runner.run(executable: Self.hdiutil, arguments: ["detach", "-force", mountPoint.path])
    }

    /// Returns the `mount-point` entry that is the folder SettleIn asked for. Any other mount point is ignored.
    static func mountPoint(inAttachPlist output: String, expecting requested: URL) -> URL? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil),
            let root = plist as? [String: Any],
            let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }
        let wanted = requested.resolvingSymlinksInPath().path
        return entities
            .compactMap { $0["mount-point"] as? String }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first { $0.resolvingSymlinksInPath().path == wanted }
    }
}

enum ToolOutput {
    /// The last lines of the tool's output, capped so one failure cannot fill the UI.
    static func summary(of result: CommandResult) -> String {
        let text = result.combinedOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " ")
        let detail = text.isEmpty ? "The tool exited with code \(result.exitCode)." : text
        return detail.count > 300 ? String(detail.prefix(300)) + "..." : detail
    }
}

/// Runs one command and gives up after a time limit.
enum TimedCommand {
    /// Returns nil when the limit passes first. The limit cancels the command's task, and the caller stops
    /// waiting even when the command ignores the cancellation.
    static func run(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> CommandResult
    ) async throws -> CommandResult? {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task { try await operation() }
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                work.cancel()
                once.resume(.success(nil))
            }
            Task {
                let result = await work.result
                timer.cancel()
                once.resume(result.map { Optional($0) })
            }
        }
    }
}

/// Resumes a continuation on the first call and ignores every later call.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult?, Error>?

    init(_ continuation: CheckedContinuation<CommandResult?, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<CommandResult?, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
