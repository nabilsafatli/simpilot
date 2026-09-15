import Foundation

/// Formats sizes for display.
///
/// Every size this app shows is an estimate — simctl's own figures drift, and APFS
/// clones mean deleting a target can free less than its measured size. The phrasing
/// helpers here exist so that caveat is carried in the copy rather than left to
/// each call site to remember.
///
/// Uses `FormatStyle` rather than the older formatter classes: these are value
/// types, so they are safe to use from the concurrent scan and the main actor alike.
public enum ByteFormatting {
    public static func string(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb, .gb, .tb]))
    }

    /// A size the user might act on, marked as approximate.
    public static func approximate(_ bytes: Int64) -> String {
        "~\(string(bytes))"
    }

    /// Renders an optional size without inventing a zero for missing data.
    /// A size we do not have is not a size of nothing.
    public static func stringOrUnknown(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unknown" }
        return string(bytes)
    }
}

public enum DateFormatting {
    /// Describes when something was last used.
    ///
    /// Returns nil for "never", so callers must choose their own wording rather
    /// than receiving a phrase that overstates what simctl said. The absence of a
    /// boot record is a fact about the record, not proof the device is unwanted.
    public static func lastUsed(_ date: Date?, relativeTo now: Date = Date()) -> String? {
        guard let date else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    public static func daysSince(_ date: Date?, now: Date = Date()) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: now).day
    }

    public static func absolute(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
