import Foundation

public struct CommandResult: Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let exitCode: Int32

    public var isSuccess: Bool { exitCode == 0 }

    public var standardErrorText: String {
        String(data: standardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public init(standardOutput: Data, standardError: Data, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

/// Runs `simctl` commands.
///
/// Abstracted so the entire service layer can be exercised against recorded
/// output. Nothing above this protocol spawns a process, which is what allows
/// the destructive code paths to be tested without deleting anything.
public protocol CommandRunner: Sendable {
    func run(_ command: SimctlCommand) async throws -> CommandResult
}

public enum SimctlError: Error, LocalizedError, Sendable {
    /// `simctl` ships only with full Xcode — the Command Line Tools package does
    /// not include it — so this is a real first-run state, not an edge case.
    case xcodeNotFound(detail: String)
    case commandFailed(command: SimctlCommand, exitCode: Int32, message: String)
    case invalidOutput(command: SimctlCommand, underlying: String)
    /// A runtime simctl itself marks as undeletable.
    case runtimeNotDeletable(runtimeName: String)
    /// A runtime known to the inventory but absent from `simctl runtime list`,
    /// and therefore unaddressable for deletion.
    case runtimeHasNoDeletableImage(runtimeName: String)

    public var errorDescription: String? {
        switch self {
        case .xcodeNotFound(let detail):
            "Xcode was not found. The Simulator tools ship with Xcode, not with the Command Line Tools. \(detail)"
        case .commandFailed(let command, let exitCode, let message):
            "`\(command.displayString)` failed with exit code \(exitCode). \(message)"
        case .invalidOutput(let command, let underlying):
            "Could not read the output of `\(command.displayString)`. \(underlying)"
        case .runtimeNotDeletable(let name):
            "\(name) cannot be deleted. simctl reports this runtime as not deletable."
        case .runtimeHasNoDeletableImage(let name):
            "\(name) has no deletable disk image, so it cannot be removed this way."
        }
    }
}
