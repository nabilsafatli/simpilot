import Foundation

/// Parses the timestamp formats simctl emits.
///
/// simctl reports ISO-8601 in UTC, but fractional seconds appear in some fields
/// and Xcode versions, so both forms are attempted. Anything unparseable yields
/// nil rather than a substituted date: a wrong timestamp would feed the staleness
/// rules and produce a confident, wrong recommendation.
///
/// `Date.ISO8601FormatStyle` is used rather than `ISO8601DateFormatter` because
/// it is a value type and therefore safe to share across concurrent parses.
enum SimctlDate {
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = try? plain.parse(string) { return date }
        return try? fractional.parse(string)
    }

    /// Collapses simctl's per-architecture usage map to its most recent entry.
    ///
    /// A runtime used on one architecture has been used, so the newest timestamp
    /// across architectures is the honest answer.
    static func mostRecent(in usage: [String: String]?) -> Date? {
        guard let usage else { return nil }
        return usage.values.compactMap(parse).max()
    }
}
