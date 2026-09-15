import Foundation

/// Whether this machine can do anything at all.
public enum ToolchainStatus: Hashable, Sendable {
    case ready(xcodePath: String, xcodeVersion: String?)
    /// Xcode is absent, or `xcode-select` points somewhere without simctl.
    ///
    /// A real state to design for rather than a crash: the Command Line Tools
    /// package does not include simctl, so a developer can have a working
    /// `git`, `clang` and `swift` and still have nothing for this app to show.
    case unavailable(reason: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Checks that simctl is actually reachable before the app reports an empty
/// inventory that a user would otherwise read as "you have no simulators".
public struct ToolchainProbe: Sendable {
    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    public func probe() async -> ToolchainStatus {
        do {
            // Any cheap read-only command proves the whole chain: xcrun resolves,
            // a developer directory is selected, and simctl exists inside it.
            let result = try await runner.run(.listRuntimes)
            guard result.isSuccess else {
                return .unavailable(reason: result.standardErrorText.isEmpty
                    ? "simctl exited with code \(result.exitCode)."
                    : result.standardErrorText)
            }
            return .ready(
                xcodePath: ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "selected Xcode",
                xcodeVersion: nil
            )
        } catch let error as SimctlError {
            return .unavailable(reason: error.errorDescription ?? "Unknown error.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }
}
