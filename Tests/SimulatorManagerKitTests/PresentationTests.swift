import Foundation
import Testing
@testable import SimulatorManagerKit

@Suite("Device list sorting and filtering")
struct DeviceListTests {

    private func rows() throws -> [DeviceRow] {
        let inventory = SimulatorInventory(
            devices: try SimctlParser.parseDevices(Fixture.data("devices")).items,
            runtimes: try SimctlParser.parseRuntimes(
                runtimesData: Fixture.data("runtimes"),
                runtimeImagesData: Fixture.data("runtime-list")
            )
        )
        // Measured sizes stand in for a completed scan.
        let storage = inventory.devices.map {
            SimulatorStorageReport.DeviceStorage(
                id: $0.id,
                totalBytes: $0.reportedDataPathSize ?? 0,
                logBytes: 0,
                reportedBytes: $0.reportedDataPathSize
            )
        }
        return DeviceRow.rows(
            inventory: inventory,
            report: SimulatorStorageReport(devices: storage)
        )
    }

    @Test("Sorting by size puts the largest device first")
    func sortsBySize() throws {
        let sorted = try rows().applying(filter: .all, sort: .size)
        #expect(sorted.first?.device.name == "iPhone 17")
        #expect((sorted.first?.measuredBytes ?? 0) > (sorted.last?.measuredBytes ?? 0))
    }

    /// A device whose size is not yet measured must not masquerade as empty.
    @Test("Unmeasured devices sort last rather than as zero bytes")
    func unmeasuredDevicesSortLast() throws {
        let inventory = SimulatorInventory(
            devices: try SimctlParser.parseDevices(Fixture.data("devices")).items,
            runtimes: []
        )
        // No report at all: nothing has been measured.
        let sorted = DeviceRow.rows(inventory: inventory, report: nil)
            .applying(filter: .all, sort: .size)

        #expect(sorted.allSatisfy { $0.measuredBytes == nil })
        #expect(sorted.count == 11)
    }

    @Test("Never-booted devices sort last when ordering by last used")
    func neverBootedSortLastByDate() throws {
        let sorted = try rows().applying(filter: .all, sort: .lastUsed)
        #expect(sorted.first?.device.hasEverBooted == true)
        #expect(sorted.last?.device.hasEverBooted == false)
        // The two booted devices lead, most recent first.
        #expect(sorted[0].device.name == "iPhone 17 Pro")
        #expect(sorted[1].device.name == "iPhone 17")
    }

    @Test("Sorting by name is stable and natural")
    func sortsByName() throws {
        let sorted = try rows().applying(filter: .all, sort: .name)
        let names = sorted.map(\.device.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test("The never-booted filter matches exactly the devices with no boot record")
    func filtersNeverBooted() throws {
        let filtered = try rows().applying(filter: .neverBooted, sort: .name)
        #expect(filtered.count == 9)
        #expect(filtered.allSatisfy { !$0.hasEverBooted })
    }

    @Test("The large filter uses measured size against the threshold")
    func filtersLarge() throws {
        // This machine's biggest device is 4.38 GB, under the 5 GB threshold, so
        // the real capture is the case where nothing is large.
        #expect(try rows().applying(filter: .large, sort: .size).isEmpty)

        // The fixture built for Rule C has two devices well past the threshold.
        let inventory = SimulatorInventory(
            devices: try SimctlParser.parseDevices(Fixture.data("large-unused-device")).items,
            runtimes: []
        )
        let report = SimulatorStorageReport(devices: inventory.devices.map {
            .init(id: $0.id, totalBytes: $0.reportedDataPathSize ?? 0, logBytes: 0)
        })
        let large = DeviceRow.rows(inventory: inventory, report: report)
            .applying(filter: .large, sort: .size)

        #expect(large.count == 2)
        #expect(large.allSatisfy { ($0.measuredBytes ?? 0) >= DeviceFilter.largeThreshold })
        // Size alone is never a reason to act: the largest here is actively used.
        #expect(large.first?.device.name.contains("large never booted") == true)
        #expect(large.contains { $0.device.state == .booted })
    }

    @Test("The unavailable filter finds stranded devices")
    func filtersUnavailable() throws {
        let inventory = SimulatorInventory(
            devices: try SimctlParser.parseDevices(Fixture.data("unavailable-runtime")).items,
            runtimes: []
        )
        let filtered = DeviceRow.rows(inventory: inventory, report: nil)
            .applying(filter: .unavailable, sort: .name)
        #expect(filtered.count == 3)
        #expect(filtered.allSatisfy { $0.isStranded })
    }

    @Test("The paired filter finds devices whose deletion would break a pair")
    func filtersPaired() throws {
        let inventory = SimulatorInventory(
            devices: try SimctlParser.parseDevices(Fixture.data("duplicate-devices")).items,
            runtimes: [],
            pairs: try SimctlParser.parsePairs(Fixture.data("pairs")).items
        )
        let filtered = DeviceRow.rows(inventory: inventory, report: nil)
            .applying(filter: .paired, sort: .name)
        #expect(filtered.count == 1)
        #expect(filtered.first?.pair?.watch.name == "Apple Watch Series 10 (46mm)")
    }

    @Test("Search matches name, runtime and UDID")
    func searchesAcrossFields() throws {
        let all = try rows()
        #expect(all.applying(filter: .all, sort: .name, searchText: "iPad").count == 6)
        #expect(all.applying(filter: .all, sort: .name, searchText: "iOS 26.5").count == 11)

        let udid = try #require(all.first?.device.id.uuidString)
        #expect(all.applying(filter: .all, sort: .name, searchText: udid).count == 1)
    }

    @Test("Every filter explains its own criterion")
    func filtersExplainThemselves() {
        for filter in DeviceFilter.allCases {
            #expect(!filter.explanation.isEmpty)
            #expect(!filter.displayName.isEmpty)
        }
    }

    /// Recommendations do not exist yet; offering a filter that matched nothing
    /// would imply the inventory had been reviewed.
    @Test("There is no recommendation filter before the engine exists")
    func noRecommendationFilterYet() {
        #expect(!DeviceFilter.allCases.contains { $0.displayName.localizedCaseInsensitiveContains("recommend") })
    }
}

@Suite("Dashboard summary")
struct DashboardSummaryTests {

    @Test("Counts what simctl directly reports")
    func countsObservableFacts() throws {
        let inventory = SimulatorInventory(
            devices: try SimctlParser.parseDevices(Fixture.data("devices")).items,
            runtimes: try SimctlParser.parseRuntimes(
                runtimesData: Fixture.data("runtimes"),
                runtimeImagesData: Fixture.data("runtime-list")
            )
        )
        let summary = DashboardSummary(inventory: inventory, report: nil)

        #expect(summary.deviceCount == 11)
        #expect(summary.runtimeCount == 1)
        #expect(summary.platformCount == 1)
        #expect(summary.neverBootedCount == 9)
        #expect(summary.unavailableDeviceCount == 0)
        #expect(summary.runningCount == 0)
    }

    /// Runtime sizes come from simctl, so they are known before any walk.
    @Test("Runtime bytes are known before a scan completes")
    func runtimeBytesNeedNoScan() throws {
        let inventory = SimulatorInventory(
            devices: [],
            runtimes: try SimctlParser.parseRuntimes(
                runtimesData: Fixture.data("runtimes"),
                runtimeImagesData: Fixture.data("runtime-list")
            )
        )
        let summary = DashboardSummary(inventory: inventory, report: nil)

        #expect(summary.runtimeBytes == 8_494_282_293)
        #expect(summary.isMeasured == false)
        #expect(summary.deviceBytes == 0)
    }

    @Test("A completed scan marks the summary as measured")
    func marksMeasuredAfterScan() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("devices")).items
        let report = SimulatorStorageReport(
            devices: devices.map {
                .init(id: $0.id, totalBytes: 1_000, logBytes: 10)
            },
            sharedBytes: 500
        )
        let summary = DashboardSummary(
            inventory: SimulatorInventory(devices: devices, runtimes: []),
            report: report
        )

        #expect(summary.isMeasured)
        #expect(summary.deviceBytes == 11_000)
        #expect(summary.logBytes == 110)
        #expect(summary.sharedBytes == 500)
    }

    @Test("Multiple platforms are counted distinctly")
    func countsPlatforms() throws {
        let inventory = SimulatorInventory(
            devices: [],
            runtimes: try SimctlParser.parseRuntimes(
                runtimesData: Fixture.data("multi-platform-runtimes"),
                runtimeImagesData: Fixture.data("multi-runtime-list")
            )
        )
        let summary = DashboardSummary(inventory: inventory, report: nil)
        #expect(summary.runtimeCount == 7)
        #expect(summary.platformCount == 4)
    }
}
