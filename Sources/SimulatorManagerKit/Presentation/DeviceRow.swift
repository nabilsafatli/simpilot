import Foundation

/// A device joined with everything the UI needs to show it in one line.
///
/// Assembled once rather than looked up per column, so sorting and filtering stay
/// pure functions over a flat list and can be tested without any view.
public struct DeviceRow: Identifiable, Sendable {
    public let device: SimulatorDevice
    /// Measured size, or nil when no scan has completed yet. Nil is distinct from
    /// zero: an unscanned device is not an empty one.
    public let measuredBytes: Int64?
    /// The runtime's display name, or nil when the runtime is no longer installed
    /// — which is itself the signal that the device is stranded.
    public let runtimeName: String?
    /// The pairing this device belongs to. Deleting either half breaks it.
    public let pair: DevicePair?

    public var id: UUID { device.id }
    public var isPaired: Bool { pair != nil }
    public var isStranded: Bool { !device.isAvailable }
    public var hasEverBooted: Bool { device.hasEverBooted }

    public init(
        device: SimulatorDevice,
        measuredBytes: Int64? = nil,
        runtimeName: String? = nil,
        pair: DevicePair? = nil
    ) {
        self.device = device
        self.measuredBytes = measuredBytes
        self.runtimeName = runtimeName
        self.pair = pair
    }

    /// Builds the rows for a whole inventory.
    public static func rows(
        inventory: SimulatorInventory,
        report: SimulatorStorageReport?
    ) -> [DeviceRow] {
        let runtimeNames = Dictionary(
            inventory.runtimes.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return inventory.devices.map { device in
            DeviceRow(
                device: device,
                measuredBytes: report?.storage(forDevice: device.id)?.totalBytes,
                runtimeName: runtimeNames[device.runtimeIdentifier],
                pair: inventory.pair(containing: device.id)
            )
        }
    }
}
