import Foundation
import Testing
@testable import SimulatorManagerKit

@Suite("Cleanup plan construction")
struct CleanupPlanTests {

    private func fixtureContext(
        _ devicesFixture: String,
        runtimes: String = "redundant-runtimes",
        runtimeImages: String = "redundant-runtime-list",
        pairs: String? = nil
    ) throws -> (SimulatorInventory, SimulatorStorageReport, [Recommendation]) {
        let (inv, storage) = try inventory(
            devicesFixture: devicesFixture,
            runtimesFixture: runtimes,
            runtimeImagesFixture: runtimeImages,
            pairsFixture: pairs
        )
        let result = RecommendationEngine().evaluate(inventory: inv, report: storage, now: referenceNow)
        return (inv, storage, result.recommendations)
    }

    /// The central guarantee of Phase 4: a review can never turn into an action.
    @Test("Review recommendations never become operations")
    func reviewsAreNotExecutable() throws {
        let (inv, storage, recommendations) = try fixtureContext("duplicate-devices")
        let reviews = recommendations.filter { !$0.action.isDestructive }
        #expect(!reviews.isEmpty, "this fixture should produce reviews")

        let plan = CleanupPlan.build(from: reviews, inventory: inv, report: storage)
        #expect(plan.isEmpty, "no review may produce an executable operation")
        #expect(plan.estimatedRecoverableBytes == 0)
    }

    /// Even when handed every recommendation, only the destructive ones survive.
    @Test("Building from everything yields only destructive operations")
    func filtersToDestructiveActionsOnly() throws {
        let (inv, storage, recommendations) = try fixtureContext("unavailable-runtime")
        let plan = CleanupPlan.build(from: recommendations, inventory: inv, report: storage)

        #expect(!plan.isEmpty)
        #expect(plan.operations.count <= recommendations.count)
        for operation in plan.operations {
            #expect(operation.action.deviceID != nil || operation.action.command.isDestructive)
        }
    }

    @Test("A runtime simctl will not delete never reaches a plan")
    func undeletableRuntimeIsExcluded() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: Fixture.data("multi-runtime-list")
        )
        let inv = SimulatorInventory(devices: [], runtimes: runtimes)

        // A hand-made recommendation targeting an undeletable runtime, as though
        // a future rule proposed one.
        let undeletable = try #require(runtimes.first { !$0.isDeletable })
        let recommendation = Recommendation(
            target: .runtime(undeletable.id),
            action: .deleteRuntime,
            reasons: [.init(kind: .obsoleteRuntime, summary: "test", isObservedFact: true)],
            confidence: 0.9
        )

        let plan = CleanupPlan.build(from: [recommendation], inventory: inv, report: nil)
        #expect(plan.isEmpty, "simctl's deletable flag is final")
    }

    @Test("A device is never acted on twice in one plan")
    func doesNotActTwiceOnSameDevice() throws {
        let (inv, storage, _) = try fixtureContext("devices")
        let device = try #require(inv.devices.first)

        let duplicated = [
            Recommendation(target: .device(device.id), action: .deleteDevice,
                           reasons: [.init(kind: .neverUsed, summary: "a", isObservedFact: true)],
                           confidence: 0.5),
            Recommendation(target: .device(device.id), action: .eraseDevice,
                           reasons: [.init(kind: .neverUsed, summary: "b", isObservedFact: true)],
                           confidence: 0.5)
        ]
        let plan = CleanupPlan.build(from: duplicated, inventory: inv, report: storage)
        #expect(plan.operations.count == 1)
    }

    @Test("A recommendation for a device that no longer exists is dropped")
    func dropsStaleTargets() throws {
        let (inv, storage, _) = try fixtureContext("devices")
        let ghost = Recommendation(
            target: .device(UUID()), action: .deleteDevice,
            reasons: [.init(kind: .neverUsed, summary: "gone", isObservedFact: true)],
            confidence: 0.5
        )
        #expect(CleanupPlan.build(from: [ghost], inventory: inv, report: storage).isEmpty)
    }

    @Test("Erasing estimates only the data above a fresh device's baseline")
    func eraseEstimatesDataAboveBaseline() throws {
        let (inv, storage, _) = try fixtureContext("devices")
        let used = try #require(inv.devices.first { $0.name == "iPhone 17" })

        let recommendation = Recommendation(
            target: .device(used.id), action: .eraseDevice,
            reasons: [.init(kind: .stale, summary: "test", isObservedFact: true)],
            confidence: 0.5, recoverableBytes: 999
        )
        let plan = CleanupPlan.build(from: [recommendation], inventory: inv, report: storage)
        let operation = try #require(plan.operations.first)

        let total = try #require(storage.storage(forDevice: used.id)?.totalBytes)
        #expect(operation.estimatedBytes == total - 18_337_792)
        #expect(operation.estimatedBytes < total, "erasing does not free the whole device")
    }

    @Test("Cautions from the recommendation travel with the operation")
    func carriesCautionsForward() throws {
        let (inv, storage, recommendations) = try fixtureContext("duplicate-devices", pairs: "pairs")
        let paired = try #require(UUID(uuidString: "C1111111-1111-4111-8111-111111111111"))

        let recommendation = Recommendation(
            target: .device(paired), action: .deleteDevice,
            reasons: [.init(kind: .neverUsed, summary: "t", isObservedFact: true)],
            cautions: recommendations.flatMap(\.cautions).filter { $0.kind == .breaksPairing },
            confidence: 0.5
        )
        let plan = CleanupPlan.build(from: [recommendation], inventory: inv, report: storage)
        #expect(plan.cautions.contains { $0.kind == .breaksPairing })
    }
}

@Suite("Cleanup impact statements")
struct CleanupImpactTests {

    private func inventoryWithPair() throws -> (SimulatorInventory, SimulatorStorageReport) {
        try inventory(
            devicesFixture: "duplicate-devices",
            runtimesFixture: "runtimes",
            runtimeImagesFixture: "runtime-list",
            pairsFixture: "pairs"
        )
    }

    @Test("Deleting a device promises the runtime survives")
    func deleteDeviceKeepsRuntime() throws {
        let (inv, report) = try inventoryWithPair()
        let device = try #require(inv.devices.first)
        let impact = CleanupImpact.forAction(
            .deleteDevice(id: device.id, name: device.name), inventory: inv, report: report
        )

        #expect(impact.willRemove.contains { $0.summary.contains(device.name) })
        #expect(impact.willKeep.contains { $0.summary.localizedCaseInsensitiveContains("runtime") })
        #expect(impact.willKeep.contains { $0.summary.localizedCaseInsensitiveContains("source code") })
        #expect(impact.willKeep.contains { $0.summary.localizedCaseInsensitiveContains("DerivedData") })
    }

    /// Phase 0 found 22 orphaned log folders. The impact statement says so rather
    /// than letting the user discover it as a surprise later.
    @Test("Deleting a device discloses that its logs are left behind")
    func deleteDeviceDisclosesOrphanedLogs() throws {
        let (inv, _) = try inventoryWithPair()
        let device = try #require(inv.devices.first)
        let report = SimulatorStorageReport(devices: [
            .init(id: device.id, totalBytes: 1_000_000, logBytes: 500_000)
        ])

        let impact = CleanupImpact.forAction(
            .deleteDevice(id: device.id, name: device.name), inventory: inv, report: report
        )
        let logs = try #require(impact.willKeep.first { $0.summary.localizedCaseInsensitiveContains("log folder") })
        #expect(logs.detail?.contains("orphaned") == true)
    }

    @Test("Deleting a paired device says what the pairing loses")
    func deletePairedDeviceExplainsBreakage() throws {
        let (inv, report) = try inventoryWithPair()
        let paired = try #require(UUID(uuidString: "C1111111-1111-4111-8111-111111111111"))
        let device = try #require(inv.devices.first { $0.id == paired })

        let impact = CleanupImpact.forAction(
            .deleteDevice(id: paired, name: device.name), inventory: inv, report: report
        )
        #expect(impact.willRemove.contains { $0.summary.localizedCaseInsensitiveContains("pairing") })
        #expect(impact.willKeep.contains { $0.summary.contains("Apple Watch Series 10 (46mm)") })
    }

    @Test("Erasing promises the device itself survives")
    func eraseKeepsTheDevice() throws {
        let (inv, report) = try inventoryWithPair()
        let device = try #require(inv.devices.first)
        let impact = CleanupImpact.forAction(
            .eraseDevice(id: device.id, name: device.name), inventory: inv, report: report
        )

        #expect(impact.willKeep.contains { $0.summary.contains(device.name) })
        #expect(impact.willKeep.contains { $0.detail?.contains(device.id.uuidString) == true })
        #expect(impact.willRemove.contains { $0.summary.localizedCaseInsensitiveContains("apps and data") })
        // Erasing must never claim to remove the simulator.
        #expect(!impact.willRemove.contains { $0.summary.hasPrefix("The simulator") })
    }

    /// Deleting a runtime does not delete its devices — it strands them. Saying
    /// "will delete these devices" would be wrong in a way that matters.
    @Test("Deleting a runtime says dependent devices survive but stop working")
    func deleteRuntimeStrandsRatherThanDeletes() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("redundant-runtimes"),
            runtimeImagesData: Fixture.data("redundant-runtime-list")
        )
        let runtime = try #require(runtimes.first { $0.version == "17.5" })
        let dependent = SimulatorDevice(
            id: UUID(), name: "iPhone 15 Pro", runtimeIdentifier: runtime.id,
            state: .shutdown, deviceTypeIdentifier: "t", isAvailable: true,
            dataPath: URL(fileURLWithPath: "/tmp"), logPath: URL(fileURLWithPath: "/tmp")
        )
        let inv = SimulatorInventory(devices: [dependent], runtimes: runtimes)
        let imageUUID = try #require(runtime.imageUUID)

        let impact = CleanupImpact.forAction(
            .deleteRuntime(imageUUID: imageUUID, name: runtime.name), inventory: inv, report: nil
        )

        let kept = try #require(impact.willKeep.first { $0.summary.contains("device") })
        #expect(kept.detail?.contains("NOT deleted") == true)
        #expect(kept.detail?.contains("iPhone 15 Pro") == true)
        #expect(impact.willKeep.contains { $0.summary.localizedCaseInsensitiveContains("Xcode") })
    }

    @Test("Every impact statement names something that survives")
    func everyImpactNamesSurvivors() throws {
        let (inv, report) = try inventoryWithPair()
        let device = try #require(inv.devices.first)
        let actions: [CleanupAction] = [
            .deleteDevice(id: device.id, name: device.name),
            .eraseDevice(id: device.id, name: device.name),
            .deleteUnavailableDevices(count: 2)
        ]

        for action in actions {
            let impact = CleanupImpact.forAction(action, inventory: inv, report: report)
            #expect(!impact.willRemove.isEmpty, "\(action.verb)")
            #expect(!impact.willKeep.isEmpty, "\(action.verb) must say what it leaves alone")
            #expect(impact.willKeep.contains { $0.summary.localizedCaseInsensitiveContains("source code") }
                    || impact.willKeep.contains { $0.summary.localizedCaseInsensitiveContains("Xcode") })
        }
    }
}

@Suite("Cleanup execution")
struct CleanupExecutorTests {

    private func plan(_ actions: [CleanupAction]) -> CleanupPlan {
        CleanupPlan(operations: actions.map {
            CleanupOperation(
                action: $0,
                impact: CleanupImpact(willRemove: [], willKeep: []),
                estimatedBytes: 1000
            )
        })
    }

    @Test("Issues exactly the expected commands, in order")
    func issuesExpectedCommands() async throws {
        let runner = try FakeCommandRunner()
        let service = SimctlSimulatorService(runner: runner)
        let deviceA = UUID(), deviceB = UUID(), image = UUID()

        let outcome = await CleanupExecutor(service: service).execute(plan([
            .deleteDevice(id: deviceA, name: "A"),
            .eraseDevice(id: deviceB, name: "B"),
            .deleteRuntime(imageUUID: image, name: "R")
        ]))

        #expect(outcome.didCompleteFully)
        #expect(outcome.succeeded.count == 3)

        let issued = await runner.executedCommands.map(\.displayString)
        #expect(issued == [
            "xcrun simctl delete \(deviceA.uuidString)",
            "xcrun simctl erase \(deviceB.uuidString)",
            "xcrun simctl runtime delete \(image.uuidString)"
        ])
    }

    /// The brief's rule: on failure, stop. Do not retry, do not continue.
    @Test("Stops at the first failure and attempts nothing after it")
    func stopsAtFirstFailure() async throws {
        let runner = try FakeCommandRunner()
        let failing = UUID(), afterA = UUID(), afterB = UUID()
        await runner.stubFailure(.deleteDevice(id: failing), exitCode: 164, message: "Device is booted.")

        let outcome = await CleanupExecutor(service: SimctlSimulatorService(runner: runner)).execute(plan([
            .eraseDevice(id: afterA, name: "ran first"),
            .deleteDevice(id: failing, name: "fails"),
            .deleteDevice(id: afterB, name: "never attempted")
        ]))

        #expect(outcome.succeeded.count == 1)
        #expect(outcome.failure?.operation.action.targetName == "fails")
        #expect(outcome.failure?.message.contains("Device is booted.") == true)
        #expect(outcome.notAttempted.count == 1)
        #expect(outcome.notAttempted.first?.action.targetName == "never attempted")
        #expect(!outcome.didCompleteFully)

        // The command after the failure was never sent, and the failing one was
        // sent exactly once — no automatic retry.
        let issued = await runner.executedCommands
        #expect(issued.count == 2)
        #expect(!issued.contains { $0.displayString.contains(afterB.uuidString) })
        #expect(issued.filter { $0.displayString.contains(failing.uuidString) }.count == 1)
    }

    @Test("An empty plan runs nothing")
    func emptyPlanRunsNothing() async throws {
        let runner = try FakeCommandRunner()
        let outcome = await CleanupExecutor(service: SimctlSimulatorService(runner: runner))
            .execute(CleanupPlan(operations: []))

        #expect(outcome.didCompleteFully)
        #expect(await runner.executedCommands.isEmpty)
    }

    @Test("Building a plan executes nothing by itself")
    func buildingAPlanIsInert() async throws {
        let runner = try FakeCommandRunner(fixtures: [
            .listDevices: "unavailable-runtime", .listRuntimes: "runtimes",
            .runtimeList: "runtime-list", .listPairs: "empty-pairs"
        ])
        let service = SimctlSimulatorService(runner: runner)
        let inv = try await service.loadInventory()
        let result = RecommendationEngine().evaluate(inventory: inv, report: nil, now: referenceNow)

        _ = CleanupPlan.build(from: result.recommendations, inventory: inv, report: nil)

        let destructive = await runner.destructiveCommands
        #expect(destructive.isEmpty, "previewing must never mutate anything")
    }

    @Test("Reports progress for each operation before running it")
    func reportsProgress() async throws {
        let runner = try FakeCommandRunner()
        let recorder = NameRecorder()
        _ = await CleanupExecutor(service: SimctlSimulatorService(runner: runner)).execute(
            plan([.deleteDevice(id: UUID(), name: "first"), .eraseDevice(id: UUID(), name: "second")]),
            progress: { recorder.record($0.action.targetName) }
        )
        #expect(recorder.names == ["first", "second"])
    }
}

final class NameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ name: String) { lock.lock(); storage.append(name); lock.unlock() }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
