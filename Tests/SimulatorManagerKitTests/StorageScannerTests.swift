import Foundation
import Testing
@testable import SimulatorManagerKit

/// Builds a throwaway copy of the CoreSimulator layout Phase 0 observed, so the
/// scanner is tested against real filesystem behaviour without depending on the
/// simulator state of whatever machine is running the tests.
struct ScratchLayout {
    let root: URL
    let paths: SimulatorPaths

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simpilot-tests-\(UUID().uuidString)")
        paths = SimulatorPaths(
            coreSimulatorRoot: root.appendingPathComponent("Library/Developer/CoreSimulator"),
            logsRoot: root.appendingPathComponent("Library/Logs/CoreSimulator")
        )
        try FileManager.default.createDirectory(at: paths.devicesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func makeDevice(id: UUID, dataBytes: Int, siblingBytes: Int = 0, logBytes: Int = 0) throws -> UUID {
        let directory = paths.deviceDirectory(forDeviceID: id)
        try write(bytes: dataBytes, to: directory.appendingPathComponent("data/Library/store.db"))
        if siblingBytes > 0 {
            // CoreSimulator writes directories next to `data/`, inside the device
            // directory. Phase 0 saw `datacom.apple.modelcatalog` here.
            try write(bytes: siblingBytes,
                      to: directory.appendingPathComponent("datacom.apple.modelcatalog/blob.bin"))
        }
        if logBytes > 0 {
            try write(bytes: logBytes,
                      to: paths.logDirectory(forDeviceID: id).appendingPathComponent("system.log"))
        }
        return id
    }

    func makeOrphanedLog(id: UUID, bytes: Int) throws {
        try write(bytes: bytes, to: paths.logDirectory(forDeviceID: id).appendingPathComponent("old.log"))
    }

    func makeDeviceSetFile() throws {
        try write(bytes: 4096, to: paths.devicesRoot
            .appendingPathComponent(SimulatorPaths.deviceSetFileName))
    }

    func makeSharedStorage(cacheBytes: Int, tempBytes: Int) throws {
        try write(bytes: cacheBytes, to: paths.cachesRoot.appendingPathComponent("cache.bin"))
        try write(bytes: tempBytes, to: paths.tempRoot.appendingPathComponent("scratch.bin"))
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }
}

private func device(id: UUID, name: String, reportedSize: Int64? = nil) -> SimulatorDevice {
    SimulatorDevice(
        id: id, name: name,
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        state: .shutdown,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        isAvailable: true,
        dataPath: URL(fileURLWithPath: "/unused"),
        reportedDataPathSize: reportedSize,
        logPath: URL(fileURLWithPath: "/unused")
    )
}

@Suite("Storage scanning")
struct StorageScannerTests {

    @Test("Measures each device independently")
    func measuresPerDevice() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let big = UUID(), small = UUID()
        try layout.makeDevice(id: big, dataBytes: 300_000)
        try layout.makeDevice(id: small, dataBytes: 10_000)

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(
                devices: [device(id: big, name: "Big"), device(id: small, name: "Small")],
                runtimes: []
            )
        )

        let bigStorage = try #require(report.storage(forDevice: big))
        let smallStorage = try #require(report.storage(forDevice: small))
        #expect(bigStorage.totalBytes > smallStorage.totalBytes)
        #expect(bigStorage.totalBytes >= 300_000)
        // Sorted largest first, which is the order the Devices screen wants.
        #expect(report.devices.first?.id == big)
    }

    /// Phase 0 found `datacom.apple.modelcatalog` sitting beside `data/`. Sizing
    /// only `data/` would undercount the device.
    @Test("Counts sibling directories inside the device directory")
    func countsSiblingsBesideData() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let id = UUID()
        try layout.makeDevice(id: id, dataBytes: 100_000, siblingBytes: 50_000)

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [device(id: id, name: "Sibling")], runtimes: [])
        )

        let storage = try #require(report.storage(forDevice: id))
        #expect(storage.totalBytes >= 150_000)
    }

    @Test("Logs are measured but kept separate from device storage")
    func separatesLogsFromDeviceStorage() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let id = UUID()
        try layout.makeDevice(id: id, dataBytes: 100_000, logBytes: 20_000)

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [device(id: id, name: "Logged")], runtimes: [])
        )

        let storage = try #require(report.storage(forDevice: id))
        #expect(storage.logBytes >= 20_000)
        #expect(storage.totalBytes >= 100_000)
        #expect(storage.totalBytes < 120_000, "log bytes must not be folded into device storage")
    }

    /// 22 of 24 log directories on the Phase 0 machine had no live device.
    @Test("Finds log directories with no corresponding device")
    func findsOrphanedLogs() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let live = UUID()
        try layout.makeDevice(id: live, dataBytes: 1_000, logBytes: 5_000)
        try layout.makeOrphanedLog(id: UUID(), bytes: 30_000)
        try layout.makeOrphanedLog(id: UUID(), bytes: 70_000)

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [device(id: live, name: "Live")], runtimes: [])
        )

        #expect(report.orphanedLogDirectories.count == 2)
        #expect(report.orphanedLogBytes >= 100_000)
        // The live device's own log is never counted as orphaned.
        #expect(!report.orphanedLogDirectories.contains { $0.id == live })
        #expect(report.orphanedLogDirectories.first?.sizeBytes ?? 0 >= 70_000)
    }

    @Test("device_set.plist is not mistaken for a device")
    func ignoresDeviceSetFile() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let id = UUID()
        try layout.makeDevice(id: id, dataBytes: 50_000)
        try layout.makeDeviceSetFile()

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [device(id: id, name: "Only")], runtimes: [])
        )

        #expect(report.devices.count == 1)
        #expect(report.devices.first?.id == id)
    }

    @Test("Shared caches are never attributed to a device")
    func keepsSharedStorageSeparate() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let id = UUID()
        try layout.makeDevice(id: id, dataBytes: 10_000)
        try layout.makeSharedStorage(cacheBytes: 40_000, tempBytes: 25_000)

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [device(id: id, name: "Device")], runtimes: [])
        )

        #expect(report.sharedBytes >= 65_000)
        let storage = try #require(report.storage(forDevice: id))
        #expect(storage.totalBytes < 40_000)
    }

    /// Runtimes live under /Library and /System, outside any tree this scanner
    /// walks, so their size comes from simctl.
    @Test("Runtime bytes come from the inventory, not the filesystem walk")
    func takesRuntimeSizeFromInventory() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let runtime = SimulatorRuntime(
            id: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            name: "iOS 26.5", version: "26.5", build: "23F77",
            platform: .iOS, isAvailable: true,
            sizeBytes: 8_494_282_293, isDeletable: true
        )

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [], runtimes: [runtime])
        )

        #expect(report.runtimeBytes == 8_494_282_293)
        #expect(report.deviceBytes == 0)
        #expect(report.totalBytes == 8_494_282_293)
    }

    @Test("simctl's cached size is retained alongside the measured one")
    func retainsReportedSizeForComparison() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let id = UUID()
        try layout.makeDevice(id: id, dataBytes: 200_000)

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(
                devices: [device(id: id, name: "Drifted", reportedSize: 123_456)],
                runtimes: []
            )
        )

        let storage = try #require(report.storage(forDevice: id))
        #expect(storage.reportedBytes == 123_456)
        #expect(storage.totalBytes != storage.reportedBytes)
    }

    @Test("Reports progress as devices complete")
    func reportsProgress() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let ids = (0..<5).map { _ in UUID() }
        for id in ids { try layout.makeDevice(id: id, dataBytes: 1_000) }

        let recorder = ProgressRecorder()
        let scanner = FileSystemStorageScanner(paths: layout.paths) { progress in
            recorder.record(progress)
        }
        _ = try await scanner.scan(inventory: SimulatorInventory(
            devices: ids.map { device(id: $0, name: "D") }, runtimes: []
        ))

        #expect(recorder.updates.count == 5)
        #expect(recorder.updates.last?.fractionCompleted == 1.0)
        #expect(recorder.updates.last?.totalDevices == 5)
    }

    @Test("A missing directory yields zero rather than failing the scan")
    func toleratesMissingDirectories() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        // A device present in simctl's listing whose directory does not exist.
        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [device(id: UUID(), name: "Ghost")], runtimes: [])
        )

        #expect(report.devices.count == 1)
        #expect(report.devices.first?.totalBytes == 0)
    }

    @Test("An empty machine scans to an honest zero")
    func handlesEmptyMachine() async throws {
        let layout = try ScratchLayout()
        defer { layout.cleanUp() }

        let report = try await FileSystemStorageScanner(paths: layout.paths).scan(
            inventory: SimulatorInventory(devices: [], runtimes: [])
        )

        #expect(report.totalBytes == 0)
        #expect(report.devices.isEmpty)
        #expect(report.orphanedLogDirectories.isEmpty)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanProgress] = []

    func record(_ progress: ScanProgress) {
        lock.lock(); defer { lock.unlock() }
        storage.append(progress)
    }

    var updates: [ScanProgress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
