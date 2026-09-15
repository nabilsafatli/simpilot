import Foundation
@testable import SimulatorManagerKit

/// A `CommandRunner` that answers from fixtures and records what it was asked.
///
/// This is what makes the destructive code paths testable: `deleteDevice` can be
/// proven to issue exactly `xcrun simctl delete <UUID>` and nothing else, without
/// a simulator ever being removed.
actor FakeCommandRunner: CommandRunner {
    private var responses: [[String]: CommandResult] = [:]
    private(set) var executedCommands: [SimctlCommand] = []

    init(fixtures: [SimctlCommand: String] = [:]) throws {
        for (command, fixtureName) in fixtures {
            responses[command.arguments] = CommandResult(
                standardOutput: try Fixture.data(fixtureName),
                standardError: Data(),
                exitCode: 0
            )
        }
    }

    func stub(_ command: SimctlCommand, fixture: String) throws {
        responses[command.arguments] = CommandResult(
            standardOutput: try Fixture.data(fixture),
            standardError: Data(),
            exitCode: 0
        )
    }

    func stubFailure(_ command: SimctlCommand, exitCode: Int32, message: String) {
        responses[command.arguments] = CommandResult(
            standardOutput: Data(),
            standardError: Data(message.utf8),
            exitCode: exitCode
        )
    }

    func run(_ command: SimctlCommand) async throws -> CommandResult {
        executedCommands.append(command)
        // Unstubbed commands succeed with empty output, which is what simctl does
        // for destructive operations.
        return responses[command.arguments]
            ?? CommandResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
    }

    var destructiveCommands: [SimctlCommand] {
        executedCommands.filter(\.isDestructive)
    }
}
