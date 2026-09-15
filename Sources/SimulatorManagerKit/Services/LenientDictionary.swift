import Foundation

/// A coding key that accepts whatever string the payload uses.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }
}

/// Decodes a dictionary, skipping entries whose values do not fit `Value`.
///
/// `simctl runtime list --json` returns a **bare** top-level dictionary keyed by
/// image UUID, with no wrapper object. Ordinary `[String: T]` decoding therefore
/// fails outright if the payload ever gains a sibling key of a different shape —
/// a metadata field in a future Xcode, for instance. Since this app's inventory
/// is the basis for destructive decisions, losing the entire runtime listing
/// because of one unrecognised key is the wrong failure mode.
///
/// Skipping fails in the safe direction: a runtime image that cannot be decoded
/// contributes no UUID and no size, so its runtime is reported as **not
/// deletable** and the user is never offered an action that cannot succeed.
struct LenientDictionary<Value: Decodable>: Decodable {
    let values: [String: Value]
    /// Keys that were present but did not decode, retained for diagnostics.
    let skippedKeys: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var decoded: [String: Value] = [:]
        var skipped: [String] = []

        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                decoded[key.stringValue] = value
            } else {
                skipped.append(key.stringValue)
            }
        }

        self.values = decoded
        self.skippedKeys = skipped
    }
}
