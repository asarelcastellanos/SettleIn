import Foundation
@testable import SettleInCore

/// Builds a `TeamID` from a literal the test controls. A bad literal stops the run.
func teamID(_ raw: String) -> TeamID {
    guard let id = TeamID(raw) else { fatalError("not a Team ID: \(raw)") }
    return id
}

/// The captured tool output in `Tests/Fixtures/`. `Fixtures/README.txt` says where each file came from.
enum Fixture {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SettleInCoreTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
}

/// Plays back canned results and records each call. It answers by tool name and first argument.
actor FakeCommandRunner: CommandRunner {
    struct Call: Equatable {
        let tool: String
        let arguments: [String]
    }

    private let responses: [String: CommandResult]
    private let launchFailure: Bool
    private(set) var calls: [Call] = []

    /// Keys are `codesign --verify`, `codesign -dv`, `spctl`, and `pkgutil`.
    init(_ responses: [String: CommandResult], launchFailure: Bool = false) {
        self.responses = responses
        self.launchFailure = launchFailure
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let tool = executable.lastPathComponent
        calls.append(Call(tool: tool, arguments: arguments))
        if launchFailure { throw CommandRunnerError.executableNotAbsolute("fake") }
        let key = tool == "codesign" ? "codesign \(arguments[0])" : tool
        return responses[key] ?? CommandResult(exitCode: 99, stderr: "no canned response for \(key)")
    }

    var toolNames: [String] { calls.map(\.tool) }
}

let expectedChrome = teamID("EQHXZ8M8AV")
let appURL = URL(fileURLWithPath: "/fixture/path/Some App.app")
let packageURL = URL(fileURLWithPath: "/fixture/path/Some.pkg")

func goodAppRunner() throws -> FakeCommandRunner {
    FakeCommandRunner([
        "codesign --verify": CommandResult(exitCode: 0, stderr: "valid on disk\n"),
        "codesign -dv": CommandResult(exitCode: 0, stderr: try Fixture.text("codesign-dv-developer-id-app.txt")),
        "spctl": CommandResult(exitCode: 0, stderr: try Fixture.text("spctl-accepted-developer-id-app.txt"))
    ])
}

func goodAppRunner(replacing key: String, with result: CommandResult) throws -> FakeCommandRunner {
    var responses: [String: CommandResult] = [
        "codesign --verify": CommandResult(exitCode: 0),
        "codesign -dv": CommandResult(exitCode: 0, stderr: try Fixture.text("codesign-dv-developer-id-app.txt")),
        "spctl": CommandResult(exitCode: 0)
    ]
    responses[key] = result
    return FakeCommandRunner(responses)
}
