import Foundation
import Testing
@testable import SimulatorManagerKit

/// A fixed clock, so staleness assertions do not change meaning as time passes.
let referenceNow = try! Date.ISO8601FormatStyle().parse("2026-09-13T12:00:00Z")

extension RecommendationReport {
    func forGroup(containing id: UUID) -> Recommendation? {
        recommendations.first { $0.target.deviceIDs.contains(id) && $0.action == .reviewDuplicates }
    }
}

/// Builds an inventory from fixtures with measured sizes standing in for a scan.
func inventory(
    devicesFixture: String,
    runtimesFixture: String? = nil,
    runtimeImagesFixture: String? = nil,
    pairsFixture: String? = nil
) throws -> (SimulatorInventory, SimulatorStorageReport) {
    let devices = try SimctlParser.parseDevices(Fixture.data(devicesFixture)).items
    let runtimes = try runtimesFixture.map {
        try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data($0),
            runtimeImagesData: try runtimeImagesFixture.map { try Fixture.data($0) }
        )
    } ?? []
    let pairs = try pairsFixture.map { try SimctlParser.parsePairs(Fixture.data($0)).items } ?? []

    let report = SimulatorStorageReport(devices: devices.map {
        .init(id: $0.id, totalBytes: $0.reportedDataPathSize ?? 0, logBytes: 0,
              reportedBytes: $0.reportedDataPathSize)
    })
    return (SimulatorInventory(devices: devices, runtimes: runtimes, pairs: pairs), report)
}

// MARK: - The three cases named in the brief

@Suite("Recommendation engine — required cases")
struct RequiredRecommendationTests {

    /// Three identical iPhone 17 devices must produce a review, never a
    /// delete-them-all recommendation.
    @Test("Identical devices yield a duplicate review, not a deletion")
    func duplicatesProduceReviewNotDeletion() throws {
        let (inv, report) = try inventory(devicesFixture: "duplicate-devices")
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        let duplicate = try #require(result.recommendations.first { $0.action == .reviewDuplicates })
        #expect(duplicate.target.deviceIDs.count == 3)
        #expect(!duplicate.action.isDestructive)

        // Critically: no rule may propose deleting a device *because* it is a duplicate.
        let deletions = result.recommendations.filter { $0.action == .deleteDevice }
        for deletion in deletions {
            #expect(!deletion.reasons.contains { $0.kind == .duplicate },
                    "duplication must never justify a deletion")
        }

        // The group is never narrowed to a subset pre-marked for removal.
        let allIDs = Set(inv.devices.map(\.id))
        #expect(Set(duplicate.target.deviceIDs) == allIDs)

        // A keeper is suggested, and the suggestion is labelled as inference.
        let keeperReason = try #require(duplicate.reasons.first { $0.summary.contains("looks like the one in use") })
        #expect(keeperReason.isObservedFact == false)
    }

    /// A device on a missing runtime is the one case stateable as fact.
    @Test("A device on an uninstalled runtime is a high-confidence delete")
    func unavailableDeviceIsHighConfidence() throws {
        let (inv, report) = try inventory(devicesFixture: "unavailable-runtime")
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        let stranded = try #require(UUID(uuidString: "A1111111-1111-4111-8111-111111111111"))
        let recommendation = try #require(result.recommendation(forDevice: stranded))

        #expect(recommendation.action == .deleteDevice)
        #expect(recommendation.level == .high)
        #expect(recommendation.confidence >= 0.8)
        #expect(recommendation.reasons.contains { $0.kind == .unavailableRuntime })
        #expect(recommendation.hasOnlyObservedEvidence, "Rule A's evidence comes wholly from simctl")
        // The missing runtime is named, not merely called "unavailable".
        #expect(recommendation.reasons.contains { $0.summary.contains("iOS 17.0") })
    }

    /// One actively-used simulator and nothing else notable must yield nothing.
    /// This is the guard against rules that fire on everything.
    @Test("An ordinary, actively-used machine produces no recommendations")
    func quietMachineProducesNothing() throws {
        let (inv, report) = try inventory(
            devicesFixture: "active-only-devices",
            runtimesFixture: "runtimes",
            runtimeImagesFixture: "runtime-list"
        )
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        #expect(result.isEmpty, "produced: \(result.recommendations.map(\.action))")
        #expect(result.actionableRecoverableBytes == 0)
    }
}

// MARK: - Individual rules

@Suite("Rule A — unavailable devices")
struct UnavailableDeviceRuleTests {

    @Test("Flags every stranded device and nothing else")
    func flagsOnlyStrandedDevices() throws {
        let (inv, report) = try inventory(devicesFixture: "unavailable-runtime")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let results = UnavailableDeviceRule().evaluate(context)

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.action == .deleteDevice })
        #expect(results.allSatisfy { $0.confidence >= 0.9 })
    }

    @Test("Passes through simctl's own explanation as supporting detail")
    func includesSimctlExplanation() throws {
        let (inv, report) = try inventory(devicesFixture: "unavailable-runtime")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let result = try #require(UnavailableDeviceRule().evaluate(context).first)

        #expect(result.reasons.contains { $0.summary.contains("simctl's explanation") })
        #expect(result.reasons.allSatisfy { $0.isObservedFact })
    }

    @Test("Says nothing about a healthy machine")
    func silentOnHealthyMachine() throws {
        let (inv, report) = try inventory(devicesFixture: "devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        #expect(UnavailableDeviceRule().evaluate(context).isEmpty)
    }
}

@Suite("Rule B — unused devices")
struct UnusedDeviceRuleTests {

    @Test("Flags never-booted devices with medium confidence")
    func flagsNeverBooted() throws {
        let (inv, report) = try inventory(devicesFixture: "devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let results = UnusedDeviceRule().evaluate(context)

        #expect(results.count == 9)
        #expect(results.allSatisfy { $0.level == .medium })
        #expect(results.allSatisfy { $0.confidence < 0.8 })
    }

    /// The Phase 0 correction: the evidence is observed, the conclusion is not.
    @Test("States the absence of a boot record as fact, and hedges the conclusion")
    func separatesEvidenceFromInference() throws {
        let (inv, report) = try inventory(devicesFixture: "devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let result = try #require(UnusedDeviceRule().evaluate(context).first)
        let reason = try #require(result.reasons.first { $0.kind == .neverUsed })

        #expect(reason.isObservedFact, "simctl reporting no boot record is an observation")
        #expect(reason.summary.contains("no boot record"))
        // It must not claim the device is unwanted or safe to remove.
        #expect(!reason.summary.localizedCaseInsensitiveContains("safe"))
        #expect(!reason.summary.localizedCaseInsensitiveContains("unused"))
        #expect(reason.summary.contains("may still be wanted"))
    }

    @Test("Leaves recently-booted devices alone")
    func ignoresRecentlyBooted() throws {
        let (inv, report) = try inventory(devicesFixture: "devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let flagged = Set(UnusedDeviceRule().evaluate(context).flatMap(\.target.deviceIDs))

        for device in inv.devices where device.hasEverBooted {
            #expect(!flagged.contains(device.id), "\(device.name) was booted recently")
        }
    }

    @Test("Flags a device booted long ago as stale, dated from the injected clock")
    func flagsStaleDevices() throws {
        let (inv, report) = try inventory(devicesFixture: "devices")
        // A year after the fixture's boot timestamps.
        let later = referenceNow.addingTimeInterval(365 * 24 * 3600)
        let context = RecommendationContext(inventory: inv, report: report, now: later)
        let results = UnusedDeviceRule().evaluate(context)

        #expect(results.count == 11, "every device is now stale or never booted")
        #expect(results.contains { $0.reasons.contains { $0.kind == .stale } })
    }

    @Test("Defers to Rule A on unavailable devices")
    func defersToRuleA() throws {
        let (inv, report) = try inventory(devicesFixture: "unavailable-runtime")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let flagged = Set(UnusedDeviceRule().evaluate(context).flatMap(\.target.deviceIDs))

        for device in inv.devices where !device.isAvailable {
            #expect(!flagged.contains(device.id))
        }
    }
}

@Suite("Rule C — large and unused")
struct LargeUnusedDeviceRuleTests {

    @Test("Raises confidence above Rule B for a large unused device")
    func raisesConfidenceOverRuleB() throws {
        let (inv, report) = try inventory(devicesFixture: "large-unused-device")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)

        let large = try #require(LargeUnusedDeviceRule().evaluate(context).first)
        let unused = try #require(UnusedDeviceRule().evaluate(context).first)
        #expect(large.confidence > unused.confidence)
    }

    /// Size alone must never justify anything.
    @Test("Ignores a large device that is actively used")
    func ignoresLargeButUsedDevice() throws {
        let (inv, report) = try inventory(devicesFixture: "large-unused-device")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let flagged = Set(LargeUnusedDeviceRule().evaluate(context).flatMap(\.target.deviceIDs))

        let active = try #require(inv.devices.first { $0.name.contains("actively used") })
        #expect(!flagged.contains(active.id), "19 GB in daily use is not a finding")

        let neverBooted = try #require(inv.devices.first { $0.name.contains("large never booted") })
        #expect(flagged.contains(neverBooted.id))
    }

    @Test("Ignores a small unused device")
    func ignoresSmallUnusedDevice() throws {
        let (inv, report) = try inventory(devicesFixture: "large-unused-device")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let flagged = Set(LargeUnusedDeviceRule().evaluate(context).flatMap(\.target.deviceIDs))

        let small = try #require(inv.devices.first { $0.name.contains("small never booted") })
        #expect(!flagged.contains(small.id))
    }

    /// Without a scan there is no measured size, and the rule will not guess from
    /// simctl's cached figure.
    @Test("Does not fire when nothing has been measured")
    func requiresMeasuredSize() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("large-unused-device")).items
        let context = RecommendationContext(
            inventory: SimulatorInventory(devices: devices, runtimes: []),
            report: nil,
            now: referenceNow
        )
        #expect(LargeUnusedDeviceRule().evaluate(context).isEmpty)
    }
}

@Suite("Rule D — duplicates")
struct DuplicateDeviceRuleTests {

    @Test("Groups devices sharing a device type and runtime")
    func groupsIdenticalConfigurations() throws {
        let (inv, report) = try inventory(devicesFixture: "duplicate-devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let results = DuplicateDeviceRule().evaluate(context)

        #expect(results.count == 1)
        #expect(results.first?.target.deviceIDs.count == 3)
    }

    @Test("Never proposes a destructive action")
    func neverProposesDeletion() throws {
        let (inv, report) = try inventory(devicesFixture: "duplicate-devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        #expect(DuplicateDeviceRule().evaluate(context).allSatisfy { !$0.action.isDestructive })
    }

    @Test("Warns that duplicates may be intentional")
    func warnsDuplicatesMayBeIntentional() throws {
        let (inv, report) = try inventory(devicesFixture: "duplicate-devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let result = try #require(DuplicateDeviceRule().evaluate(context).first)
        #expect(result.reasons.contains { $0.summary.contains("can be intentional") })
    }

    @Test("Suggests keeping the copy with evidence of use")
    func suggestsMostRecentlyUsedKeeper() throws {
        let (inv, report) = try inventory(devicesFixture: "duplicate-devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        let result = try #require(DuplicateDeviceRule().evaluate(context).first)

        // Only "iPhone 17" has a boot record in this fixture.
        #expect(result.reasons.contains { $0.summary.contains("\"iPhone 17\" looks like the one in use") })
    }

    @Test("Says so plainly when no copy has any evidence behind it")
    func admitsWhenThereIsNoEvidence() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("duplicate-devices")).items
            .filter { !$0.hasEverBooted }
        let context = RecommendationContext(
            inventory: SimulatorInventory(devices: devices, runtimes: []),
            report: nil, now: referenceNow
        )
        let result = try #require(DuplicateDeviceRule().evaluate(context).first)
        #expect(result.reasons.contains { $0.summary.contains("no evidence favouring one") })
    }

    @Test("A single device of a kind is not a duplicate")
    func ignoresUniqueDevices() throws {
        let (inv, report) = try inventory(devicesFixture: "devices")
        let context = RecommendationContext(inventory: inv, report: report, now: referenceNow)
        #expect(DuplicateDeviceRule().evaluate(context).isEmpty)
    }
}

@Suite("Rule E — redundant runtimes")
struct RedundantRuntimeRuleTests {

    private func context(devices: [SimulatorDevice] = []) throws -> RecommendationContext {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("redundant-runtimes"),
            runtimeImagesData: Fixture.data("redundant-runtime-list")
        )
        return RecommendationContext(
            inventory: SimulatorInventory(devices: devices, runtimes: runtimes),
            report: nil, now: referenceNow
        )
    }

    @Test("Suggests review of an old, unused runtime superseded on its own platform")
    func flagsSupersededRuntime() throws {
        let results = RedundantRuntimeRule().evaluate(try context())

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.target == .runtime("com.apple.CoreSimulator.SimRuntime.iOS-17-5"))
        #expect(result.action == .reviewRuntime)
        #expect(!result.action.isDestructive)
        #expect(result.level == .low, "this is a prompt to think, not a proposal")
    }

    /// A newer runtime on one platform says nothing about another.
    @Test("Does not use an iOS upgrade to indict watchOS")
    func doesNotCrossPlatforms() throws {
        let results = RedundantRuntimeRule().evaluate(try context())
        #expect(!results.contains { $0.target == .runtime("com.apple.CoreSimulator.SimRuntime.watchOS-11-2") })
    }

    @Test("Never claims a newer runtime makes an older one unnecessary")
    func refusesToClaimObsolescence() throws {
        let result = try #require(RedundantRuntimeRule().evaluate(try context()).first)
        let coverage = try #require(result.reasons.first { $0.kind == .redundantCoverage })
        #expect(coverage.summary.contains("does not make"))
        #expect(coverage.isObservedFact == false)
    }

    @Test("Respects simctl's deletable flag over age and size")
    func respectsDeletableFlag() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: Fixture.data("multi-runtime-list")
        )
        let ctx = RecommendationContext(
            inventory: SimulatorInventory(devices: [], runtimes: runtimes),
            report: nil, now: referenceNow
        )
        // iOS 18.2 and 16.4 are both older than 26.5 but not deletable.
        #expect(RedundantRuntimeRule().evaluate(ctx).isEmpty)
    }

    @Test("Names the devices that removing the runtime would strand")
    func namesDependentDevices() throws {
        let dependent = SimulatorDevice(
            id: UUID(), name: "iPhone 15 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
            state: .shutdown,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro",
            isAvailable: true,
            dataPath: URL(fileURLWithPath: "/tmp"), logPath: URL(fileURLWithPath: "/tmp")
        )
        let result = try #require(RedundantRuntimeRule().evaluate(try context(devices: [dependent])).first)

        #expect(result.cautions.contains { $0.kind == .runtimeInUse })
        #expect(result.reasons.contains { $0.summary.contains("iPhone 15 Pro") })
    }
}
