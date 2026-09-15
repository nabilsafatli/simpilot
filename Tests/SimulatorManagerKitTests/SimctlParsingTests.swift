import Foundation
import Testing
@testable import SimulatorManagerKit

@Suite("simctl device parsing")
struct DeviceParsingTests {

    @Test("Parses the real captured device list")
    func parsesRealCapture() throws {
        let outcome = try SimctlParser.parseDevices(Fixture.data("devices"))

        #expect(outcome.items.count == 11)
        #expect(outcome.issues.isEmpty)
        #expect(outcome.items.allSatisfy { $0.isAvailable })
        #expect(outcome.items.allSatisfy {
            $0.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
        })
    }

    /// The Phase 0 finding that changed Rule B: boot history is reported, so
    /// "never booted" is an observation rather than a filesystem-mtime guess.
    @Test("lastBootedAt is absent on never-booted devices and parsed when present")
    func distinguishesNeverBootedFromBooted() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("devices")).items

        let booted = devices.filter(\.hasEverBooted)
        let neverBooted = devices.filter { !$0.hasEverBooted }

        #expect(booted.count == 2)
        #expect(neverBooted.count == 9)

        let pro = try #require(devices.first { $0.name == "iPhone 17 Pro" })
        let expected = try Date.ISO8601FormatStyle().parse("2026-09-07T05:46:17Z")
        #expect(pro.lastBootedAt == expected)

        let air = try #require(devices.first { $0.name == "iPhone Air" })
        #expect(air.lastBootedAt == nil)
    }

    @Test("Unavailable devices are detected and keep their runtime attribution")
    func detectsUnavailableDevices() throws {
        let outcome = try SimctlParser.parseDevices(Fixture.data("unavailable-runtime"))

        let unavailable = outcome.items.filter { !$0.isAvailable }
        #expect(unavailable.count == 3)
        #expect(outcome.issues.isEmpty)

        // The runtime identifier survives even though the runtime is gone; this
        // is what lets the UI say *which* missing runtime stranded the device.
        let stranded = try #require(unavailable.first { $0.name == "iPhone 14 Pro" })
        #expect(stranded.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
        #expect(stranded.availabilityError != nil)

        // Devices on a still-installed runtime are unaffected.
        #expect(outcome.items.filter(\.isAvailable).count == 1)
    }

    /// Rule A must key off `isAvailable`, which was verified present in real
    /// captures, never off the error string, whose wording was not.
    @Test("Availability is decided by isAvailable, not by the error string")
    func availabilityIgnoresErrorStringWording() throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[
          {"udid":"A1111111-1111-4111-8111-111111111111","name":"No Error String",
           "state":"Shutdown","isAvailable":false,
           "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-14"}
        ]}}
        """.data(using: .utf8)!

        let device = try #require(try SimctlParser.parseDevices(json).items.first)
        #expect(device.isAvailable == false)
        #expect(device.availabilityError == nil)
    }

    @Test("A missing isAvailable field does not invent an unavailable device")
    func missingAvailabilityDefaultsToAvailable() throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"udid":"B1111111-1111-4111-8111-111111111111","name":"Old Xcode Shape",
           "state":"Shutdown",
           "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}
        ]}}
        """.data(using: .utf8)!

        let device = try #require(try SimctlParser.parseDevices(json).items.first)
        #expect(device.isAvailable)
    }

    @Test("A malformed device is reported as an issue, not silently dropped")
    func reportsMalformedDevicesRatherThanHidingThem() throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"udid":"not-a-uuid","name":"Broken","state":"Shutdown",
           "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
          {"udid":"B1111111-1111-4111-8111-111111111111","name":"Fine","state":"Shutdown",
           "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}
        ]}}
        """.data(using: .utf8)!

        let outcome = try SimctlParser.parseDevices(json)
        #expect(outcome.items.count == 1)
        #expect(outcome.issues.count == 1)
        #expect(outcome.issues.first?.kind == .malformedDeviceIdentifier)
        #expect(outcome.issues.first?.rawIdentifier == "not-a-uuid")
    }

    @Test("A machine with no devices parses to an empty inventory, not an error")
    func handlesEmptyInventory() throws {
        let outcome = try SimctlParser.parseDevices(Fixture.data("empty-devices"))
        #expect(outcome.items.isEmpty)
        #expect(outcome.issues.isEmpty)
    }

    @Test("Running devices are distinguishable, and unknown states count as active")
    func treatsUnknownStatesAsActive() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("large-unused-device")).items
        let booted = try #require(devices.first { $0.state == .booted })
        #expect(booted.state.isActive)

        #expect(SimulatorState(rawValue: "Some Future State").isActive)
        #expect(SimulatorState(rawValue: "Shutdown").isActive == false)
    }

    @Test("The reported data path size is retained but never mistaken for measured")
    func retainsReportedSizeSeparately() throws {
        let devices = try SimctlParser.parseDevices(Fixture.data("devices")).items
        let pro = try #require(devices.first { $0.name == "iPhone 17 Pro" })
        // Phase 0 measured this device at 2.829 GB; simctl reports 2.527 GB.
        #expect(pro.reportedDataPathSize == 2_526_879_744)
    }
}
