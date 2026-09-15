import Foundation

/// The figures the Dashboard shows.
///
/// Derived entirely from observation. There is deliberately no "potentially
/// recoverable space" here: nothing is recoverable until a recommendation says so
/// and the user agrees, and a headline number implying otherwise would make this
/// a cleaner rather than a decision-support tool. That figure arrives with the
/// recommendation engine, attached to specific targets the user has reviewed.
public struct DashboardSummary: Hashable, Sendable {
    public let deviceCount: Int
    public let runtimeCount: Int
    public let platformCount: Int

    /// Devices whose runtime is no longer installed. Directly observable from
    /// simctl, so this one can be stated as fact.
    public let unavailableDeviceCount: Int
    public let neverBootedCount: Int
    public let runningCount: Int

    public let deviceBytes: Int64
    public let runtimeBytes: Int64
    public let sharedBytes: Int64
    public let logBytes: Int64
    public let orphanedLogBytes: Int64
    public let orphanedLogCount: Int

    /// True when sizes come from a completed scan. Until then the UI must not
    /// present byte counts as measured.
    public let isMeasured: Bool

    public var totalBytes: Int64 {
        deviceBytes + runtimeBytes + sharedBytes + logBytes + orphanedLogBytes
    }

    public init(inventory: SimulatorInventory, report: SimulatorStorageReport?) {
        deviceCount = inventory.devices.count
        runtimeCount = inventory.runtimes.count
        platformCount = Set(inventory.runtimes.map(\.platform)).count
        unavailableDeviceCount = inventory.devices.filter { !$0.isAvailable }.count
        neverBootedCount = inventory.devices.filter { !$0.hasEverBooted }.count
        runningCount = inventory.devices.filter { $0.state.isActive }.count

        deviceBytes = report?.deviceBytes ?? 0
        // Runtime sizes come from simctl and are known even before a scan runs.
        runtimeBytes = inventory.runtimes.compactMap(\.sizeBytes).reduce(0, +)
        sharedBytes = report?.sharedBytes ?? 0
        logBytes = report?.deviceLogBytes ?? 0
        orphanedLogBytes = report?.orphanedLogBytes ?? 0
        orphanedLogCount = report?.orphanedLogDirectories.count ?? 0
        isMeasured = report != nil
    }
}
