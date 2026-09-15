import Foundation
import Testing
@testable import SimulatorManagerKit

/// Guards the honesty of the test corpus itself.
///
/// Some fixtures are verbatim captures from a real machine; others describe states
/// no machine on hand could produce and were written by hand. Anyone reading a
/// test needs to know which is which, because a hand-built fixture proves only
/// that the parser handles the shape we *believe* simctl emits. These tests fail
/// if that labelling is ever dropped.
@Suite("Fixture integrity")
struct FixtureIntegrityTests {

    /// Captured verbatim from `xcrun simctl` on the Phase 0 machine.
    static let captured = ["devices", "runtimes", "runtime-list"]

    /// Written by hand because no available machine exhibited the state.
    static let constructed = [
        "unavailable-runtime", "duplicate-devices", "large-unused-device",
        "multi-platform-runtimes", "multi-runtime-list", "pairs",
        "empty-pairs", "active-only-devices", "empty-devices",
        "redundant-runtimes", "redundant-runtime-list"
    ]

    @Test("Every hand-constructed fixture explains what was invented",
          arguments: FixtureIntegrityTests.constructed)
    func constructedFixturesAreLabelled(name: String) throws {
        let note = try #require(try Fixture.note(name),
                                "\(name).json is hand-built and must carry a _fixtureNote")
        #expect(note.count > 40, "\(name).json's note should say what was captured vs invented")
    }

    @Test("Captured fixtures are not hand-built",
          arguments: FixtureIntegrityTests.captured)
    func capturedFixturesAreUnannotated(name: String) throws {
        #expect(try Fixture.note(name) == nil,
                "\(name).json is a real capture and must not carry a _fixtureNote")
    }

    /// Captured fixtures are verbatim except for one permitted edit: the
    /// capturing machine's home directory is replaced. Any fixture that took
    /// that edit has to declare it, so "verbatim" never quietly stops being true.
    @Test("Any redaction of a captured fixture is declared",
          arguments: FixtureIntegrityTests.captured)
    func redactionsAreDeclared(name: String) throws {
        let object = try JSONSerialization.jsonObject(with: Fixture.data(name)) as? [String: Any]
        guard let redaction = object?["_redaction"] as? String else { return }
        #expect(redaction.contains("/Users/developer"))
        #expect(redaction.contains("VERBATIM"))
    }

    /// The repository is public. A fixture is the likeliest place for a real
    /// machine's details to survive unnoticed, so this fails if one does.
    @Test("No fixture carries a real home directory",
          arguments: FixtureIntegrityTests.captured + FixtureIntegrityTests.constructed)
    func fixturesCarryNoPersonalPaths(name: String) throws {
        let text = try #require(String(data: try Fixture.data(name), encoding: .utf8))
        // Stop at the first character a macOS short username cannot contain, so
        // prose mentioning a path is not mistaken for the path itself.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let homePaths = text.components(separatedBy: "/Users/")
            .dropFirst()
            .map { segment in
                String(segment.prefix { $0.unicodeScalars.allSatisfy(allowed.contains) })
            }
        for path in homePaths {
            #expect(path == "developer" || path == "dev",
                    "\(name).json leaks a home directory: /Users/\(path)")
        }
    }

    /// The claim that drove the whole Rule B correction. If a future capture
    /// lacks it, the recommendation engine's wording needs revisiting.
    @Test("The real capture still proves boot history is reported by simctl")
    func realCaptureContainsBootHistory() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("devices")).items
        #expect(devices.contains { $0.lastBootedAt != nil },
                "simctl no longer reports lastBootedAt; Rule B's confidence must be revisited")
        #expect(devices.contains { $0.lastBootedAt == nil })
    }

    /// The join exists only because these two commands disagree about identity.
    @Test("The two runtime commands still disagree, which is why the join exists")
    func runtimeCommandsStillRequireJoining() throws {
        let listed = try JSONSerialization.jsonObject(with: Fixture.data("runtimes")) as? [String: Any]
        let runtimes = listed?["runtimes"] as? [[String: Any]]
        let first = try #require(runtimes?.first)
        #expect(first["identifier"] != nil)
        #expect(first["udid"] == nil, "if simctl ever adds a UUID here, the join can be simplified")

        let images = try JSONSerialization.jsonObject(with: Fixture.data("runtime-list")) as? [String: Any]
        let image = try #require(images?.values.first as? [String: Any])
        #expect(image["sizeBytes"] != nil)
        #expect(image["deletable"] != nil)
    }
}
