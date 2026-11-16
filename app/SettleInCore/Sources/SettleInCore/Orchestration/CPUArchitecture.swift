import Foundation

/// The processor family of this Mac, used to pick a download for a `perArch` catalog entry.
public enum CPUArchitecture: Equatable, Sendable {
    case arm64
    case intel

    /// Asks the kernel whether the hardware is Apple silicon. The answer stays `arm64` when the app
    /// runs under Rosetta, so an Apple silicon Mac gets the arm64 build.
    public static var current: CPUArchitecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isARM = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        return isARM ? .arm64 : .intel
    }
}

extension DownloadSource {
    /// The download for `architecture`. A `universal` entry returns its one download.
    public func download(for architecture: CPUArchitecture) -> CatalogDownload {
        switch self {
        case .universal(let download):
            return download
        case .perArch(let arm64, let intel):
            return architecture == .arm64 ? arm64 : intel
        }
    }
}
