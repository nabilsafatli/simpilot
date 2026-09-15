import Foundation
import Testing
@testable import SimulatorManagerKit

@Suite("SimulatorService against recorded simctl output")
struct SimulatorServiceTests {

    private func makeService(
        devices: String = "devices",
        runtimes: String = "runtimes",
        runtimeImages: String = "runtime-list",
        pairs: String = "empty-pairs"
    ) throws -> (SimctlSimulatorService, FakeCommandRunner) {
        let runner = try FakeCommandRunner(fixtures: [
            .listDevices: devices,
            .listRuntimes: runtimes,
            .runtimeList: runtimeImages,
            .listPairs: pairs
        ])
        return (SimctlSimulatorService(runner: runner), runner)
    }

    @Test("Loads a complete inventory in one pass")
    func loadsInventory() async throws {
        let (service, _) = try makeService()
        let inventory = try await service.loadInventory()

        #expect(inventory.devices.count == 11)
        #expect(inventory.runtimes.count == 1)
        #expect(inventory.pairs.isEmpty)
        #expect(inventory.issues.isEmpty)
    }

    @Test("Reading the inventory issues no destructive command")
    func readingIsNeverDestructive() async throws {
        let (service, runner) = try makeService()
        _ = try await service.loadInventory()

        let destructive = await runner.destructiveCommands
        #expect(destructive.isEmpty)
    }

    @Test("Resolves which devices are stranded by a missing runtime")
    func correlatesDevicesToInstalledRuntimes() async throws {
        let (service, _) = try makeService(
            devices: "unavailable-runtime",
            runtimes: "multi-platform-runtimes",
            runtimeImages: "multi-runtime-list"
        )
        let inventory = try await service.loadInventory()

        let installed = inventory.installedRuntimeIdentifiers
        #expect(installed.contains("com.apple.CoreSimulator.SimRuntime.iOS-26-5"))
        #expect(!installed.contains("com.apple.CoreSimulator.SimRuntime.iOS-17-0"))

        let stranded = inventory.devices.filter { !installed.contains($0.runtimeIdentifier) }
        #expect(stranded.count == 3)
    }

    @Test("Finds the pairing a device belongs to")
    func findsPairMembership() async throws {
        let (service, _) = try makeService(devices: "duplicate-devices", pairs: "pairs")
        let inventory = try await service.loadInventory()

        let phoneID = try #require(UUID(uuidString: "C1111111-1111-4111-8111-111111111111"))
        let pair = try #require(inventory.pair(containing: phoneID))
        #expect(pair.counterpart(of: phoneID)?.name == "Apple Watch Series 10 (46mm)")

        let unpaired = try #require(UUID(uuidString: "C2222222-2222-4222-8222-222222222222"))
        #expect(inventory.pair(containing: unpaired) == nil)
    }

    // MARK: - Destructive commands, proven without deleting anything

    @Test("deleteDevice issues exactly `simctl delete <UUID>`")
    func deleteDeviceIssuesExactCommand() async throws {
        let (service, runner) = try makeService()
        let target = try #require(UUID(uuidString: "32D5B2B1-B8FF-4846-840D-E49B15F4141F"))

        try await service.deleteDevice(id: target)

        let commands = await runner.executedCommands
        #expect(commands.count == 1)
        #expect(commands.first?.displayString
                == "xcrun simctl delete 32D5B2B1-B8FF-4846-840D-E49B15F4141F")
    }

    @Test("eraseDevice erases rather than deletes")
    func eraseUsesEraseNotDelete() async throws {
        let (service, runner) = try makeService()
        let target = try #require(UUID(uuidString: "32D5B2B1-B8FF-4846-840D-E49B15F4141F"))

        try await service.eraseDevice(id: target)

        let command = try #require(await runner.executedCommands.first)
        #expect(command.arguments.first == "erase")
        #expect(!command.arguments.contains("delete"))
    }

    @Test("Runtime deletion targets the image UUID, not the runtime identifier")
    func runtimeDeletionUsesImageUUID() async throws {
        let (service, runner) = try makeService()
        let imageUUID = try #require(UUID(uuidString: "39BDD188-94B4-4FB2-B91F-59208B8597FE"))

        try await service.deleteRuntime(imageUUID: imageUUID)

        let command = try #require(await runner.executedCommands.first)
        #expect(command.displayString
                == "xcrun simctl runtime delete 39BDD188-94B4-4FB2-B91F-59208B8597FE")
    }

    @Test("A failing destructive command surfaces the command and exit code")
    func surfacesFailureDetail() async throws {
        let (service, runner) = try makeService()
        let target = UUID()
        await runner.stubFailure(.deleteDevice(id: target), exitCode: 164,
                                     message: "Unable to delete device.")

        var caught: SimctlError?
        do {
            try await service.deleteDevice(id: target)
        } catch let error as SimctlError {
            caught = error
        }

        let error = try #require(caught)
        guard case .commandFailed(let command, let exitCode, let message) = error else {
            Issue.record("Expected commandFailed, got \(error)")
            return
        }
        #expect(exitCode == 164)
        #expect(message == "Unable to delete device.")
        // The failing command is quotable back to the user verbatim.
        #expect(command.displayString.hasPrefix("xcrun simctl delete "))
        #expect(error.errorDescription?.contains("exit code 164") == true)
    }

    @Test("A missing runtime-image command costs sizes, not the inventory")
    func toleratesMissingRuntimeImageCommand() async throws {
        let runner = try FakeCommandRunner(fixtures: [
            .listDevices: "devices",
            .listRuntimes: "runtimes",
            .listPairs: "empty-pairs"
        ])
        await runner.stubFailure(.runtimeList, exitCode: 1, message: "Unknown subcommand")
        let service = SimctlSimulatorService(runner: runner)

        let inventory = try await service.loadInventory()
        #expect(inventory.devices.count == 11)
        #expect(inventory.runtimes.count == 1)
        #expect(inventory.runtimes.allSatisfy { !$0.isDeletable })
    }

    @Test("A toolchain without simctl is reported, not mistaken for an empty Mac")
    func detectsMissingToolchain() async throws {
        let runner = try FakeCommandRunner()
        await runner.stubFailure(.listRuntimes, exitCode: 72,
                                     message: "xcrun: error: unable to find utility \"simctl\"")

        let status = await ToolchainProbe(runner: runner).probe()
        #expect(status.isReady == false)
        guard case .unavailable(let reason) = status else {
            Issue.record("Expected unavailable")
            return
        }
        #expect(reason.contains("simctl"))
    }

    @Test("A working toolchain reports ready")
    func detectsWorkingToolchain() async throws {
        let runner = try FakeCommandRunner(fixtures: [.listRuntimes: "runtimes"])
        let status = await ToolchainProbe(runner: runner).probe()
        #expect(status.isReady)
    }
}
