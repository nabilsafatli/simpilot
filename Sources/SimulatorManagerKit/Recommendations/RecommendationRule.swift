import Foundation

/// Everything a rule is allowed to look at.
///
/// Rules receive a snapshot and return recommendations. They cannot run commands,
/// touch the filesystem, or call a model — the engine is deterministic, so the
/// same inventory always yields the same advice, and any recommendation can be
/// reproduced from a fixture.
public struct RecommendationContext: Sendable {
    public let inventory: SimulatorInventory
    public let report: SimulatorStorageReport?
    /// Injected rather than read from the clock, so staleness tests are not
    /// dated by the day they run.
    public let now: Date

    public init(inventory: SimulatorInventory, report: SimulatorStorageReport?, now: Date = Date()) {
        self.inventory = inventory
        self.report = report
        self.now = now
    }

    /// Measured size of a device, or nil when no scan has completed.
    ///
    /// Nil is not zero. A rule that treated an unmeasured device as empty would
    /// under-report what a deletion recovers.
    public func measuredBytes(forDevice id: UUID) -> Int64? {
        report?.storage(forDevice: id)?.totalBytes
    }

    public func runtime(_ identifier: String) -> SimulatorRuntime? {
        inventory.runtimes.first { $0.id == identifier }
    }

    /// Whether a device's runtime is installed and usable.
    public func runtimeIsInstalled(_ identifier: String) -> Bool {
        inventory.installedRuntimeIdentifiers.contains(identifier)
    }

    public func days(since date: Date?) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: now).day
    }

    // MARK: - Shared caution construction
    //
    // Every rule that proposes touching a device must surface the same hazards,
    // so they are built here rather than repeated (and eventually forgotten) in
    // each rule.

    public func cautions(forDevice device: SimulatorDevice) -> [RecommendationCaution] {
        var cautions: [RecommendationCaution] = []

        if device.state.isActive {
            cautions.append(RecommendationCaution(
                kind: .deviceIsRunning,
                summary: "This simulator is \(device.state.displayName.lowercased()). Quit it before making changes."
            ))
        }

        // Nothing in a device's own listing reveals that it is paired, so this is
        // the only place the user would learn what a deletion breaks.
        if let pair = inventory.pair(containing: device.id),
           let counterpart = pair.counterpart(of: device.id) {
            cautions.append(RecommendationCaution(
                kind: .breaksPairing,
                summary: "Paired with \(counterpart.name). Deleting this device breaks the pairing."
            ))
        }

        if measuredBytes(forDevice: device.id) == nil {
            cautions.append(RecommendationCaution(
                kind: .sizeNotMeasured,
                summary: "Disk usage has not been measured yet, so the space shown may be inaccurate."
            ))
        }

        return cautions
    }
}

/// One independently testable rule.
public protocol RecommendationRule: Sendable {
    /// Stable identifier used in tests and in the UI's explanation of provenance.
    var identifier: String { get }
    var title: String { get }
    func evaluate(_ context: RecommendationContext) -> [Recommendation]
}
