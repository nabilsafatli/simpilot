import Foundation

/// An installed simulator runtime.
///
/// This type is assembled from **two different simctl commands**, because neither
/// alone is sufficient:
///
/// - `simctl list runtimes --json` supplies identity, version and availability,
///   but no UUID — so it cannot address a runtime for deletion.
/// - `simctl runtime list --json` is keyed by UUID and supplies `sizeBytes` and
///   `deletable`, but only covers runtimes held as disk images.
///
/// The two are joined on ``id`` (the runtime identifier). A runtime present only
/// in the first command — a runtime bundled with Xcode, for instance — has a nil
/// ``imageUUID`` and is not deletable.
public struct SimulatorRuntime: Identifiable, Hashable, Sendable {
    /// The runtime identifier, e.g. `com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
    /// Always present; this is the key devices reference.
    public let id: String

    public let name: String
    public let version: String
    public let build: String
    public let platform: Platform
    public let isAvailable: Bool
    public let availabilityError: String?

    /// Last recorded use, collapsed from the per-architecture `lastUsage` map
    /// to its most recent entry.
    public let lastUsedAt: Date?

    /// Device types this runtime can host, used to reason about coverage.
    public let supportedDeviceTypeIdentifiers: [String]

    // MARK: - Joined from `simctl runtime list`

    /// The UUID required to delete this runtime. Nil when the runtime has no
    /// deletable disk image.
    public let imageUUID: UUID?

    /// Exact size from simctl. Runtimes live outside the scanned user directory
    /// (under `/Library/Developer/CoreSimulator/Volumes` and `/System/Library/AssetsV2`),
    /// so this is taken from simctl rather than measured.
    ///
    /// Still an estimate of *recoverable* space: simctl clones runtime images
    /// where it can, so deleting one may free less than this.
    public let sizeBytes: Int64?

    /// simctl's own `deletable` flag. Never inferred from age, size or version —
    /// a runtime may be undeletable for reasons none of those imply.
    public let isDeletable: Bool

    public init(
        id: String,
        name: String,
        version: String,
        build: String,
        platform: Platform,
        isAvailable: Bool,
        availabilityError: String? = nil,
        lastUsedAt: Date? = nil,
        supportedDeviceTypeIdentifiers: [String] = [],
        imageUUID: UUID? = nil,
        sizeBytes: Int64? = nil,
        isDeletable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.build = build
        self.platform = platform
        self.isAvailable = isAvailable
        self.availabilityError = availabilityError
        self.lastUsedAt = lastUsedAt
        self.supportedDeviceTypeIdentifiers = supportedDeviceTypeIdentifiers
        self.imageUUID = imageUUID
        self.sizeBytes = sizeBytes
        self.isDeletable = isDeletable
    }
}
