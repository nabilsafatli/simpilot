import Foundation

/// Lifecycle state of a simulator device, as reported by `simctl`.
///
/// Unrecognized states are preserved rather than collapsed, so a future Xcode
/// introducing a new state cannot silently be treated as ``shutdown`` — which
/// would be unsafe, since a running device must never be deleted without warning.
public enum SimulatorState: Hashable, Sendable {
    case booted
    case shutdown
    case booting
    case shuttingDown
    case creating
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "booted": self = .booted
        case "shutdown": self = .shutdown
        case "booting": self = .booting
        case "shutting down": self = .shuttingDown
        case "creating": self = .creating
        default: self = .unknown(rawValue)
        }
    }

    /// Whether the device is doing something that deletion would interrupt.
    ///
    /// Unknown states count as active: if we cannot prove a device is idle, we
    /// treat it as busy rather than assume it is safe to remove.
    public var isActive: Bool {
        switch self {
        case .shutdown: false
        case .booted, .booting, .shuttingDown, .creating: true
        case .unknown: true
        }
    }

    public var displayName: String {
        switch self {
        case .booted: "Booted"
        case .shutdown: "Shutdown"
        case .booting: "Booting"
        case .shuttingDown: "Shutting Down"
        case .creating: "Creating"
        case .unknown(let raw): raw
        }
    }
}
