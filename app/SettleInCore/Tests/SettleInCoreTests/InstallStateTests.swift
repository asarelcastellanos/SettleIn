import Foundation
import Testing
@testable import SettleInCore

private let failure = InstallFailure.download(.insecureScheme)

private struct Transition: Sendable, CustomTestStringConvertible {
    let from: InstallState
    let event: InstallEvent
    let result: InstallState

    var testDescription: String { "\(from.name) + \(event.name) -> \(result.name)" }
}

private extension InstallEvent {
    var name: String {
        switch self {
        case .installRequested: "installRequested"
        case .uninstallRequested: "uninstallRequested"
        case .appFound: "appFound"
        case .downloadProgressed: "downloadProgressed"
        case .downloadFinished: "downloadFinished"
        case .verified: "verified"
        case .installFinished: "installFinished"
        case .uninstallFinished: "uninstallFinished"
        case .declined: "declined"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}

/// Every state and every event, with one sample value for each case that carries a value.
private let allStates: [InstallState] = [
    .idle, .downloading(progress: 0.5), .verifying, .installing, .installed, .uninstalling, .failed(failure)
]
private let allEvents: [InstallEvent] = [
    .installRequested, .uninstallRequested, .appFound, .downloadProgressed(fraction: 0.9), .downloadFinished,
    .verified, .installFinished, .uninstallFinished, .declined, .cancelled, .failed(failure)
]

/// The complete list of valid transitions. A pair that is not listed here must leave the state unchanged.
private let validTransitions: [Transition] = [
    Transition(from: .idle, event: .installRequested, result: .downloading(progress: nil)),
    Transition(from: .failed(failure), event: .installRequested, result: .downloading(progress: nil)),
    Transition(from: .installed, event: .uninstallRequested, result: .uninstalling),
    Transition(from: .failed(failure), event: .uninstallRequested, result: .uninstalling),
    Transition(from: .idle, event: .appFound, result: .installed),
    Transition(
        from: .downloading(progress: 0.5), event: .downloadProgressed(fraction: 0.9),
        result: .downloading(progress: 0.9)
    ),
    Transition(from: .downloading(progress: 0.5), event: .downloadFinished, result: .verifying),
    Transition(from: .downloading(progress: 0.5), event: .cancelled, result: .idle),
    Transition(from: .downloading(progress: 0.5), event: .failed(failure), result: .failed(failure)),
    Transition(from: .verifying, event: .verified, result: .installing),
    Transition(from: .verifying, event: .cancelled, result: .idle),
    Transition(from: .verifying, event: .declined, result: .idle),
    Transition(from: .verifying, event: .failed(failure), result: .failed(failure)),
    Transition(from: .installing, event: .installFinished, result: .installed),
    Transition(from: .installing, event: .cancelled, result: .idle),
    Transition(from: .installing, event: .failed(failure), result: .failed(failure)),
    Transition(from: .uninstalling, event: .uninstallFinished, result: .idle),
    Transition(from: .uninstalling, event: .declined, result: .installed),
    Transition(from: .uninstalling, event: .failed(failure), result: .failed(failure))
]

struct InstallStateTests {
    @Test(arguments: validTransitions)
    private func validTransitionMovesToTheNextState(_ transition: Transition) {
        #expect(transition.from.reduce(transition.event) == transition.result)
    }

    @Test func everyEventOutsideTheValidListLeavesTheStateUnchanged() {
        let valid = Set(validTransitions.map { "\($0.from.name)|\($0.event.name)" })
        var checked = 0
        for state in allStates {
            for event in allEvents where !valid.contains("\(state.name)|\(event.name)") {
                #expect(state.reduce(event) == state, "\(state.name) + \(event.name) changed the state")
                checked += 1
            }
        }
        #expect(checked == allStates.count * allEvents.count - validTransitions.count)
    }

    @Test func installRequestWhileDownloadingLeavesTheStateUnchanged() {
        let state = InstallState.downloading(progress: 0.25)
        #expect(state.reduce(.installRequested) == state)
    }

    // MARK: Declined

    @Test func aDeclinedInstallReturnsToIdleAndAnUninstallReturnsToInstalled() {
        #expect(InstallState.verifying.reduce(.declined) == .idle)
        #expect(InstallState.uninstalling.reduce(.declined) == .installed)
    }

    @Test func declinedChangesNoOtherState() {
        let others: [InstallState] = [.idle, .downloading(progress: 0.5), .installing, .installed, .failed(failure)]
        for state in others {
            #expect(state.reduce(.declined) == state, "\(state.name) + declined changed the state")
        }
    }

    // MARK: Verification gate

    @Test func noEventMovesDownloadingStraightToInstalling() {
        for event in allEvents {
            #expect(InstallState.downloading(progress: 0.5).reduce(event) != .installing)
        }
    }

    /// Walks every state that is reachable from `downloading` without entering `verifying`. If `installing`
    /// were among them, an install could skip verification.
    @Test func installingIsUnreachableFromDownloadingWithoutVerifying() {
        var seen: [InstallState] = [.downloading(progress: nil)]
        var queue = seen
        while let state = queue.popLast() {
            guard state != .verifying else { continue }
            for event in allEvents {
                let next = state.reduce(event)
                if !seen.contains(next) {
                    seen.append(next)
                    queue.append(next)
                }
            }
        }
        #expect(!seen.contains(.installing))
        #expect(seen.contains(.verifying))
    }

    @Test func installingIsReachableThroughVerifying() {
        let state = InstallState.downloading(progress: nil)
            .reduce(.downloadFinished)
            .reduce(.verified)
        #expect(state == .installing)
    }

    // MARK: Progress

    @Test func progressNeverMovesBackward() {
        var state = InstallState.downloading(progress: 0.6)
        state = state.reduce(.downloadProgressed(fraction: 0.4))
        #expect(state == .downloading(progress: 0.6))
    }

    @Test func progressIsClampedToTheUnitRange() {
        #expect(InstallState.downloading(progress: nil).reduce(.downloadProgressed(fraction: 7))
            == .downloading(progress: 1))
        #expect(InstallState.downloading(progress: nil).reduce(.downloadProgressed(fraction: -3))
            == .downloading(progress: 0))
    }

    @Test func unknownOrInvalidProgressKeepsTheCurrentValue() {
        #expect(InstallState.downloading(progress: 0.3).reduce(.downloadProgressed(fraction: nil))
            == .downloading(progress: 0.3))
        #expect(InstallState.downloading(progress: 0.3).reduce(.downloadProgressed(fraction: .nan))
            == .downloading(progress: 0.3))
        #expect(InstallState.downloading(progress: nil).reduce(.downloadProgressed(fraction: nil))
            == .downloading(progress: nil))
    }

    // MARK: Busy states

    @Test func busyStatesAreTheOnesWhereAnOperationRuns() {
        let busy = allStates.filter(\.isBusy).map(\.name)
        #expect(busy == ["downloading", "verifying", "installing", "uninstalling"])
    }
}
