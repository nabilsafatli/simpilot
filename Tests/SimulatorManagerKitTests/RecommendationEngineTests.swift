import Foundation
import Testing
@testable import SimulatorManagerKit

@Suite("Recommendation engine — merging and ordering")
struct RecommendationEngineTests {

    /// Rules B and C both describe the same device. The user must see one entry
    /// carrying both reasons, not two competing suggestions.
    @Test("Rules describing the same device merge into one recommendation")
    func mergesRulesForSameDevice() throws {
        let (inv, report) = try inventory(devicesFixture: "large-unused-device")
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        let neverBooted = try #require(inv.devices.first { $0.name.contains("large never booted") })
        let merged = try #require(result.recommendation(forDevice: neverBooted.id))

        #expect(merged.reasons.contains { $0.kind == .neverUsed })
        #expect(merged.reasons.contains { $0.kind == .largeUnusedDevice })

        // Merging is per action, not per device: proposing both "delete this" and
        // "erase this" is a real choice to offer, not a duplicate to collapse.
        let deletions = result.recommendations.filter {
            $0.target == .device(neverBooted.id) && $0.action == .deleteDevice
        }
        #expect(deletions.count == 1)
    }

    /// The central honesty property of the engine. Several weak signals must not
    /// accumulate into something that reads as certainty.
    @Test("Merged confidence is the maximum, never the sum")
    func confidenceIsMaxNotSum() throws {
        let (inv, report) = try inventory(devicesFixture: "large-unused-device")
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        let neverBooted = try #require(inv.devices.first { $0.name.contains("large never booted") })
        let merged = try #require(result.recommendation(forDevice: neverBooted.id))

        // Rule B contributes 0.5 and Rule C 0.7. Their sum would cross into
        // "high confidence" and misrepresent two heuristics as an observation.
        #expect(merged.confidence == 0.7)
        #expect(merged.level == .medium)
        #expect(!merged.hasOnlyObservedEvidence, "a large-footprint inference is not an observation")
    }

    @Test("Recommendations are ordered most confident first")
    func ordersByConfidence() throws {
        let (inv, report) = try inventory(
            devicesFixture: "unavailable-runtime",
            runtimesFixture: "redundant-runtimes",
            runtimeImagesFixture: "redundant-runtime-list"
        )
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        let confidences = result.recommendations.map(\.confidence)
        #expect(confidences == confidences.sorted(by: >))
        #expect(result.recommendations.first?.level == .high)
    }

    @Test("The same inventory always produces the same report")
    func isDeterministic() throws {
        let (inv, report) = try inventory(
            devicesFixture: "duplicate-devices",
            runtimesFixture: "redundant-runtimes",
            runtimeImagesFixture: "redundant-runtime-list",
            pairsFixture: "pairs"
        )
        let engine = RecommendationEngine()

        let first = engine.evaluate(inventory: inv, report: report, now: referenceNow)
        for _ in 0..<8 {
            let next = engine.evaluate(inventory: inv, report: report, now: referenceNow)
            #expect(next.recommendations.map(\.target) == first.recommendations.map(\.target))
            #expect(next.recommendations.map(\.confidence) == first.recommendations.map(\.confidence))
            #expect(next.recommendations.map(\.reasons) == first.recommendations.map(\.reasons))
        }
    }

    @Test("Duplicate reasons are not repeated after a merge")
    func dedupesReasons() throws {
        let (inv, report) = try inventory(devicesFixture: "large-unused-device")
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        for recommendation in result.recommendations {
            #expect(Set(recommendation.reasons.map(\.id)).count == recommendation.reasons.count)
            #expect(Set(recommendation.cautions.map(\.id)).count == recommendation.cautions.count)
        }
    }

    // MARK: - Recoverable space accounting

    @Test("Reviews contribute nothing to the actionable total")
    func reviewsAreNotCountedAsSavings() throws {
        let (inv, report) = try inventory(devicesFixture: "duplicate-devices")
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        let review = try #require(result.recommendations.first { $0.action == .reviewDuplicates })
        #expect(review.recoverableBytes > 0, "the stakes are still described")

        // ...but nothing the user has not agreed to is advertised as savings.
        let fromReviews = result.recommendations
            .filter { !$0.action.isDestructive }
            .reduce(Int64(0)) { $0 + $1.recoverableBytes }
        #expect(fromReviews > 0)

        let destructiveOnly = result.recommendations
            .filter { $0.action.isDestructive }
            .reduce(Int64(0)) { $0 + $1.recoverableBytes }
        #expect(result.actionableRecoverableBytes <= destructiveOnly,
                "the total may not exceed what the destructive suggestions claim")
        #expect(result.actionableRecoverableBytes < fromReviews + destructiveOnly,
                "review bytes are excluded from the total")
    }

    /// A device may now carry both a delete and an erase suggestion. Adding both
    /// figures would advertise the same gigabytes twice.
    @Test("A device with two possible actions is counted once")
    func doesNotDoubleCountDevices() throws {
        let (inv, storage) = try inventory(devicesFixture: "devices")
        let device = try #require(inv.devices.first { $0.name == "iPhone 17" })
        let measured = try #require(storage.storage(forDevice: device.id)?.totalBytes)

        let both = [
            Recommendation(target: .device(device.id), action: .deleteDevice,
                           reasons: [.init(kind: .stale, summary: "d", isObservedFact: true)],
                           confidence: 0.6, recoverableBytes: measured),
            Recommendation(target: .device(device.id), action: .eraseDevice,
                           reasons: [.init(kind: .reclaimableData, summary: "e", isObservedFact: true)],
                           confidence: 0.4, recoverableBytes: measured - 18_337_792)
        ]
        let report = RecommendationReport(recommendations: both)

        #expect(report.recommendations.count == 2, "both remain on offer")
        #expect(report.actionableRecoverableBytes == measured,
                "but the device's space is counted once, at its larger claim")
    }

    @Test("An empty machine yields an empty report")
    func handlesEmptyInventory() {
        let result = RecommendationEngine().evaluate(
            inventory: SimulatorInventory(devices: [], runtimes: []),
            report: nil, now: referenceNow
        )
        #expect(result.isEmpty)
        #expect(result.actionableRecoverableBytes == 0)
    }

    @Test("Filtering by confidence returns only what qualifies")
    func filtersByConfidence() throws {
        let (inv, report) = try inventory(devicesFixture: "unavailable-runtime")
        let result = RecommendationEngine().evaluate(inventory: inv, report: report, now: referenceNow)

        #expect(result.recommendations(atLeast: .high).allSatisfy { $0.level == .high })
        #expect(result.recommendations(atLeast: .low).count == result.recommendations.count)
    }
}

/// Properties that must hold for every recommendation the engine can produce,
/// checked across every fixture rather than one case at a time. These encode the
/// brief's hard safety rules directly.
@Suite("Recommendation safety invariants")
struct RecommendationSafetyTests {

    static let deviceFixtures = [
        "devices", "duplicate-devices", "large-unused-device",
        "unavailable-runtime", "active-only-devices", "empty-devices"
    ]

    private func report(_ fixture: String) throws -> (SimulatorInventory, RecommendationReport) {
        let (inv, storage) = try inventory(
            devicesFixture: fixture,
            runtimesFixture: "redundant-runtimes",
            runtimeImagesFixture: "redundant-runtime-list",
            pairsFixture: "pairs"
        )
        return (inv, RecommendationEngine().evaluate(inventory: inv, report: storage, now: referenceNow))
    }

    @Test("Duplication never justifies a deletion", arguments: RecommendationSafetyTests.deviceFixtures)
    func duplicationNeverJustifiesDeletion(fixture: String) throws {
        let (_, result) = try report(fixture)
        for recommendation in result.recommendations where recommendation.action.isDestructive {
            #expect(!recommendation.reasons.contains { $0.kind == .duplicate })
        }
    }

    @Test("Size alone never justifies a deletion", arguments: RecommendationSafetyTests.deviceFixtures)
    func sizeAloneNeverJustifiesDeletion(fixture: String) throws {
        let (_, result) = try report(fixture)
        for recommendation in result.recommendations where recommendation.action.isDestructive {
            let kinds = Set(recommendation.reasons.map(\.kind))
            if kinds.contains(.largeUnusedDevice) {
                #expect(kinds.contains(.neverUsed) || kinds.contains(.stale),
                        "a large device must also be unused to be flagged")
            }
        }
    }

    @Test("Age alone never justifies deleting a runtime", arguments: RecommendationSafetyTests.deviceFixtures)
    func ageAloneNeverDeletesRuntime(fixture: String) throws {
        let (_, result) = try report(fixture)
        for recommendation in result.recommendations {
            if case .runtime = recommendation.target {
                #expect(recommendation.action == .reviewRuntime,
                        "runtimes are only ever put up for review")
                #expect(!recommendation.action.isDestructive)
            }
        }
    }

    /// Nothing in a device's own listing reveals a pairing, so the recommendation
    /// is the only place the user would learn what a deletion breaks.
    @Test("A paired device always carries the pairing caution",
          arguments: RecommendationSafetyTests.deviceFixtures)
    func pairedDevicesCarryCaution(fixture: String) throws {
        let (inv, result) = try report(fixture)
        for recommendation in result.recommendations {
            for id in recommendation.target.deviceIDs where inv.pair(containing: id) != nil {
                #expect(recommendation.cautions.contains { $0.kind == .breaksPairing },
                        "\(fixture): a paired device was flagged without saying so")
            }
        }
    }

    @Test("A running device always carries the running caution",
          arguments: RecommendationSafetyTests.deviceFixtures)
    func runningDevicesCarryCaution(fixture: String) throws {
        let (inv, result) = try report(fixture)
        let running = Set(inv.devices.filter { $0.state.isActive }.map(\.id))

        for recommendation in result.recommendations {
            for id in recommendation.target.deviceIDs where running.contains(id) {
                #expect(recommendation.cautions.contains { $0.kind == .deviceIsRunning })
            }
        }
    }

    @Test("Every recommendation explains itself", arguments: RecommendationSafetyTests.deviceFixtures)
    func everyRecommendationHasReasons(fixture: String) throws {
        let (_, result) = try report(fixture)
        for recommendation in result.recommendations {
            #expect(!recommendation.reasons.isEmpty)
            #expect(recommendation.reasons.allSatisfy { !$0.summary.isEmpty })
            #expect((0...1).contains(recommendation.confidence))
        }
    }

    /// Only Rule A's finding is certain enough to act on with high confidence.
    @Test("Only an unavailable runtime reaches high confidence",
          arguments: RecommendationSafetyTests.deviceFixtures)
    func onlyUnavailableRuntimeReachesHighConfidence(fixture: String) throws {
        let (_, result) = try report(fixture)
        for recommendation in result.recommendations where recommendation.level == .high {
            #expect(recommendation.hasOnlyObservedEvidence,
                    "\(fixture): a high-confidence finding must rest on observation")
            #expect(recommendation.reasons.contains { $0.kind == .unavailableRuntime },
                    "\(fixture): only an unavailable runtime is certain enough")
        }
    }

    /// The distinction the engine exists to preserve: evidence can be entirely
    /// observed while the conclusion drawn from it remains a judgement. simctl
    /// really does have no boot record for a never-booted device — that is a fact.
    /// "You do not need it" is not, and must not inherit the evidence's certainty.
    @Test("Observed evidence does not by itself confer confidence")
    func observedEvidenceDoesNotImplyConfidence() throws {
        let (inv, storage) = try inventory(devicesFixture: "devices")
        let result = RecommendationEngine().evaluate(inventory: inv, report: storage, now: referenceNow)

        let neverBooted = try #require(result.recommendations.first {
            $0.reasons.contains { $0.kind == .neverUsed }
        })
        #expect(neverBooted.hasOnlyObservedEvidence, "the absence of a boot record is observed")
        #expect(neverBooted.level == .medium, "but the conclusion stays a judgement")
    }

    @Test("Identity is derived from the target, not generated per evaluation")
    func identityIsStableAcrossEvaluations() throws {
        let (inv, storage) = try inventory(devicesFixture: "unavailable-runtime")
        let engine = RecommendationEngine()

        let first = engine.evaluate(inventory: inv, report: storage, now: referenceNow)
        let second = engine.evaluate(inventory: inv, report: storage, now: referenceNow)

        #expect(first.recommendations.map(\.id) == second.recommendations.map(\.id))
        #expect(Set(first.recommendations.map(\.id)).count == first.recommendations.count)
    }

    @Test("No recommendation promises safety", arguments: RecommendationSafetyTests.deviceFixtures)
    func neverPromisesSafety(fixture: String) throws {
        let (_, result) = try report(fixture)
        for recommendation in result.recommendations {
            for reason in recommendation.reasons {
                #expect(!reason.summary.localizedCaseInsensitiveContains("safe to"),
                        "\(fixture): \(reason.summary)")
                #expect(!reason.summary.localizedCaseInsensitiveContains("you don't need"))
            }
        }
    }
}
