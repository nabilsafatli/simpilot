import Foundation

/// The simulated platform a runtime provides.
///
/// `simctl` reports this in the `platform` field of `simctl list runtimes`, but the
/// field is absent on older Xcode releases, so ``init(reportedPlatform:runtimeIdentifier:)``
/// falls back to parsing the runtime identifier. Note that visionOS is spelled `xrOS`
/// everywhere in simctl's output; ``visionOS`` normalizes that for display.
public enum Platform: Hashable, Sendable {
    case iOS
    case watchOS
    case tvOS
    case visionOS
    case unknown(String)

    public init(reportedPlatform: String?, runtimeIdentifier: String) {
        if let reported = reportedPlatform, let known = Platform(rawIdentifier: reported) {
            self = known
            return
        }
        // Fall back to the runtime identifier, e.g.
        // com.apple.CoreSimulator.SimRuntime.watchOS-11-2 -> watchOS
        let trailing = runtimeIdentifier
            .components(separatedBy: ".SimRuntime.")
            .last ?? runtimeIdentifier
        let token = trailing.components(separatedBy: "-").first ?? trailing
        self = Platform(rawIdentifier: token) ?? .unknown(reportedPlatform ?? token)
    }

    private init?(rawIdentifier: String) {
        switch rawIdentifier.lowercased() {
        case "ios": self = .iOS
        case "watchos": self = .watchOS
        case "tvos": self = .tvOS
        case "xros", "visionos": self = .visionOS
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        case .tvOS: "tvOS"
        case .visionOS: "visionOS"
        case .unknown(let raw): raw
        }
    }
}
