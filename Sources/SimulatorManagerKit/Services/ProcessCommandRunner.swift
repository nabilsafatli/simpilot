import Foundation

/// Runs `simctl` by spawning `xcrun`.
///
/// This is the only type in the package that touches `Process`. It requires the
/// app to be built **without** the App Sandbox: a sandboxed process cannot spawn
/// `xcrun` nor read `~/Library/Developer/CoreSimulator`. That is why the app ships
/// Developer ID–signed and notarized rather than through the Mac App Store.
public struct ProcessCommandRunner: CommandRunner {
    private let xcrunURL: URL
    private let deviceSetPath: String?

    /// - Parameter deviceSetPath: an alternate device set for `simctl --set`.
    ///   Nil means the user's real device set, which is what the app always uses.
    ///   Supplying a path targets a completely separate set, which is how the
    ///   destructive paths are integration-tested for real without any risk to
    ///   the machine's actual simulators. The directory must already exist —
    ///   simctl will not create it.
    public init(
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        deviceSetPath: String? = nil
    ) {
        self.xcrunURL = xcrunURL
        self.deviceSetPath = deviceSetPath
    }

    public func run(_ command: SimctlCommand) async throws -> CommandResult {
        let xcrunURL = self.xcrunURL

        let deviceSetPath = self.deviceSetPath

        return try await withCheckedThrowingContinuation { continuation in
            // Run on a dedicated thread rather than the cooperative pool: the
            // reads below block, and blocking a cooperative thread can starve the
            // very tasks that are meant to make a refresh concurrent.
            Thread.detachNewThread {
                do {
                    continuation.resume(returning: try execute(
                        xcrunURL: xcrunURL, command: command, deviceSetPath: deviceSetPath
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func execute(
        xcrunURL: URL, command: SimctlCommand, deviceSetPath: String?
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = xcrunURL
        // `--set` must precede the subcommand.
        let setArguments = deviceSetPath.map { ["--set", $0] } ?? []
        process.arguments = ["simctl"] + setArguments + command.arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SimctlError.xcodeNotFound(
                detail: "Could not run \(xcrunURL.path): \(error.localizedDescription)"
            )
        }

        // Both pipes are drained concurrently, and both are drained to EOF before
        // waiting on the process.
        //
        // Draining only one first can deadlock: simctl blocks writing to a full
        // 64 KB buffer on the other while we wait on the one we chose. Waiting
        // before draining truncates output for the same reason. `simctl list
        // runtimes --json` is ~20 KB on a single-runtime machine and grows with
        // every runtime installed, so both failures are ordinary, not exotic.
        let standardOutput = DataBox()
        let standardError = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            standardOutput.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            standardError.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        return CommandResult(
            standardOutput: standardOutput.value,
            standardError: standardError.value,
            exitCode: process.terminationStatus
        )
    }
}

/// Carries pipe output back from the reader queues.
///
/// The `DispatchGroup` already establishes the ordering, but the compiler cannot
/// see that, and an unsynchronised captured `var` would be a data race by the
/// language's rules even where it happens to work.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage = data
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
