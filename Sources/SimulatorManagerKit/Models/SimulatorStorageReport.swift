import Foundation

/// Measured disk usage across the simulator storage trees.
///
/// Every figure here is an estimate, and not merely as a disclaimer: APFS clones
/// mean two files can share blocks, so deleting one target may free less than its
/// reported size. This is why cleanup reports *measured* recovery from a re-scan
/// rather than echoing a prediction.
public struct SimulatorStorageReport: Hashable, Sendable {

    /// Disk usage of one device's directory, measured by walking the filesystem
    /// rather than trusting simctl's cached `dataPathSize`.
    public struct DeviceStorage: Identifiable, Hashable, Sendable {
        public let id: UUID
        /// Measured size of the whole device directory. This can exceed the size
        /// of `data/` alone, because CoreSimulator writes sibling directories
        /// next to it (e.g. `datacom.apple.modelcatalog`).
        public let totalBytes: Int64
        /// Measured size of the device's log directory, which lives in a separate
        /// tree under `~/Library/Logs/CoreSimulator`.
        public let logBytes: Int64
        /// What simctl claimed, retained so the UI can explain a discrepancy
        /// rather than silently disagree with the command line.
        public let reportedBytes: Int64?

        public init(id: UUID, totalBytes: Int64, logBytes: Int64, reportedBytes: Int64? = nil) {
            self.id = id
            self.totalBytes = totalBytes
            self.logBytes = logBytes
            self.reportedBytes = reportedBytes
        }
    }

    /// A log directory with no corresponding device, left behind when a device
    /// was deleted.
    ///
    /// Reported only. There is no simctl command to remove these, and this app
    /// does not delete simulator data by any other means.
    public struct OrphanedLogDirectory: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let path: URL
        public let sizeBytes: Int64
        public let modifiedAt: Date?

        public init(id: UUID, path: URL, sizeBytes: Int64, modifiedAt: Date? = nil) {
            self.id = id
            self.path = path
            self.sizeBytes = sizeBytes
            self.modifiedAt = modifiedAt
        }
    }

    public let devices: [DeviceStorage]
    public let orphanedLogDirectories: [OrphanedLogDirectory]

    /// Simulator storage that belongs to no single device: `Caches` and `Temp`
    /// under the user's CoreSimulator directory.
    public let sharedBytes: Int64

    /// Sum of runtime image sizes as reported by simctl. Kept separate from
    /// device storage because it lives in a different tree entirely and is not
    /// measured by this scanner.
    public let runtimeBytes: Int64

    public let scannedAt: Date

    public var deviceBytes: Int64 { devices.reduce(0) { $0 + $1.totalBytes } }
    public var deviceLogBytes: Int64 { devices.reduce(0) { $0 + $1.logBytes } }
    public var orphanedLogBytes: Int64 { orphanedLogDirectories.reduce(0) { $0 + $1.sizeBytes } }

    /// Everything the app accounts for, across all trees.
    public var totalBytes: Int64 {
        deviceBytes + deviceLogBytes + orphanedLogBytes + sharedBytes + runtimeBytes
    }

    public func storage(forDevice id: UUID) -> DeviceStorage? {
        devices.first { $0.id == id }
    }

    public init(
        devices: [DeviceStorage],
        orphanedLogDirectories: [OrphanedLogDirectory] = [],
        sharedBytes: Int64 = 0,
        runtimeBytes: Int64 = 0,
        scannedAt: Date = Date()
    ) {
        self.devices = devices
        self.orphanedLogDirectories = orphanedLogDirectories
        self.sharedBytes = sharedBytes
        self.runtimeBytes = runtimeBytes
        self.scannedAt = scannedAt
    }
}
