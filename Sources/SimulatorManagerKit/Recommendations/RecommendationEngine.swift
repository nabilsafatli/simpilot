import Foundation

/// The result of evaluating every rule against one inventory.
public struct RecommendationReport: Sendable {
    public let recommendations: [Recommendation]
    public let evaluatedAt: Date

    public var isEmpty: Bool { recommendations.isEmpty }

    public func recommendations(atLeast level: ConfidenceLevel) -> [Recommendation] {
        switch level {
        case .high: recommendations.filter { $0.level == .high }
        case .medium: recommendations.filter { $0.level == .high || $0.level == .medium }
        case .low: recommendations
        }
    }

    public func recommendation(forDevice id: UUID) -> Recommendation? {
        recommendations.first { $0.target == .device(id) }
    }

    /// Space that acting on the actionable recommendations could free.
    ///
    /// Counts each device at most once and excludes reviews entirely: a review is
    /// not a pending deletion, and adding its bytes to a headline figure would
    /// advertise space the user has not agreed to release. Still an estimate —
    /// APFS clones mean the real figure is only known after a re-scan.
    public var actionableRecoverableBytes: Int64 {
        var countedDevices = Set<UUID>()
        var total: Int64 = 0

        for recommendation in recommendations where recommendation.action.isDestructive {
            switch recommendation.target {
            case .device(let id):
                guard countedDevices.insert(id).inserted else { continue }
                total += recommendation.recoverableBytes
            case .runtime:
                total += recommendation.recoverableBytes
            case .deviceGroup:
                // Groups are only ever produced by review rules today; if that
                // changes, the per-device accounting above must be extended
                // rather than the group's total added wholesale.
                continue
            }
        }
        return total
    }

    public init(recommendations: [Recommendation], evaluatedAt: Date = Date()) {
        self.recommendations = recommendations
        self.evaluatedAt = evaluatedAt
    }
}

/// Runs the rules and reconciles their output.
///
/// Deterministic by construction: the same inventory and the same clock always
/// produce the same report. There are no model calls here and there must never
/// be — a recommendation that cannot be reproduced from a fixture cannot be
/// explained to the user or verified by a test.
public struct RecommendationEngine: Sendable {
    private let rules: [any RecommendationRule]

    public static let defaultRules: [any RecommendationRule] = [
        UnavailableDeviceRule(),
        UnusedDeviceRule(),
        LargeUnusedDeviceRule(),
        DuplicateDeviceRule(),
        RedundantRuntimeRule(),
        ReclaimableDataRule()
    ]

    public init(rules: [any RecommendationRule] = RecommendationEngine.defaultRules) {
        self.rules = rules
    }

    public func evaluate(
        inventory: SimulatorInventory,
        report storageReport: SimulatorStorageReport? = nil,
        now: Date = Date()
    ) -> RecommendationReport {
        let context = RecommendationContext(inventory: inventory, report: storageReport, now: now)
        let produced = rules.flatMap { $0.evaluate(context) }
        return RecommendationReport(recommendations: merge(produced), evaluatedAt: now)
    }

    /// Combines recommendations that propose the same action on the same target.
    ///
    /// Confidence is the **maximum** of the merged values, never their sum. Adding
    /// them up would let several weak heuristics accumulate into something that
    /// reads as certainty, which is exactly the failure this app is built to
    /// avoid. Two medium reasons to suspect a device is unused are still only a
    /// medium reason.
    private func merge(_ recommendations: [Recommendation]) -> [Recommendation] {
        var byKey: [MergeKey: Recommendation] = [:]
        var order: [MergeKey] = []

        for recommendation in recommendations {
            let key = MergeKey(target: recommendation.target, action: recommendation.action)

            guard let existing = byKey[key] else {
                byKey[key] = recommendation
                order.append(key)
                continue
            }

            byKey[key] = Recommendation(
                id: existing.id,
                target: existing.target,
                action: existing.action,
                reasons: dedupe(existing.reasons + recommendation.reasons),
                cautions: dedupe(existing.cautions + recommendation.cautions),
                confidence: max(existing.confidence, recommendation.confidence),
                // The same device's size, not two separate savings.
                recoverableBytes: max(existing.recoverableBytes, recommendation.recoverableBytes)
            )
        }

        return order.compactMap { byKey[$0] }.sorted(by: ranking)
    }

    /// Most confident first, then largest saving, then stably by identifier.
    private func ranking(_ lhs: Recommendation, _ rhs: Recommendation) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.recoverableBytes != rhs.recoverableBytes {
            return lhs.recoverableBytes > rhs.recoverableBytes
        }
        return lhs.target.stableKey < rhs.target.stableKey
    }

    private func dedupe<T: Identifiable & Hashable>(_ items: [T]) -> [T] where T.ID: Hashable {
        var seen = Set<T.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private struct MergeKey: Hashable {
        let target: RecommendationTarget
        let action: RecommendedAction
    }
}
