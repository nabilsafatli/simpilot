import Foundation

/// One line in the impact statement.
public struct ImpactItem: Hashable, Sendable, Identifiable {
    public let summary: String
    /// Why this is affected, or why it survives. Shown beneath the summary.
    public let detail: String?
    public let bytes: Int64?

    public var id: String { summary }

    public init(summary: String, detail: String? = nil, bytes: Int64? = nil) {
        self.summary = summary
        self.detail = detail
        self.bytes = bytes
    }
}

/// What an operation removes and, just as importantly, what it leaves alone.
///
/// The "will not" column is derived here rather than written per screen, so it
/// cannot drift from what the commands actually do, and so every screen makes the
/// same promises. Several entries encode findings from Phase 0 — notably that
/// `simctl delete` leaves the device's log directory behind, which is why 22 of
/// 24 log folders on the development machine belonged to devices that no longer
/// existed.
public struct CleanupImpact: Hashable, Sendable {
    public let willRemove: [ImpactItem]
    public let willKeep: [ImpactItem]

    public init(willRemove: [ImpactItem], willKeep: [ImpactItem]) {
        self.willRemove = willRemove
        self.willKeep = willKeep
    }

    public static func forAction(
        _ action: CleanupAction,
        inventory: SimulatorInventory,
        report: SimulatorStorageReport?
    ) -> CleanupImpact {
        switch action {
        case .deleteDevice(let id, let name):
            deleteDevice(id: id, name: name, inventory: inventory, report: report)
        case .eraseDevice(let id, let name):
            eraseDevice(id: id, name: name, inventory: inventory, report: report)
        case .deleteRuntime(let imageUUID, let name):
            deleteRuntime(imageUUID: imageUUID, name: name, inventory: inventory, report: report)
        case .deleteUnavailableDevices:
            deleteUnavailable(inventory: inventory, report: report)
        }
    }

    // MARK: - Per action

    private static func deleteDevice(
        id: UUID, name: String,
        inventory: SimulatorInventory,
        report: SimulatorStorageReport?
    ) -> CleanupImpact {
        let storage = report?.storage(forDevice: id)
        let device = inventory.devices.first { $0.id == id }

        var willRemove = [
            ImpactItem(
                summary: "The simulator “\(name)”",
                detail: "Its identifier \(id.uuidString) is released and cannot be recovered.",
                bytes: storage?.totalBytes
            ),
            ImpactItem(
                summary: "Everything installed on it",
                detail: "Apps, their data, settings, keychain entries and any seeded test state."
            )
        ]

        var willKeep = [
            ImpactItem(
                summary: "The runtime it used",
                detail: device.flatMap { d in inventory.runtimes.first { $0.id == d.runtimeIdentifier }?.name }
                    ?? "The simulator runtime remains installed for other devices."
            ),
            ImpactItem(summary: "Every other simulator", detail: "Only the device named above is removed."),
            ImpactItem(summary: "Xcode, your projects and source code", detail: "Simpilot never touches anything outside the simulator directories."),
            ImpactItem(summary: "DerivedData and build caches", detail: "Out of scope for this app entirely.")
        ]

        // Verified in Phase 0: log folders outlive the devices they belong to.
        if let logBytes = storage?.logBytes, logBytes > 0 {
            willKeep.append(ImpactItem(
                summary: "Its log folder",
                detail: "simctl leaves ~/Library/Logs/CoreSimulator/\(id.uuidString) in place. Simpilot will report it afterwards as an orphaned log folder.",
                bytes: logBytes
            ))
        }

        if let pair = inventory.pair(containing: id), let other = pair.counterpart(of: id) {
            willRemove.append(ImpactItem(
                summary: "Its pairing with \(other.name)",
                detail: "The pairing is broken. \(other.name) itself is not deleted."
            ))
            willKeep.append(ImpactItem(summary: other.name, detail: "The paired device survives, but is no longer paired."))
        }

        return CleanupImpact(willRemove: willRemove, willKeep: willKeep)
    }

    private static func eraseDevice(
        id: UUID, name: String,
        inventory: SimulatorInventory,
        report: SimulatorStorageReport?
    ) -> CleanupImpact {
        let storage = report?.storage(forDevice: id)
        // A freshly created device measured 18,337,792 bytes on the Phase 0
        // machine, and identically across all nine never-booted devices.
        let baseline: Int64 = 18_337_792
        let recoverable = storage.map { max($0.totalBytes - baseline, 0) }

        return CleanupImpact(
            willRemove: [
                ImpactItem(
                    summary: "All apps and data on “\(name)”",
                    detail: "Installed apps, their databases and caches, photos, settings, keychain entries and logins.",
                    bytes: recoverable
                ),
                ImpactItem(
                    summary: "Any state you seeded manually",
                    detail: "Test accounts, downloaded content and anything not reproducible from a build are lost."
                )
            ],
            willKeep: [
                ImpactItem(
                    summary: "The simulator “\(name)” itself",
                    detail: "It keeps its name and its identifier \(id.uuidString). Schemes and scripts referring to it keep working."
                ),
                ImpactItem(summary: "Its runtime and device type", detail: "The device is reset to a clean state, not removed."),
                ImpactItem(summary: "Every other simulator"),
                ImpactItem(summary: "Xcode, your projects and source code")
            ]
        )
    }

    private static func deleteRuntime(
        imageUUID: UUID, name: String,
        inventory: SimulatorInventory,
        report: SimulatorStorageReport?
    ) -> CleanupImpact {
        let runtime = inventory.runtimes.first { $0.imageUUID == imageUUID }
        let dependents = runtime.map { inventory.devices(forRuntime: $0.id) } ?? []

        var willRemove = [
            ImpactItem(
                summary: "The \(name) runtime",
                detail: "Its disk image is removed from the secure storage area. Reinstalling it means downloading it again.",
                bytes: runtime?.sizeBytes
            )
        ]

        var willKeep: [ImpactItem] = [
            ImpactItem(summary: "Every other runtime"),
            ImpactItem(summary: "Xcode itself", detail: "Removing a runtime does not modify your Xcode installation."),
            ImpactItem(summary: "Your projects and source code")
        ]

        if dependents.isEmpty {
            willKeep.append(ImpactItem(summary: "All of your simulators", detail: "No device uses this runtime."))
        } else {
            // Devices are not deleted — they become unavailable, which is a
            // materially different outcome and must not be described as removal.
            willKeep.append(ImpactItem(
                summary: "\(dependents.count) device\(dependents.count == 1 ? "" : "s") that use this runtime",
                detail: "\(dependents.map(\.name).sorted().joined(separator: ", ")). These are NOT deleted, but they become unavailable and cannot boot until the runtime is reinstalled."
            ))
            willRemove.append(ImpactItem(
                summary: "The ability to boot \(dependents.count) device\(dependents.count == 1 ? "" : "s")",
                detail: "They remain on disk and keep their data."
            ))
        }

        return CleanupImpact(willRemove: willRemove, willKeep: willKeep)
    }

    private static func deleteUnavailable(
        inventory: SimulatorInventory,
        report: SimulatorStorageReport?
    ) -> CleanupImpact {
        let unavailable = inventory.devices.filter { !$0.isAvailable }
        let bytes = unavailable.compactMap { report?.storage(forDevice: $0.id)?.totalBytes }.reduce(0, +)

        return CleanupImpact(
            willRemove: [
                ImpactItem(
                    summary: "\(unavailable.count) device\(unavailable.count == 1 ? "" : "s") whose runtime is missing",
                    detail: unavailable.isEmpty
                        ? "Nothing matches; simctl will make no changes."
                        : unavailable.map(\.name).sorted().joined(separator: ", "),
                    bytes: bytes > 0 ? bytes : nil
                ),
                ImpactItem(summary: "The data on those devices", detail: "Apps and state they held are removed with them.")
            ],
            willKeep: [
                ImpactItem(
                    summary: "Every device whose runtime is installed",
                    detail: "simctl matches only on availability; working simulators are untouched."
                ),
                ImpactItem(summary: "All installed runtimes"),
                ImpactItem(summary: "Xcode, your projects and source code")
            ]
        )
    }
}
