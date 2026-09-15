import Foundation

/// Turns simctl's JSON into domain models.
///
/// Pure and synchronous: it takes `Data` and returns models, with no process
/// execution and no filesystem access. That is what lets the whole correctness
/// story be proven against fixtures on a machine whose own simulator state
/// resembles nobody else's.
public enum SimctlParser {

    // MARK: - Devices

    /// Parses `xcrun simctl list devices --json`.
    ///
    /// The outer dictionary is keyed by runtime identifier, and that key is
    /// retained as the device's `runtimeIdentifier` even when the runtime is no
    /// longer installed — which is exactly the case Rule A depends on.
    public static func parseDevices(_ data: Data) throws -> ParseOutcome<SimulatorDevice> {
        let dto = try JSONDecoder().decode(SimctlDTO.DeviceList.self, from: data)
        var devices: [SimulatorDevice] = []
        var issues: [ParseIssue] = []

        for (runtimeIdentifier, entries) in dto.devices {
            for entry in entries {
                guard let uuid = UUID(uuidString: entry.udid) else {
                    issues.append(ParseIssue(
                        kind: .malformedDeviceIdentifier,
                        rawIdentifier: entry.udid,
                        detail: "Device '\(entry.name)' has a UDID that is not a valid UUID."
                    ))
                    continue
                }

                // Paths are derived from the UDID when simctl omits them, so a
                // device is never dropped merely for a missing convenience field.
                let dataPath = entry.dataPath.map { URL(fileURLWithPath: $0) }
                    ?? SimulatorPaths.defaultDataPath(forDeviceID: uuid)
                let logPath = entry.logPath.map { URL(fileURLWithPath: $0) }
                    ?? SimulatorPaths.defaultLogPath(forDeviceID: uuid)

                devices.append(SimulatorDevice(
                    id: uuid,
                    name: entry.name,
                    runtimeIdentifier: runtimeIdentifier,
                    state: SimulatorState(rawValue: entry.state),
                    deviceTypeIdentifier: entry.deviceTypeIdentifier ?? "",
                    // Absent `isAvailable` is treated as available: assuming a
                    // device is broken because a field is missing would invent a
                    // high-confidence delete recommendation out of nothing.
                    isAvailable: entry.isAvailable ?? true,
                    availabilityError: entry.availabilityError,
                    lastBootedAt: SimctlDate.parse(entry.lastBootedAt),
                    dataPath: dataPath,
                    reportedDataPathSize: entry.dataPathSize,
                    logPath: logPath,
                    reportedLogPathSize: entry.logPathSize
                ))
            }
        }

        return ParseOutcome(
            items: devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            issues: issues
        )
    }

    // MARK: - Runtimes

    /// Parses and joins the two runtime commands.
    ///
    /// - Parameters:
    ///   - runtimesData: output of `simctl list runtimes --json`, the authority
    ///     on which runtimes exist.
    ///   - runtimeImagesData: output of `simctl runtime list --json`, the only
    ///     source of deletion UUIDs and sizes. Optional, because it fails on
    ///     older Xcode versions that lack the subcommand — in which case every
    ///     runtime is simply reported as not deletable, which is safe.
    public static func parseRuntimes(
        runtimesData: Data,
        runtimeImagesData: Data? = nil
    ) throws -> [SimulatorRuntime] {
        let listed = try JSONDecoder().decode(SimctlDTO.RuntimeList.self, from: runtimesData)
        let images = try parseRuntimeImages(runtimeImagesData)

        return listed.runtimes.map { runtime in
            // Join on runtime identifier: the only field both commands share.
            let image = images[runtime.identifier]

            return SimulatorRuntime(
                id: runtime.identifier,
                name: runtime.name ?? runtime.identifier,
                version: runtime.version ?? image?.version ?? "",
                build: runtime.buildversion ?? image?.build ?? "",
                platform: Platform(
                    reportedPlatform: runtime.platform,
                    runtimeIdentifier: runtime.identifier
                ),
                isAvailable: runtime.isAvailable ?? true,
                availabilityError: runtime.availabilityError,
                // Prefer the per-arch map from `list runtimes`; fall back to the
                // flat timestamp the image command reports.
                lastUsedAt: SimctlDate.mostRecent(in: runtime.lastUsage)
                    ?? SimctlDate.parse(image?.lastUsedAt),
                supportedDeviceTypeIdentifiers: (runtime.supportedDeviceTypes ?? []).map(\.identifier),
                imageUUID: image.flatMap { UUID(uuidString: $0.identifier) },
                sizeBytes: image?.sizeBytes,
                // simctl's own flag, defaulting to false. A runtime with no disk
                // image has no deletion path, and guessing otherwise would offer
                // the user an action that cannot succeed.
                isDeletable: image?.deletable ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.platform.displayName != rhs.platform.displayName {
                return lhs.platform.displayName < rhs.platform.displayName
            }
            return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
        }
    }

    /// Decodes `simctl runtime list --json`, keyed by runtime identifier for joining.
    private static func parseRuntimeImages(_ data: Data?) throws -> [String: SimctlDTO.RuntimeImage] {
        guard let data, !data.isEmpty else { return [:] }
        // This command returns a bare UUID-keyed dictionary with no wrapper, so
        // an unrecognised sibling key must not discard the whole listing.
        let byUUID = try JSONDecoder()
            .decode(LenientDictionary<SimctlDTO.RuntimeImage>.self, from: data)
        return Dictionary(
            byUUID.values.values.map { ($0.runtimeIdentifier, $0) },
            // Two images can claim the same runtime identifier; keep the larger,
            // which is the one whose deletion the user would care about.
            uniquingKeysWith: { ($0.sizeBytes ?? 0) >= ($1.sizeBytes ?? 0) ? $0 : $1 }
        )
    }

    // MARK: - Pairs

    /// Parses `xcrun simctl list pairs --json`. An empty dictionary is the
    /// common case, not an error.
    public static func parsePairs(_ data: Data) throws -> ParseOutcome<DevicePair> {
        let dto = try JSONDecoder().decode(SimctlDTO.PairList.self, from: data)
        var pairs: [DevicePair] = []
        var issues: [ParseIssue] = []

        for (rawPairID, pair) in dto.pairs {
            guard let pairID = UUID(uuidString: rawPairID),
                  let watchID = UUID(uuidString: pair.watch.udid),
                  let phoneID = UUID(uuidString: pair.phone.udid) else {
                issues.append(ParseIssue(
                    kind: .malformedPairIdentifier,
                    rawIdentifier: rawPairID,
                    detail: "Pair could not be read; devices in it will not be flagged as paired."
                ))
                continue
            }

            pairs.append(DevicePair(
                id: pairID,
                watch: DevicePair.Member(
                    id: watchID,
                    name: pair.watch.name,
                    state: SimulatorState(rawValue: pair.watch.state ?? "")
                ),
                phone: DevicePair.Member(
                    id: phoneID,
                    name: pair.phone.name,
                    state: SimulatorState(rawValue: pair.phone.state ?? "")
                ),
                state: pair.state ?? ""
            ))
        }

        return ParseOutcome(items: pairs, issues: issues)
    }
}
