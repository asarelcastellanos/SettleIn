import Foundation

/// Where one app is in an install or uninstall.
///
/// An install runs `downloading`, then `verifying`, then `installing`, then `installed`. The reducer has
/// no event that moves `downloading` straight to `installing`, so no run reaches `installing` without
/// passing `verifying`. `InstallStateTests` checks this on the whole transition graph.
///
/// For a dmg or zip, the installer checks the signature inside its call, so `verifying` lasts until the app
/// is checked and copied. For a pkg, `installing` means SettleIn waits for Installer.app.
public enum InstallState: Equatable, Sendable {
    case idle
    /// `progress` is the fraction from 0 to 1, or `nil` while the server has not announced a size.
    case downloading(progress: Double?)
    case verifying
    case installing
    case installed
    case uninstalling
    case failed(InstallFailure)

    /// True while an operation runs. A busy app refuses every new request.
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing, .uninstalling: true
        case .idle, .installed, .failed: false
        }
    }

    /// The case name without its values. The log uses it so progress ticks do not fill the log.
    var name: String {
        switch self {
        case .idle: "idle"
        case .downloading: "downloading"
        case .verifying: "verifying"
        case .installing: "installing"
        case .installed: "installed"
        case .uninstalling: "uninstalling"
        case .failed: "failed"
        }
    }
}

/// Something that happened to an app. The orchestrator turns results from the engine into events.
public enum InstallEvent: Equatable, Sendable {
    case installRequested
    case uninstallRequested
    /// The launch check found the app on this Mac.
    case appFound
    /// A `nil` fraction means the size is still unknown. The reducer never lowers the fraction.
    case downloadProgressed(fraction: Double?)
    case downloadFinished
    /// The signature check passed.
    case verified
    case installFinished
    case uninstallFinished
    /// The user answered no to a question the installer or the uninstaller asked. The app returns to the state
    /// it had before the request, and no failure shows.
    case declined
    /// The user cancelled the download, or the macOS installer quit without installing the app.
    case cancelled
    case failed(InstallFailure)
}

extension InstallState {
    /// The next state for `event`. An event that makes no sense in the current state returns the state
    /// unchanged. This function does no I/O.
    public func reduce(_ event: InstallEvent) -> InstallState {
        switch self {
        case .idle: reduceIdle(event)
        case .downloading(let progress): reduceDownloading(progress, event)
        case .verifying: reduceVerifying(event)
        case .installing: event == .installFinished ? .installed : endingEarly(event)
        case .installed: event == .uninstallRequested ? .uninstalling : self
        case .uninstalling: reduceUninstalling(event)
        case .failed: reduceFailed(event)
        }
    }

    private func reduceIdle(_ event: InstallEvent) -> InstallState {
        switch event {
        case .installRequested: .downloading(progress: nil)
        case .appFound: .installed
        default: self
        }
    }

    private func reduceDownloading(_ progress: Double?, _ event: InstallEvent) -> InstallState {
        switch event {
        case .downloadProgressed(let fraction): .downloading(progress: Self.advance(progress, to: fraction))
        case .downloadFinished: .verifying
        default: endingEarly(event)
        }
    }

    private func reduceVerifying(_ event: InstallEvent) -> InstallState {
        switch event {
        case .verified: .installing
        case .declined: .idle
        default: endingEarly(event)
        }
    }

    private func reduceUninstalling(_ event: InstallEvent) -> InstallState {
        switch event {
        case .uninstallFinished: .idle
        case .declined: .installed
        default: failing(event)
        }
    }

    private func reduceFailed(_ event: InstallEvent) -> InstallState {
        switch event {
        case .installRequested: .downloading(progress: nil)
        case .uninstallRequested: .uninstalling
        default: self
        }
    }

    /// A running install ends early when the user cancels or the engine reports a failure.
    private func endingEarly(_ event: InstallEvent) -> InstallState {
        event == .cancelled ? .idle : failing(event)
    }

    private func failing(_ event: InstallEvent) -> InstallState {
        guard case .failed(let failure) = event else { return self }
        return .failed(failure)
    }

    /// Keeps the larger fraction, clamped to 0...1, so late progress reports never move the bar back.
    private static func advance(_ current: Double?, to fraction: Double?) -> Double? {
        guard let fraction, !fraction.isNaN else { return current }
        let clamped = min(max(fraction, 0), 1)
        return max(current ?? 0, clamped)
    }
}
