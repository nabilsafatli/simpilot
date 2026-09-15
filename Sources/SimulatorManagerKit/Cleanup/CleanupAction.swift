import Foundation

/// An operation that actually changes something.
///
/// Deliberately narrower than ``RecommendedAction``: the review cases have no
/// representation here at all, so a "review duplicates" finding cannot become an
/// execution through any code path. The type system enforces what the brief
/// requires — that duplication and age never resolve into a deletion on their own.
public enum CleanupAction: Hashable, Sendable {
    case deleteDevice(id: UUID, name: String)
    /// Keeps the device and its identity; clears its data.
    case eraseDevice(id: UUID, name: String)
    case deleteRuntime(imageUUID: UUID, name: String)
    /// simctl's own bulk removal of devices whose runtime is gone.
    case deleteUnavailableDevices(count: Int)

    /// The exact command this will run. Shown to the user before anything happens.
    public var command: SimctlCommand {
        switch self {
        case .deleteDevice(let id, _): .deleteDevice(id: id)
        case .eraseDevice(let id, _): .eraseDevice(id: id)
        case .deleteRuntime(let imageUUID, _): .deleteRuntime(imageUUID: imageUUID)
        case .deleteUnavailableDevices: .deleteUnavailableDevices
        }
    }

    public var targetName: String {
        switch self {
        case .deleteDevice(_, let name), .eraseDevice(_, let name), .deleteRuntime(_, let name):
            name
        case .deleteUnavailableDevices(let count):
            "\(count) unavailable device\(count == 1 ? "" : "s")"
        }
    }

    public var verb: String {
        switch self {
        case .deleteDevice: "Delete simulator"
        case .eraseDevice: "Erase simulator"
        case .deleteRuntime: "Delete runtime"
        case .deleteUnavailableDevices: "Delete unavailable simulators"
        }
    }

    /// Whether the thing being acted on survives the operation.
    public var isReversibleByRecreating: Bool {
        switch self {
        case .eraseDevice: true   // the device remains; only its contents go
        default: false
        }
    }

    public var deviceID: UUID? {
        switch self {
        case .deleteDevice(let id, _), .eraseDevice(let id, _): id
        default: nil
        }
    }
}
