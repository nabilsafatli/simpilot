import Foundation
import Testing
@testable import SimulatorManagerKit

/// Exercises the destructive paths against a **real** simctl and a **throwaway**
/// device set.
///
/// Phase 0 established that `simctl --set <path>` operates on a completely
/// separate device set: a device was created and deleted in one while the
/// machine's real devices were verifiably untouched. That is what makes it
/// responsible to test deletion for real rather than only against a fake.
///
/// Opt-in via `SIMPILOT_LIVE_TESTS=1`, requires Xcode, and every device involved
/// is one this test created moments earlier in a temporary directory. Nothing
/// here can reach the user's own simulators.
@Suite(
    "Destructive operations against an isolated device set (opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["SIMPILOT_LIVE_TESTS"] == "1"),
    .serialized
)
struct IsolatedDeviceSetTests {

    /// A temporary device set, plus the service that talks to it.
    private struct Sandbox {
        let path: String
        let service: SimctlSimulatorService

        init() throws {
            path = NSTemporaryDirectory() + "simpilot-set-\(UUID().uuidString)"
            // simctl requires the directory to exist already.
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true
            )
            service = SimctlSimulatorService(
                runner: ProcessCommandRunner(deviceSetPath: path)
            )
        }

        func createDevice(named name: String) async throws -> UUID {
            let runtime = try await firstRuntimeIdentifier()
            let deviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "--set", path, "create", name, deviceType, runtime]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return try #require(UUID(uuidString: output), "create failed: \(output)")
        }

        private func firstRuntimeIdentifier() async throws -> String {
            let runtimes = try await SimctlSimulatorService(runner: ProcessCommandRunner())
                .listRuntimes()
            return try #require(runtimes.first { $0.isAvailable && $0.platform == .iOS }?.id)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @Test("Deleting through a plan really removes the device")
    func deleteActuallyDeletes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }

        let id = try await sandbox.createDevice(named: "Simpilot Delete Target")
        var inventory = try await sandbox.service.loadInventory()
        #expect(inventory.devices.contains { $0.id == id })

        let recommendation = Recommendation(
            target: .device(id), action: .deleteDevice,
            reasons: [.init(kind: .neverUsed, summary: "created by this test", isObservedFact: true)],
            confidence: 0.5
        )
        let plan = CleanupPlan.build(from: [recommendation], inventory: inventory, report: nil)
        #expect(plan.operations.count == 1)

        let outcome = await CleanupExecutor(service: sandbox.service).execute(plan)
        #expect(outcome.didCompleteFully)
        #expect(outcome.failure == nil)

        inventory = try await sandbox.service.loadInventory()
        #expect(!inventory.devices.contains { $0.id == id }, "the device should be gone")
    }

    /// The distinction the impact statement promises: erase keeps the device.
    @Test("Erasing keeps the device and its identifier")
    func eraseKeepsTheDevice() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }

        let id = try await sandbox.createDevice(named: "Simpilot Erase Target")
        try await sandbox.service.eraseDevice(id: id)

        let inventory = try await sandbox.service.loadInventory()
        let device = try #require(inventory.devices.first { $0.id == id })
        #expect(device.name == "Simpilot Erase Target", "erase must not rename or replace it")
    }

    /// The brief's rule, verified against real simctl failures rather than a stub.
    @Test("A failing operation stops the plan and leaves later targets alone")
    func failureStopsExecution() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }

        let survivor = try await sandbox.createDevice(named: "Simpilot Survivor")
        let inventory = try await sandbox.service.loadInventory()

        // A plan whose middle operation targets a device that does not exist.
        let plan = CleanupPlan(operations: [
            CleanupOperation(
                action: .deleteDevice(id: UUID(), name: "does not exist"),
                impact: CleanupImpact(willRemove: [], willKeep: []), estimatedBytes: 0
            ),
            CleanupOperation(
                action: .deleteDevice(id: survivor, name: "Simpilot Survivor"),
                impact: CleanupImpact(willRemove: [], willKeep: []), estimatedBytes: 0
            )
        ])

        let outcome = await CleanupExecutor(service: sandbox.service).execute(plan)

        #expect(outcome.failure != nil, "deleting a nonexistent device should fail")
        #expect(outcome.succeeded.isEmpty)
        #expect(outcome.notAttempted.count == 1)

        // The critical assertion: execution stopped, so the survivor is still here.
        let after = try await sandbox.service.loadInventory()
        #expect(after.devices.contains { $0.id == survivor },
                "the operation after a failure must not have run")
        #expect(inventory.devices.count == after.devices.count)
    }

    /// Belt and braces: confirm the real device set was never touched.
    @Test("The machine's real device set is unaffected")
    func realDeviceSetUntouched() async throws {
        let realService = SimctlSimulatorService(runner: ProcessCommandRunner())
        let before = try await realService.loadInventory().devices.map(\.id).sorted { $0.uuidString < $1.uuidString }

        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let id = try await sandbox.createDevice(named: "Simpilot Isolation Check")
        try await sandbox.service.deleteDevice(id: id)

        let after = try await realService.loadInventory().devices.map(\.id).sorted { $0.uuidString < $1.uuidString }
        #expect(before == after, "operations on an isolated set must not affect the real one")
    }
}
