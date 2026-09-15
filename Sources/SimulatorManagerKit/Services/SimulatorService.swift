import Foundation

/// Everything the app knows about simulator state at one moment.
public struct SimulatorInventory: Sendable {
    public let devices: [SimulatorDevice]
    public let runtimes: [SimulatorRuntime]
    public let pairs: [DevicePair]
    /// Entries simctl reported that could not be read. Surfaced rather than
    /// swallowed, so the UI never implies it has seen everything when it has not.
    public let issues: [ParseIssue]
    public let capturedAt: Date

    public init(
        devices: [SimulatorDevice],
        runtimes: [SimulatorRuntime],
        pairs: [DevicePair] = [],
        issues: [ParseIssue] = [],
        capturedAt: Date = Date()
    ) {
        self.devices = devices
        self.runtimes = runtimes
        self.pairs = pairs
        self.issues = issues
        self.capturedAt = capturedAt
    }

    /// Runtime identifiers that are actually installed, which is what makes a
    /// device's runtime reference resolvable or not.
    public var installedRuntimeIdentifiers: Set<String> {
        Set(runtimes.filter(\.isAvailable).map(\.id))
    }

    public func devices(forRuntime runtimeIdentifier: String) -> [SimulatorDevice] {
        devices.filter { $0.runtimeIdentifier == runtimeIdentifier }
    }

    /// The pairing a device belongs to, if any. Deleting either half breaks it,
    /// and nothing in the device's own listing reveals the relationship.
    public func pair(containing deviceID: UUID) -> DevicePair? {
        pairs.first { $0.contains(deviceID: deviceID) }
    }
}

/// Reads and mutates simulator state. All mutation goes through `simctl`;
/// nothing in this package deletes simulator data by any other means.
public protocol SimulatorService: Sendable {
    func listDevices() async throws -> [SimulatorDevice]
    func listRuntimes() async throws -> [SimulatorRuntime]
    func listPairs() async throws -> [DevicePair]
    /// Loads devices, runtimes and pairs together, which is what any screen
    /// showing recommendations actually needs.
    func loadInventory() async throws -> SimulatorInventory

    func deleteDevice(id: UUID) async throws
    func eraseDevice(id: UUID) async throws
    func deleteRuntime(imageUUID: UUID) async throws
    func deleteUnavailableDevices() async throws
}
