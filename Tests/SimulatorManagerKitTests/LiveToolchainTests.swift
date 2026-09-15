import Foundation
import Testing
@testable import SimulatorManagerKit

/// Read-only checks against whatever simulator state this machine actually has.
///
/// Disabled unless `SIMPILOT_LIVE_TESTS=1`, because correctness must never depend
/// on the developer's own simulator state — the fixture suite is the source of
/// truth. These exist to catch the one thing fixtures cannot: a future Xcode
/// changing simctl's output shape out from under the parser.
///
/// Nothing here mutates anything. There is no live test of deletion, and there
/// should never be one against the real device set.
@Suite(
    "Live toolchain (opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["SIMPILOT_LIVE_TESTS"] == "1")
)
struct LiveToolchainTests {

    @Test("The real simctl output still parses")
    func realOutputParses() async throws {
        let service = SimctlSimulatorService(runner: ProcessCommandRunner())
        let inventory = try await service.loadInventory()

        #expect(inventory.issues.isEmpty, "simctl emitted entries the parser could not read")
        #expect(!inventory.runtimes.isEmpty, "a machine with Xcode should report a runtime")

        for device in inventory.devices {
            #expect(!device.name.isEmpty)
            #expect(!device.runtimeIdentifier.isEmpty)
        }
    }

    @Test("The runtime join still finds sizes and UUIDs on a real machine")
    func realRuntimeJoinWorks() async throws {
        let service = SimctlSimulatorService(runner: ProcessCommandRunner())
        let runtimes = try await service.listRuntimes()
        let deletable = runtimes.filter(\.isDeletable)

        for runtime in deletable {
            #expect(runtime.imageUUID != nil, "\(runtime.name) is deletable but has no image UUID")
            #expect((runtime.sizeBytes ?? 0) > 0)
        }
    }

    @Test("A real scan completes and measures more than simctl's cached figure")
    func realScanMeasuresDevices() async throws {
        let service = SimctlSimulatorService(runner: ProcessCommandRunner())
        let inventory = try await service.loadInventory()
        let report = try await FileSystemStorageScanner().scan(inventory: inventory)

        #expect(report.devices.count == inventory.devices.count)

        // Phase 0 measured simctl's dataPathSize 9-12% low on booted devices. If
        // this ever stops holding, the scanner may no longer be earning its keep.
        let drifted = report.devices.filter {
            guard let reported = $0.reportedBytes, reported > 0 else { return false }
            return $0.totalBytes > reported
        }
        #expect(!drifted.isEmpty || report.devices.allSatisfy { $0.totalBytes == 0 })
    }

    @Test("The engine produces coherent advice about this actual machine")
    func realRecommendationsAreCoherent() async throws {
        let service = SimctlSimulatorService(runner: ProcessCommandRunner())
        let inventory = try await service.loadInventory()
        let report = try await FileSystemStorageScanner().scan(inventory: inventory)
        let result = RecommendationEngine().evaluate(inventory: inventory, report: report)

        for recommendation in result.recommendations {
            #expect(!recommendation.reasons.isEmpty)
            #expect((0...1).contains(recommendation.confidence))

            // Targets must exist in the inventory this advice was derived from.
            for id in recommendation.target.deviceIDs {
                #expect(inventory.devices.contains { $0.id == id })
            }
            if case .runtime(let identifier) = recommendation.target {
                #expect(inventory.runtimes.contains { $0.id == identifier })
                #expect(recommendation.action == .reviewRuntime)
            }
            // A high-confidence finding on a real machine must rest on observation.
            if recommendation.level == .high {
                #expect(recommendation.hasOnlyObservedEvidence)
            }
        }

        #expect(result.actionableRecoverableBytes >= 0)
    }
}
