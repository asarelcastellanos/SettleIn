import Foundation
import Testing
@testable import SettleInCore

// MARK: ProcessCommandRunner

struct ProcessCommandRunnerTests {
    private let runner = ProcessCommandRunner()

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
            arguments: ["--check-signature", "/fixture/missing.pkg"])
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty && result.stderr.contains("Package does not exist"))
    }

    @Test func passesEachArgumentWithoutAShell() async throws {
        let tricky = "$HOME; echo injected `id` > nowhere"
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [tricky, "-n"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == tricky + " -n\n")
    }

    @Test func largeOutputOnBothStreamsDoesNotBlock() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1000000", "/dev/zero"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 1_000_000)
    }

    @Test func nonFileExecutableThrows() async throws {
        let web = try #require(URL(string: "https://example.com/tool"))
        await #expect(throws: CommandRunnerError.self) { try await runner.run(executable: web, arguments: []) }
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/settlein-no-such-tool"), arguments: [])
        }
    }
}

// MARK: Source rules

struct SignatureSourceRulesTests {
    /// The issue's `grep` check as a test. No source file starts a shell or passes a shell option.
    @Test func sourcesContainNoShellLaunch() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SettleInCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SettleInCore
            .appendingPathComponent("Sources")
        let forbidden = ["/bin/sh", "/bin/zsh", "/bin/bash", "\"-c\""]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbidden {
                #expect(!text.contains(pattern), "\(file.lastPathComponent) contains \(pattern)")
            }
            checked += 1
        }
        #expect(checked > 0)
    }
}
