import Foundation

/// One confirmed operation, with everything needed to explain it beforehand.
///
/// Built from a snapshot, so the preview a user reads cannot shift underneath
/// them while they read it.
public struct CleanupOperation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let action: CleanupAction
    public let impact: CleanupImpact
    /// Estimated space this frees. An estimate in the strict sense: APFS clones
    /// share blocks, so the figure is only settled by the re-scan afterwards.
    public let estimatedBytes: Int64
    /// Hazards carried over from the recommendation that proposed this.
    public let cautions: [RecommendationCaution]

    public var command: SimctlCommand { action.command }

    public init(
        id: UUID = UUID(),
        action: CleanupAction,
        impact: CleanupImpact,
        estimatedBytes: Int64,
        cautions: [RecommendationCaution] = []
    ) {
        self.id = id
        self.action = action
        self.impact = impact
        self.estimatedBytes = estimatedBytes
        self.cautions = cautions
    }
}

/// A set of operations the user has assembled but not yet confirmed.
///
/// Holding this as a value is what makes the dry run real: building a plan runs
/// nothing, and the same value is what the confirmation screen displays and the
/// executor later receives. There is no path from "previewing" to "executing"
/// that does not pass through the user pressing a button.
public struct CleanupPlan: Sendable {
    public let operations: [CleanupOperation]
    public let builtAt: Date

    public var isEmpty: Bool { operations.isEmpty }
    public var estimatedRecoverableBytes: Int64 {
        operations.reduce(0) { $0 + $1.estimatedBytes }
    }
    public var commands: [SimctlCommand] { operations.map(\.command) }

    /// Every distinct hazard across the plan, so the confirmation screen can lead
    /// with them rather than burying them per row.
    public var cautions: [RecommendationCaution] {
        var seen = Set<String>()
        return operations.flatMap(\.cautions).filter { seen.insert($0.id).inserted }
    }

    public init(operations: [CleanupOperation], builtAt: Date = Date()) {
        self.operations = operations
        self.builtAt = builtAt
    }

    /// Builds a plan from recommendations the user selected.
    ///
    /// Review recommendations are silently unrepresentable — ``CleanupAction`` has
    /// no case for them — so a duplicate group or a runtime review cannot become a
    /// pending deletion even if passed in by mistake.
    public static func build(
        from recommendations: [Recommendation],
        inventory: SimulatorInventory,
        report: SimulatorStorageReport?,
        now: Date = Date()
    ) -> CleanupPlan {
        var operations: [CleanupOperation] = []
        var indexByDevice: [UUID: Int] = [:]

        for recommendation in recommendations {
            guard let action = executableAction(for: recommendation, inventory: inventory) else { continue }

            let operation = CleanupOperation(
                action: action,
                impact: CleanupImpact.forAction(action, inventory: inventory, report: report),
                estimatedBytes: estimatedBytes(for: action, recommendation: recommendation, report: report),
                cautions: recommendation.cautions
            )

            // A device must not be acted on twice in one plan. Since Rule F can
            // propose erasing a device that another rule proposes deleting, the
            // collision is ordinary rather than exceptional — and the plan is
            // confidence-ordered, so deletion would otherwise win by default.
            //
            // Keep the gentler action instead. Erasing someone who wanted a
            // deletion leaves them a device to delete afterwards; deleting
            // someone who wanted an erase destroys something unrecoverable.
            guard let deviceID = action.deviceID else {
                operations.append(operation)
                continue
            }

            if let existing = indexByDevice[deviceID] {
                if isGentler(operation.action, than: operations[existing].action) {
                    operations[existing] = operation
                }
                continue
            }

            indexByDevice[deviceID] = operations.count
            operations.append(operation)
        }

        return CleanupPlan(operations: operations, builtAt: now)
    }

    /// Erasing keeps the device; deleting does not. Nothing else is comparable.
    private static func isGentler(_ lhs: CleanupAction, than rhs: CleanupAction) -> Bool {
        lhs.isReversibleByRecreating && !rhs.isReversibleByRecreating
    }

    private static func executableAction(
        for recommendation: Recommendation,
        inventory: SimulatorInventory
    ) -> CleanupAction? {
        switch (recommendation.action, recommendation.target) {
        case (.deleteDevice, .device(let id)):
            guard let device = inventory.devices.first(where: { $0.id == id }) else { return nil }
            return .deleteDevice(id: id, name: device.name)

        case (.eraseDevice, .device(let id)):
            guard let device = inventory.devices.first(where: { $0.id == id }) else { return nil }
            return .eraseDevice(id: id, name: device.name)

        case (.deleteRuntime, .runtime(let identifier)):
            guard let runtime = inventory.runtimes.first(where: { $0.id == identifier }),
                  // simctl's flag is final. A runtime it will not delete must
                  // never reach a plan, or the user is promised a failing action.
                  runtime.isDeletable,
                  let imageUUID = runtime.imageUUID else { return nil }
            return .deleteRuntime(imageUUID: imageUUID, name: runtime.name)

        default:
            // Reviews, and any mismatched action/target pairing, are not executable.
            return nil
        }
    }

    private static func estimatedBytes(
        for action: CleanupAction,
        recommendation: Recommendation,
        report: SimulatorStorageReport?
    ) -> Int64 {
        switch action {
        case .eraseDevice(let id, _):
            // Erasing returns the device to its fresh baseline rather than
            // freeing everything it occupies.
            guard let total = report?.storage(forDevice: id)?.totalBytes else { return 0 }
            return max(total - 18_337_792, 0)
        default:
            return recommendation.recoverableBytes
        }
    }
}
