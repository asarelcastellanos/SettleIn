import Foundation
import Testing
@testable import SettleInCore

struct InstallStatusTextTests {
    private static let archive = OrchestratorFixture.app(.dmg).install
    private static let zip = OrchestratorFixture.app(.zip).install
    private static let package = OrchestratorFixture.app(.pkg).install

    @Test(arguments: [archive, zip])
    func anArchiveInstallSaysCheckingAndInstallingWhileTheInstallerRuns(_ install: InstallMethod) {
        #expect(InstallState.verifying.statusText(for: install) == "Checking and installing")
        #expect(InstallState.installing.statusText(for: install) == "Installing")
    }

    @Test func aPackageInstallSaysWaitingForInstallerWhileThePollRuns() {
        #expect(InstallState.verifying.statusText(for: Self.package) == "Verifying")
        #expect(InstallState.installing.statusText(for: Self.package) == "Waiting for Installer")
    }

    @Test func onlyAWaitingPackageRowOffersToStopWaiting() {
        #expect(InstallState.installing.canStopWaiting(for: Self.package))
        for install in [Self.archive, Self.zip] {
            #expect(!InstallState.installing.canStopWaiting(for: install))
        }
        let others: [InstallState] = [.idle, .downloading(progress: nil), .verifying, .installed, .uninstalling]
        for state in others {
            #expect(!state.canStopWaiting(for: Self.package), "\(state.name)")
        }
    }

    @Test(arguments: [archive, zip, package])
    func theOtherStatesReadTheSameForEveryInstallType(_ install: InstallMethod) {
        #expect(InstallState.idle.statusText(for: install) == "Not installed")
        #expect(InstallState.downloading(progress: nil).statusText(for: install) == "Downloading")
        #expect(InstallState.downloading(progress: 0.42).statusText(for: install) == "Downloading, 42%")
        #expect(InstallState.installed.statusText(for: install) == "Installed")
        #expect(InstallState.uninstalling.statusText(for: install) == "Uninstalling")
        #expect(InstallState.failed(.interrupted).statusText(for: install) == "Failed")
    }
}
