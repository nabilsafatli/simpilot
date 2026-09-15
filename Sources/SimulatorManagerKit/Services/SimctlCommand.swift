import Foundation

/// A single `simctl` invocation, as a value.
///
/// Commands are modelled rather than assembled inline so that every number and
/// every action in the UI can show the exact command behind it. This app exists
/// because reaching these answers by hand was tedious; it should not become a
/// black box in the process. A user who wants to verify a destructive action
/// before trusting it must be able to read, copy and run the same command.
public struct SimctlCommand: Hashable, Sendable {
    /// Arguments following `simctl`.
    public let arguments: [String]
    /// Whether this command changes state. Used to keep read-only inspection
    /// and destructive work visibly distinct.
    public let isDestructive: Bool

    private init(_ arguments: [String], isDestructive: Bool = false) {
        self.arguments = arguments
        self.isDestructive = isDestructive
    }

    /// The command exactly as a user would type it.
    public var displayString: String {
        (["xcrun", "simctl"] + arguments).joined(separator: " ")
    }

    // MARK: - Read-only

    public static let listDevices = SimctlCommand(["list", "devices", "--json"])
    public static let listRuntimes = SimctlCommand(["list", "runtimes", "--json"])
    public static let listPairs = SimctlCommand(["list", "pairs", "--json"])

    /// Distinct from ``listRuntimes``: this is the runtime *image* management
    /// command, and the only source of deletion UUIDs and sizes.
    public static let runtimeList = SimctlCommand(["runtime", "list", "--json"])

    /// simctl's own dry run for runtime deletion — a real preview from the tool
    /// itself rather than a prediction this app invents.
    public static func runtimeDeleteDryRun(notUsedSinceDays days: Int) -> SimctlCommand {
        SimctlCommand(["runtime", "delete", "--notUsedSinceDays", String(days), "--dry-run"])
    }

    // MARK: - Destructive

    public static func deleteDevice(id: UUID) -> SimctlCommand {
        SimctlCommand(["delete", id.uuidString], isDestructive: true)
    }

    /// Keeps the device, clears its data.
    public static func eraseDevice(id: UUID) -> SimctlCommand {
        SimctlCommand(["erase", id.uuidString], isDestructive: true)
    }

    public static func deleteRuntime(imageUUID: UUID) -> SimctlCommand {
        SimctlCommand(["runtime", "delete", imageUUID.uuidString], isDestructive: true)
    }

    public static let deleteUnavailableDevices = SimctlCommand(
        ["delete", "unavailable"], isDestructive: true
    )
}
