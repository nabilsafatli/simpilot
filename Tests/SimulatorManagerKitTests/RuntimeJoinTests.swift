import Foundation
import Testing
@testable import SimulatorManagerKit

/// `simctl list runtimes` knows which runtimes exist; `simctl runtime list` knows
/// their UUIDs, sizes and whether they can be deleted. Neither is sufficient, so
/// these tests pin the join between them.
@Suite("Runtime join across the two simctl commands")
struct RuntimeJoinTests {

    @Test("Joins the real captured pair of outputs")
    func joinsRealCapture() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("runtimes"),
            runtimeImagesData: Fixture.data("runtime-list")
        )

        #expect(runtimes.count == 1)
        let iOS = try #require(runtimes.first)
        #expect(iOS.id == "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        #expect(iOS.version == "26.5")
        #expect(iOS.build == "23F77")
        #expect(iOS.platform == .iOS)
        #expect(iOS.isAvailable)

        // These three fields exist only in `simctl runtime list`, and the whole
        // point of the join is to have them.
        #expect(iOS.imageUUID == UUID(uuidString: "39BDD188-94B4-4FB2-B91F-59208B8597FE"))
        #expect(iOS.sizeBytes == 8_494_282_293)
        #expect(iOS.isDeletable)
    }

    @Test("Recognises every simulator platform, not just iOS")
    func recognisesAllPlatforms() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: Fixture.data("multi-runtime-list")
        )

        let platforms = Set(runtimes.map(\.platform))
        #expect(platforms == [.iOS, .watchOS, .tvOS, .visionOS])

        // simctl spells visionOS "xrOS" everywhere; the UI should not.
        let vision = try #require(runtimes.first { $0.platform == .visionOS })
        #expect(vision.id.contains("xrOS"))
        #expect(vision.platform.displayName == "visionOS")
    }

    /// A runtime bundled with Xcode appears in `list runtimes` but has no
    /// deletable disk image. Offering to delete it would be an action that
    /// cannot succeed.
    @Test("A runtime with no disk image is not deletable and has no UUID")
    func runtimeWithoutImageIsNotDeletable() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: Fixture.data("multi-runtime-list")
        )

        let iOS164 = try #require(runtimes.first { $0.version == "16.4" })
        #expect(iOS164.imageUUID == nil)
        #expect(iOS164.sizeBytes == nil)
        #expect(iOS164.isDeletable == false)
    }

    /// The deletable flag is simctl's to give. It must not be inferred from age,
    /// size, or version ordering — iOS 18.2 here is newer and larger than others
    /// yet is marked undeletable.
    @Test("Deletability comes from simctl, never inferred from age or size")
    func deletabilityIsNeverInferred() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: Fixture.data("multi-runtime-list")
        )

        let iOS182 = try #require(runtimes.first { $0.version == "18.2" && $0.platform == .iOS })
        #expect(iOS182.sizeBytes == 7_620_035_430)
        #expect(iOS182.isDeletable == false, "simctl said deletable:false; nothing may override that")
    }

    /// Older Xcode releases lack the `simctl runtime` subcommand entirely. The
    /// inventory must still list runtimes — just without deletion offered.
    @Test("Missing runtime-image data degrades to not-deletable, never to a crash")
    func degradesWhenRuntimeListUnavailable() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: nil
        )

        #expect(runtimes.count == 7)
        #expect(runtimes.allSatisfy { $0.imageUUID == nil })
        #expect(runtimes.allSatisfy { !$0.isDeletable })
        #expect(runtimes.allSatisfy { $0.sizeBytes == nil })
    }

    @Test("An unavailable runtime is surfaced as unavailable")
    func detectsUnavailableRuntime() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: Fixture.data("multi-runtime-list")
        )

        let unavailable = runtimes.filter { !$0.isAvailable }
        #expect(unavailable.count == 1)
        #expect(unavailable.first?.version == "17.0")
    }

    @Test("Last usage collapses the per-architecture map to its newest entry")
    func collapsesPerArchitectureUsage() throws {
        #expect(SimctlDate.mostRecent(in: nil) == nil)
        #expect(SimctlDate.mostRecent(in: [:]) == nil)

        let newest = try #require(SimctlDate.mostRecent(in: [
            "arm64": "2026-09-11T18:36:50Z",
            "x86_64": "2025-01-02T03:04:05Z"
        ]))
        #expect(newest == (try Date.ISO8601FormatStyle().parse("2026-09-11T18:36:50Z")))
    }

    @Test("Runtimes with no recorded usage report nil rather than a stand-in date")
    func neverSubstitutesAFakeDate() throws {
        let runtimes = try SimctlParser.parseRuntimes(
            runtimesData: Fixture.data("multi-platform-runtimes"),
            runtimeImagesData: Fixture.data("multi-runtime-list")
        )
        let tvOS = try #require(runtimes.first { $0.platform == .tvOS })
        #expect(tvOS.lastUsedAt == nil)
    }

    @Test("Platform falls back to the runtime identifier when the field is absent")
    func derivesPlatformFromIdentifier() {
        #expect(Platform(reportedPlatform: nil,
                         runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-2") == .watchOS)
        #expect(Platform(reportedPlatform: nil,
                         runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-2-2") == .visionOS)
        #expect(Platform(reportedPlatform: "tvOS",
                         runtimeIdentifier: "irrelevant") == .tvOS)
        #expect(Platform(reportedPlatform: nil,
                         runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.fooOS-1-0")
                == .unknown("fooOS"))
    }
}

@Suite("Device pair parsing")
struct PairParsingTests {

    @Test("The empty pair list captured from a real machine parses cleanly")
    func parsesEmptyPairs() throws {
        let outcome = try SimctlParser.parsePairs(Fixture.data("empty-pairs"))
        #expect(outcome.items.isEmpty)
        #expect(outcome.issues.isEmpty)
    }

    @Test("A pairing names both halves so a deletion can explain what it breaks")
    func parsesPairMembership() throws {
        let outcome = try SimctlParser.parsePairs(Fixture.data("pairs"))
        let pair = try #require(outcome.items.first)

        let phoneID = try #require(UUID(uuidString: "C1111111-1111-4111-8111-111111111111"))
        let watchID = try #require(UUID(uuidString: "E1111111-1111-4111-8111-111111111111"))

        #expect(pair.contains(deviceID: phoneID))
        #expect(pair.contains(deviceID: watchID))
        #expect(pair.counterpart(of: phoneID)?.id == watchID)
        #expect(pair.counterpart(of: watchID)?.name == "iPhone 17")
        #expect(pair.counterpart(of: UUID()) == nil)
    }
}
