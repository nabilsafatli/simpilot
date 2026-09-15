import Foundation

/// `SimulatorService` backed by the real `simctl`.
public struct SimctlSimulatorService: SimulatorService {
    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    public init() {
        self.runner = ProcessCommandRunner()
    }

    // MARK: - Reading

    public func listDevices() async throws -> [SimulatorDevice] {
        try await parsedDevices().items
    }

    public func listRuntimes() async throws -> [SimulatorRuntime] {
        let listed = try await output(of: .listRuntimes)
        // `simctl runtime list` is absent on older Xcode versions and can fail
        // independently. Losing it costs sizes and deletability, not the
        // inventory itself, so its failure is tolerated rather than propagated.
        let images = try? await output(of: .runtimeList)
        do {
            return try SimctlParser.parseRuntimes(runtimesData: listed, runtimeImagesData: images)
        } catch {
            throw SimctlError.invalidOutput(command: .listRuntimes, underlying: "\(error)")
        }
    }

    public func listPairs() async throws -> [DevicePair] {
        try await parsedPairs().items
    }

    public func loadInventory() async throws -> SimulatorInventory {
        // These three reads are independent, so run them concurrently: on a
        // machine with many devices the listing dominates refresh time.
        async let devices = parsedDevices()
        async let runtimes = listRuntimes()
        async let pairs = parsedPairs()

        let (deviceOutcome, runtimeList, pairOutcome) = try await (devices, runtimes, pairs)

        return SimulatorInventory(
            devices: deviceOutcome.items,
            runtimes: runtimeList,
            pairs: pairOutcome.items,
            issues: deviceOutcome.issues + pairOutcome.issues
        )
    }

    // MARK: - Mutating
    //
    // Every method here is destructive and none performs its own confirmation.
    // Confirmation is the caller's responsibility, on a screen that names the
    // exact target; this layer exists to be the single audited place where
    // simctl is asked to remove something.

    public func deleteDevice(id: UUID) async throws {
        _ = try await output(of: .deleteDevice(id: id))
    }

    public func eraseDevice(id: UUID) async throws {
        _ = try await output(of: .eraseDevice(id: id))
    }

    public func deleteRuntime(imageUUID: UUID) async throws {
        _ = try await output(of: .deleteRuntime(imageUUID: imageUUID))
    }

    public func deleteUnavailableDevices() async throws {
        _ = try await output(of: .deleteUnavailableDevices)
    }

    // MARK: - Plumbing

    private func parsedDevices() async throws -> ParseOutcome<SimulatorDevice> {
        let data = try await output(of: .listDevices)
        do {
            return try SimctlParser.parseDevices(data)
        } catch {
            throw SimctlError.invalidOutput(command: .listDevices, underlying: "\(error)")
        }
    }

    private func parsedPairs() async throws -> ParseOutcome<DevicePair> {
        let data = try await output(of: .listPairs)
        do {
            return try SimctlParser.parsePairs(data)
        } catch {
            throw SimctlError.invalidOutput(command: .listPairs, underlying: "\(error)")
        }
    }

    private func output(of command: SimctlCommand) async throws -> Data {
        let result = try await runner.run(command)
        guard result.isSuccess else {
            throw SimctlError.commandFailed(
                command: command,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return result.standardOutput
    }
}
