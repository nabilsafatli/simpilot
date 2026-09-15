import Foundation

/// A watch/phone pairing, from `xcrun simctl list pairs --json`.
///
/// Pairings matter for safety rather than storage: deleting either half breaks
/// the pair, and nothing in a device's own listing reveals that it is paired.
public struct DevicePair: Identifiable, Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let state: SimulatorState

        public init(id: UUID, name: String, state: SimulatorState) {
            self.id = id
            self.name = name
            self.state = state
        }
    }

    public let id: UUID
    public let watch: Member
    public let phone: Member
    /// simctl's own description, e.g. `(active, disconnected)`. Display-only.
    public let state: String

    public init(id: UUID, watch: Member, phone: Member, state: String) {
        self.id = id
        self.watch = watch
        self.phone = phone
        self.state = state
    }

    public func contains(deviceID: UUID) -> Bool {
        watch.id == deviceID || phone.id == deviceID
    }

    /// The other half of the pair, used to name what a deletion would break.
    public func counterpart(of deviceID: UUID) -> Member? {
        if watch.id == deviceID { return phone }
        if phone.id == deviceID { return watch }
        return nil
    }
}
