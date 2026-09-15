import Foundation

/// A simulator device as reported by `xcrun simctl list devices --json`.
public struct SimulatorDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let runtimeIdentifier: String
    public let state: SimulatorState
    public let deviceTypeIdentifier: String

    /// Directly observable from simctl. Drives the only delete recommendation
    /// this app states as fact rather than judgment (Rule A).
    public let isAvailable: Bool

    /// simctl's explanation for `isAvailable == false`, when it supplies one.
    ///
    /// Display-only. No rule keys off this string: its exact wording was never
    /// verified against real output during Phase 0, whereas `isAvailable` was
    /// present on every device in every capture.
    public let availabilityError: String?

    /// When the device was last booted, persisted by CoreSimulator in the
    /// device's `device.plist`.
    ///
    /// `nil` means simctl reported no boot record at all, which is a fact about
    /// the device rather than an inference from filesystem timestamps. It still
    /// does not by itself mean the device is unwanted — a developer may keep an
    /// unbooted device for a future test matrix.
    public let lastBootedAt: Date?

    public let dataPath: URL

    /// Size simctl reported for `dataPath`.
    ///
    /// Do not surface this as the device's size. Phase 0 measured it 9–12% below
    /// actual usage on booted devices (exact only on never-booted ones): it is a
    /// snapshot written at boot/shutdown, not a live measurement. Present here so
    /// the scanner can be compared against it, and so sizes remain available when
    /// a filesystem walk is not possible.
    public let reportedDataPathSize: Int64?

    /// Per-device log directory, which lives under `~/Library/Logs/CoreSimulator`
    /// — a different tree from the device itself.
    public let logPath: URL
    public let reportedLogPathSize: Int64?

    public var hasEverBooted: Bool { lastBootedAt != nil }

    public init(
        id: UUID,
        name: String,
        runtimeIdentifier: String,
        state: SimulatorState,
        deviceTypeIdentifier: String,
        isAvailable: Bool,
        availabilityError: String? = nil,
        lastBootedAt: Date? = nil,
        dataPath: URL,
        reportedDataPathSize: Int64? = nil,
        logPath: URL,
        reportedLogPathSize: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.state = state
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.isAvailable = isAvailable
        self.availabilityError = availabilityError
        self.lastBootedAt = lastBootedAt
        self.dataPath = dataPath
        self.reportedDataPathSize = reportedDataPathSize
        self.logPath = logPath
        self.reportedLogPathSize = reportedLogPathSize
    }
}
