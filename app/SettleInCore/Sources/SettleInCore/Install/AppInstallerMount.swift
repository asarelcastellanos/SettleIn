import Foundation

/// Mounts a disk image read-only inside the private directory and detaches it again.
struct DiskImageMounter: Sendable {
    let runner: any CommandRunner
    let attachTimeout: Duration
    /// Receives a note when a mounted image cannot be detached.
    let report: InstallReport?

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
            await detach(mountPoint, reportingFailure: true)
            return value
        } catch {
            await detach(mountPoint, reportingFailure: true)
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
    /// is not an error for the install, because the app is already copied or the install already failed. With
    /// `reportingFailure`, the failure goes to `report`. A failed attach passes false, because nothing is mounted.
    ///
    /// The detach runs in a detached task. A cancelled install still has to unmount the image, and a runner
    /// call inside a cancelled task throws at once.
    private func detach(_ mountPoint: URL, reportingFailure: Bool = false) async {
        let runner = self.runner
        let report = reportingFailure ? self.report : nil
        await Task.detached {
            await Self.detachNow(mountPoint, runner: runner, report: report)
        }.value
    }

    private static func detachNow(_ mountPoint: URL, runner: any CommandRunner, report: InstallReport?) async {
        let first = try? await runner.run(executable: hdiutil, arguments: ["detach", mountPoint.path])
        if first?.exitCode == 0 { return }
        let forced = try? await runner.run(executable: hdiutil, arguments: ["detach", "-force", mountPoint.path])
        guard let report, forced?.exitCode != 0 else { return }
        let outcome = forced.map { "hdiutil exited with code \($0.exitCode)" } ?? "hdiutil did not start"
        report("the disk image mounted at \(mountPoint.path) was not detached, and \(outcome)")
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
    /// Returns nil when the limit passes first. The limit cancels the command's task and then waits until the
    /// command has ended, so the caller never goes on while the child process still runs. The runner ends the
    /// child when it sees the cancellation.
    static func run(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> CommandResult
    ) async throws -> CommandResult? {
        let work = Task { try await operation() }
        let expiry = Expiry()
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            expiry.mark()
            work.cancel()
        }
        let outcome = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        timer.cancel()
        if expiry.hasExpired, case .failure = outcome { return nil }
        return try outcome.get()
    }
}

/// Records that the time limit passed.
private final class Expiry: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false

    func mark() { lock.withLock { expired = true } }
    var hasExpired: Bool { lock.withLock { expired } }
}
