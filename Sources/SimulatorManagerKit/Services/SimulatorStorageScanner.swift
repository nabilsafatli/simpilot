import Foundation

/// Measures simulator disk usage by walking the filesystem.
///
/// Deviates from the original protocol sketch's `scan()` in taking the inventory:
/// a log directory can only be called orphaned if we know which devices exist,
/// and runtime sizes come from simctl rather than from any tree this scanner
/// walks. Both facts were established in Phase 0.
public protocol SimulatorStorageScanner: Sendable {
    func scan(inventory: SimulatorInventory) async throws -> SimulatorStorageReport
}

/// Progress during a scan, for machines where it is not instantaneous.
public struct ScanProgress: Hashable, Sendable {
    public let completedDevices: Int
    public let totalDevices: Int

    public var fractionCompleted: Double {
        totalDevices == 0 ? 1 : Double(completedDevices) / Double(totalDevices)
    }
}

public struct FileSystemStorageScanner: SimulatorStorageScanner {
    private let paths: SimulatorPaths
    private let progressHandler: (@Sendable (ScanProgress) -> Void)?

    public init(
        paths: SimulatorPaths = .standard(),
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) {
        self.paths = paths
        self.progressHandler = progressHandler
    }

    public func scan(inventory: SimulatorInventory) async throws -> SimulatorStorageReport {
        let devices = inventory.devices

        // Devices are measured concurrently. A single device's walk is cheap, but
        // a developer with a hundred of them is exactly who this app is for.
        let deviceStorage = try await withThrowingTaskGroup(
            of: SimulatorStorageReport.DeviceStorage.self
        ) { group in
            for device in devices {
                group.addTask {
                    try Task.checkCancellation()
                    let deviceDirectory = paths.deviceDirectory(forDeviceID: device.id)
                    return SimulatorStorageReport.DeviceStorage(
                        id: device.id,
                        // The whole device directory, not just `data/`: CoreSimulator
                        // writes siblings alongside it that belong to the device.
                        totalBytes: Self.directorySize(at: deviceDirectory),
                        logBytes: Self.directorySize(at: paths.logDirectory(forDeviceID: device.id)),
                        reportedBytes: device.reportedDataPathSize
                    )
                }
            }

            var collected: [SimulatorStorageReport.DeviceStorage] = []
            for try await storage in group {
                collected.append(storage)
                progressHandler?(ScanProgress(
                    completedDevices: collected.count,
                    totalDevices: devices.count
                ))
            }
            return collected
        }

        try Task.checkCancellation()

        return SimulatorStorageReport(
            devices: deviceStorage.sorted { $0.totalBytes > $1.totalBytes },
            orphanedLogDirectories: orphanedLogDirectories(knownDeviceIDs: Set(devices.map(\.id))),
            sharedBytes: paths.sharedRoots.reduce(0) { $0 + Self.directorySize(at: $1) },
            // Taken from simctl: runtimes live under /Library and /System, outside
            // any tree this scanner walks, and are often root-owned.
            runtimeBytes: inventory.runtimes.compactMap(\.sizeBytes).reduce(0, +)
        )
    }

    /// Log directories with no corresponding device.
    ///
    /// Reported only. There is no simctl command that removes these, and this app
    /// does not delete simulator data outside simctl, so they are shown as an
    /// explanation of disk usage rather than as an offer to reclaim it.
    private func orphanedLogDirectories(
        knownDeviceIDs: Set<UUID>
    ) -> [SimulatorStorageReport.OrphanedLogDirectory] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: paths.logsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        )) ?? []

        return contents.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  !knownDeviceIDs.contains(id) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return SimulatorStorageReport.OrphanedLogDirectory(
                id: id,
                path: url,
                sizeBytes: Self.directorySize(at: url),
                modifiedAt: values?.contentModificationDate
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Total allocated size beneath a directory.
    ///
    /// Uses allocated rather than logical size, because allocated is what the
    /// volume actually gives back. Both remain estimates: APFS clones let files
    /// share blocks, so deleting a target can free less than its measured size.
    /// Unreadable entries are skipped rather than failing the scan — a root-owned
    /// or in-flight file should not cost the user their whole report.
    static func directorySize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
