import Foundation

/// Something simctl reported that could not be turned into a domain model.
///
/// Parsing is lenient by entry and strict by document: one malformed device does
/// not discard the other ninety-nine, but neither is it dropped silently. Issues
/// travel with the parsed results so the UI can say "3 entries could not be read"
/// instead of quietly showing an inventory that is missing rows. An app that
/// deletes things must never understate what it failed to see.
public struct ParseIssue: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case malformedDeviceIdentifier
        case malformedPairIdentifier
        case missingRequiredField
    }

    public let kind: Kind
    /// Whatever identified the entry in simctl's output, for the user to chase.
    public let rawIdentifier: String
    public let detail: String

    public init(kind: Kind, rawIdentifier: String, detail: String) {
        self.kind = kind
        self.rawIdentifier = rawIdentifier
        self.detail = detail
    }
}

/// Parsed items alongside anything that could not be parsed.
public struct ParseOutcome<Element: Sendable>: Sendable {
    public let items: [Element]
    public let issues: [ParseIssue]

    public init(items: [Element], issues: [ParseIssue] = []) {
        self.items = items
        self.issues = issues
    }
}
