import Foundation

/// Wire types mirroring `simctl`'s JSON exactly.
///
/// These are deliberately separate from the domain models. simctl's shape varies
/// across Xcode releases and splits the same concept across two commands; keeping
/// the wire format quarantined here means those quirks are handled in one place
/// and never leak into the rest of the app.
///
/// Every optional below is optional because simctl genuinely omits it in some
/// state — not defensively. Notably `lastBootedAt` is absent (not null) on a
/// device that has never been booted, which is what makes its absence meaningful.
enum SimctlDTO {

    // MARK: - simctl list devices --json

    struct DeviceList: Decodable {
        /// Keyed by runtime identifier. The key survives even when the runtime
        /// itself is gone, which is how unavailable devices remain attributable.
        let devices: [String: [Device]]
    }

    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let deviceTypeIdentifier: String?
        let isAvailable: Bool?
        let availabilityError: String?
        let lastBootedAt: String?
        let dataPath: String?
        let dataPathSize: Int64?
        let logPath: String?
        let logPathSize: Int64?
    }

    // MARK: - simctl list runtimes --json

    struct RuntimeList: Decodable {
        let runtimes: [Runtime]
    }

    struct Runtime: Decodable {
        let identifier: String
        let name: String?
        let version: String?
        let buildversion: String?
        let platform: String?
        let isAvailable: Bool?
        let availabilityError: String?
        /// Per-architecture timestamps, e.g. `{"arm64": "2026-09-11T18:36:50Z"}`.
        let lastUsage: [String: String]?
        let supportedDeviceTypes: [DeviceType]?
    }

    struct DeviceType: Decodable {
        let identifier: String
        let name: String?
        let productFamily: String?
    }

    // MARK: - simctl runtime list --json

    /// A runtime disk image. This command returns a bare dictionary keyed by
    /// image UUID, with no wrapper object, so it decodes as `[String: RuntimeImage]`.
    struct RuntimeImage: Decodable {
        let identifier: String
        let runtimeIdentifier: String
        let version: String?
        let build: String?
        let state: String?
        let deletable: Bool?
        let sizeBytes: Int64?
        let kind: String?
        let lastUsedAt: String?
        let mountPath: String?
    }

    // MARK: - simctl list pairs --json

    struct PairList: Decodable {
        let pairs: [String: Pair]
    }

    struct Pair: Decodable {
        let watch: PairMember
        let phone: PairMember
        let state: String?
    }

    struct PairMember: Decodable {
        let udid: String
        let name: String
        let state: String?
    }
}
