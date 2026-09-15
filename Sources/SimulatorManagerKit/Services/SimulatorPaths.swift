import Foundation

/// The filesystem locations simulator storage actually occupies.
///
/// Phase 0 established that these are three separate trees, not one. A scanner
/// pointed only at the user's CoreSimulator directory reports device storage
/// correctly and misses runtime images entirely — which on a typical machine are
/// the single largest reclaimable item.
public struct SimulatorPaths: Hashable, Sendable {
    /// `~/Library/Developer/CoreSimulator` — devices, caches, temp. User-owned.
    public let coreSimulatorRoot: URL
    /// `~/Library/Logs/CoreSimulator` — per-device logs, in a different tree,
    /// and the only place orphaned directories accumulate.
    public let logsRoot: URL

    public var devicesRoot: URL { coreSimulatorRoot.appendingPathComponent("Devices") }
    public var cachesRoot: URL { coreSimulatorRoot.appendingPathComponent("Caches") }
    public var tempRoot: URL { coreSimulatorRoot.appendingPathComponent("Temp") }

    /// Storage that belongs to no single device, and so must never be attributed
    /// to one in the UI.
    public var sharedRoots: [URL] { [cachesRoot, tempRoot] }

    /// A file, not a device directory, that sits among the UUID-named directories
    /// in `Devices/`. Enumerating device directories must skip it.
    public static let deviceSetFileName = "device_set.plist"

    public init(coreSimulatorRoot: URL, logsRoot: URL) {
        self.coreSimulatorRoot = coreSimulatorRoot
        self.logsRoot = logsRoot
    }

    /// The real locations for the current user.
    public static func standard(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> SimulatorPaths {
        SimulatorPaths(
            coreSimulatorRoot: homeDirectory
                .appendingPathComponent("Library/Developer/CoreSimulator"),
            logsRoot: homeDirectory
                .appendingPathComponent("Library/Logs/CoreSimulator")
        )
    }

    public func deviceDirectory(forDeviceID id: UUID) -> URL {
        devicesRoot.appendingPathComponent(id.uuidString)
    }

    public func logDirectory(forDeviceID id: UUID) -> URL {
        logsRoot.appendingPathComponent(id.uuidString)
    }

    // MARK: - Fallbacks used when simctl omits a path

    static func defaultDataPath(forDeviceID id: UUID) -> URL {
        standard().deviceDirectory(forDeviceID: id).appendingPathComponent("data")
    }

    static func defaultLogPath(forDeviceID id: UUID) -> URL {
        standard().logDirectory(forDeviceID: id)
    }
}
