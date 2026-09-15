import Foundation
import Testing

/// Loads the captured and hand-constructed simctl payloads in `Fixtures/`.
///
/// Every test in this target reads from here rather than from the machine it runs
/// on. That is deliberate: the development machine has one runtime, one platform
/// and no unavailable devices, so it can prove almost nothing about the states
/// this app exists to handle.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json") else {
            Issue.record("Missing fixture: \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// Fixtures we constructed by hand carry a `_fixtureNote` explaining what was
    /// captured versus invented. ``FixtureIntegrityTests`` enforces that.
    static func note(_ name: String) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data(name)) as? [String: Any]
        return object?["_fixtureNote"] as? String
    }
}

/// Bytes in a gibibyte, for readable size assertions.
let GiB: Int64 = 1_073_741_824
