import Foundation
import Testing
@testable import SimulatorManagerKit

/// Rule F is the only rule where size is the primary trigger and the only one
/// that proposes erasing, so its restraint matters more than its reach.
@Suite("Rule F — reclaimable app data")
struct ReclaimableDataRuleTests {

    /// Boot times in the real capture, against which the seven-day threshold is
    /// measured:
    ///
    ///   iPhone 17      2026-09-06 20:40Z   4.38 GB
    ///   iPhone 17 Pro  2026-09-07 05:46Z   2.53 GB
    ///
    /// At 2026-09-13 22:00Z the first is 7 days idle and the second 6, which
    /// straddles the threshold with real data and makes the cliff observable.
    /// `referenceNow` (12:00Z the same day) puts *both* at 6 days.
    static let straddlingClock = try! Date.ISO8601FormatStyle().parse("2026-09-13T22:00:00Z")

    private func context(
        _ fixture: String = "devices",
        now: Date = ReclaimableDataRuleTests.straddlingClock
    ) throws -> RecommendationContext {
        let (inv, storage) = try inventory(devicesFixture: fixture)
        return RecommendationContext(inventory: inv, report: storage, now: now)
    }

    @Test("Flags a device idle for a week that is mostly app data")
    func flagsIdleDeviceHoldingData() throws {
        // In the real capture, only "iPhone 17" is both large and idle 7 days.
        let results = ReclaimableDataRule().evaluate(try context())

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.action == .eraseDevice)
        #expect(result.recoverableBytes == 4_381_171_712 - 18_337_792)
    }

    /// The defect the brief's own "quiet machine" case caught: a simulator used
    /// yesterday holds live working state, whatever its size.
    @Test("Never flags a recently used device, however large")
    func ignoresRecentlyUsedDevices() throws {
        // This fixture's largest device is 19 GB and was booted the day before.
        let results = ReclaimableDataRule().evaluate(try context("large-unused-device"))
        #expect(results.isEmpty, "19 GB in current use is not a finding")

        // And the case from the brief's required tests.
        #expect(ReclaimableDataRule().evaluate(try context("active-only-devices")).isEmpty)
    }

    @Test("The idle threshold is a cliff, not a suggestion")
    func respectsTheIdleThreshold() throws {
        // Ten hours earlier, iPhone 17 is 6 days idle rather than 7.
        let justUnder = try context(now: referenceNow)
        #expect(ReclaimableDataRule().evaluate(justUnder).isEmpty,
                "at 6 days idle nothing is flagged, whatever its size")

        #expect(ReclaimableDataRule().evaluate(try context()).count == 1,
                "ten hours later the same device crosses the threshold")

        // A day later the second device crosses it too.
        let laterStill = try context(now: Self.straddlingClock.addingTimeInterval(24 * 3600))
        #expect(ReclaimableDataRule().evaluate(laterStill).count == 2)
    }

    /// A never-booted device sits at the baseline: erasing it recovers nothing,
    /// and if it somehow holds data, deleting is the better answer.
    @Test("Never flags a device that has never been booted")
    func ignoresNeverBootedDevices() throws {
        // A clock far enough ahead that every booted device qualifies on age,
        // so only the never-booted exclusion can account for what is missing.
        let results = ReclaimableDataRule().evaluate(
            try context(now: referenceNow.addingTimeInterval(400 * 24 * 3600))
        )
        let flagged = Set(results.flatMap(\.target.deviceIDs))
        let (inv, _) = try inventory(devicesFixture: "devices")

        for device in inv.devices where !device.hasEverBooted {
            #expect(!flagged.contains(device.id))
        }
    }

    @Test("Never flags a device whose runtime is missing")
    func ignoresUnavailableDevices() throws {
        // Erasing needs a working runtime; Rule A proposes deletion instead.
        let results = ReclaimableDataRule().evaluate(
            try context("unavailable-runtime", now: referenceNow.addingTimeInterval(400 * 24 * 3600))
        )
        for result in results {
            let (inv, _) = try inventory(devicesFixture: "unavailable-runtime")
            for id in result.target.deviceIDs {
                #expect(inv.devices.first { $0.id == id }?.isAvailable == true)
            }
        }
    }

    @Test("Does not act on simctl's cached size")
    func requiresMeasurement() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("devices")).items
        let unmeasured = RecommendationContext(
            inventory: SimulatorInventory(devices: devices, runtimes: []),
            report: nil, now: referenceNow
        )
        #expect(ReclaimableDataRule().evaluate(unmeasured).isEmpty)
    }

    @Test("Ignores a device whose excess is below the threshold")
    func ignoresSmallExcess() throws {
        let device = SimulatorDevice(
            id: UUID(), name: "Modest", runtimeIdentifier: "r", state: .shutdown,
            deviceTypeIdentifier: "t", isAvailable: true,
            lastBootedAt: referenceNow.addingTimeInterval(-60 * 24 * 3600),
            dataPath: URL(fileURLWithPath: "/tmp"), logPath: URL(fileURLWithPath: "/tmp")
        )
        // 500 MB above baseline: real, but not worth losing a login over.
        let report = SimulatorStorageReport(devices: [
            .init(id: device.id, totalBytes: 18_337_792 + 500_000_000, logBytes: 0)
        ])
        let ctx = RecommendationContext(
            inventory: SimulatorInventory(devices: [device], runtimes: []),
            report: report, now: referenceNow
        )
        #expect(ReclaimableDataRule().evaluate(ctx).isEmpty)
    }

    /// A bigger number attached to the same unanswerable question is not more
    /// certainty.
    @Test("Confidence does not rise with size")
    func confidenceIsFlat() throws {
        func confidence(forBytes bytes: Int64) throws -> Double {
            let device = SimulatorDevice(
                id: UUID(), name: "D", runtimeIdentifier: "r", state: .shutdown,
                deviceTypeIdentifier: "t", isAvailable: true,
                lastBootedAt: referenceNow.addingTimeInterval(-60 * 24 * 3600),
                dataPath: URL(fileURLWithPath: "/tmp"), logPath: URL(fileURLWithPath: "/tmp")
            )
            let ctx = RecommendationContext(
                inventory: SimulatorInventory(devices: [device], runtimes: []),
                report: SimulatorStorageReport(devices: [.init(id: device.id, totalBytes: bytes, logBytes: 0)]),
                now: referenceNow
            )
            return try #require(ReclaimableDataRule().evaluate(ctx).first?.confidence)
        }

        let modest = try confidence(forBytes: 3 * GiB)
        let enormous = try confidence(forBytes: 80 * GiB)
        #expect(modest == enormous)
        #expect(enormous < 0.5, "never more than a prompt to consider")
    }

    @Test("Leads with what is lost, not what is gained")
    func leadsWithDataLoss() throws {
        let result = try #require(ReclaimableDataRule().evaluate(try context()).first)

        #expect(result.cautions.first?.kind == .dataLoss)
        let caution = try #require(result.cautions.first)
        #expect(caution.summary.contains("permanently lost"))
        #expect(caution.summary.contains("cannot be recovered"))
    }

    @Test("Says plainly that size does not answer the question")
    func admitsSizeIsNotTheAnswer() throws {
        let result = try #require(ReclaimableDataRule().evaluate(try context()).first)
        let judgement = try #require(result.reasons.first { !$0.isObservedFact })
        #expect(judgement.summary.contains("Only you can tell"))
        #expect(judgement.summary.contains("Size alone is not a reason"))
    }

    @Test("Never proposes deleting the device")
    func neverProposesDeletion() throws {
        let later = try context(now: referenceNow.addingTimeInterval(400 * 24 * 3600))
        for result in ReclaimableDataRule().evaluate(later) {
            #expect(result.action == .eraseDevice)
        }
    }
}

@Suite("Erase and delete on the same device")
struct ActionCollisionTests {

    /// Rule F can propose erasing a device another rule proposes deleting. The
    /// plan is confidence-ordered, so deletion would win by default — which is
    /// the wrong way to resolve an ambiguity about someone else's data.
    @Test("A plan keeps the gentler action when both are selected")
    func prefersEraseOverDelete() throws {
        let (inv, storage) = try inventory(devicesFixture: "devices")
        let device = try #require(inv.devices.first { $0.name == "iPhone 17" })

        let both = [
            Recommendation(target: .device(device.id), action: .deleteDevice,
                           reasons: [.init(kind: .stale, summary: "d", isObservedFact: true)],
                           confidence: 0.7, recoverableBytes: 100),
            Recommendation(target: .device(device.id), action: .eraseDevice,
                           reasons: [.init(kind: .reclaimableData, summary: "e", isObservedFact: true)],
                           confidence: 0.4, recoverableBytes: 50)
        ]

        let plan = CleanupPlan.build(from: both, inventory: inv, report: storage)
        #expect(plan.operations.count == 1)

        let action = try #require(plan.operations.first?.action)
        guard case .eraseDevice = action else {
            Issue.record("expected erase to win, got \(action)")
            return
        }
    }

    @Test("Order of selection does not change which action survives")
    func orderDoesNotMatter() throws {
        let (inv, storage) = try inventory(devicesFixture: "devices")
        let device = try #require(inv.devices.first { $0.name == "iPhone 17" })

        let erase = Recommendation(target: .device(device.id), action: .eraseDevice,
                                   reasons: [.init(kind: .reclaimableData, summary: "e", isObservedFact: true)],
                                   confidence: 0.4)
        let delete = Recommendation(target: .device(device.id), action: .deleteDevice,
                                    reasons: [.init(kind: .stale, summary: "d", isObservedFact: true)],
                                    confidence: 0.7)

        for ordering in [[erase, delete], [delete, erase]] {
            let plan = CleanupPlan.build(from: ordering, inventory: inv, report: storage)
            #expect(plan.operations.count == 1)
            #expect(plan.operations.first?.action.isReversibleByRecreating == true)
        }
    }

    /// Erasing is the gentler action precisely because the device survives.
    @Test("The surviving operation keeps the device")
    func gentlerActionKeepsTheDevice() throws {
        let (inv, storage) = try inventory(devicesFixture: "devices")
        let device = try #require(inv.devices.first { $0.name == "iPhone 17" })

        let plan = CleanupPlan.build(from: [
            Recommendation(target: .device(device.id), action: .deleteDevice,
                           reasons: [.init(kind: .stale, summary: "d", isObservedFact: true)], confidence: 0.7),
            Recommendation(target: .device(device.id), action: .eraseDevice,
                           reasons: [.init(kind: .reclaimableData, summary: "e", isObservedFact: true)], confidence: 0.4)
        ], inventory: inv, report: storage)

        let operation = try #require(plan.operations.first)
        #expect(operation.impact.willKeep.contains { $0.summary.contains(device.name) })
    }
}
