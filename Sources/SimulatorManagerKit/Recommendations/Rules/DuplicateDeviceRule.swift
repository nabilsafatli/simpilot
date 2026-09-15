import Foundation

/// Rule D — several devices with the same device type and runtime.
///
/// Emits a **review**, never a deletion. Which copy to keep is a question only the
/// user can answer: identical configurations are often deliberate, holding
/// different app states, seeded data or test accounts that simctl cannot see.
///
/// The rule names a suggested keeper and explains why it was suggested, but the
/// target is the whole group, so no single device is ever pre-marked for removal.
/// `recoverableBytes` describes what removing the *others* would free — it is an
/// illustration of the stakes, not a pending action.
public struct DuplicateDeviceRule: RecommendationRule {
    public let identifier = "D.duplicate-devices"
    public let title = "Duplicate configurations"

    public init() {}

    public func evaluate(_ context: RecommendationContext) -> [Recommendation] {
        let groups = Dictionary(grouping: context.inventory.devices.filter(\.isAvailable)) {
            DuplicateKey(deviceType: $0.deviceTypeIdentifier, runtime: $0.runtimeIdentifier)
        }

        return groups
            .filter { $0.value.count >= 2 }
            // Dictionary iteration order is not stable; sort so the engine's
            // output is deterministic for the same inventory.
            .sorted { lhs, rhs in
                lhs.value.first?.name ?? "" < rhs.value.first?.name ?? ""
            }
            .map { _, devices in
                let keeper = suggestedKeeper(devices, context: context)
                let others = devices.filter { $0.id != keeper.id }
                let othersBytes = others.compactMap { context.measuredBytes(forDevice: $0.id) }.reduce(0, +)

                var reasons = [
                    RecommendationReason(
                        kind: .duplicate,
                        summary: "\(devices.count) devices share the same device type and runtime: \(devices.map(\.name).sorted().joined(separator: ", ")).",
                        isObservedFact: true
                    ),
                    RecommendationReason(
                        kind: .duplicate,
                        summary: keeperRationale(keeper, context: context),
                        isObservedFact: false
                    )
                ]

                // Identical configurations often hold deliberately different
                // state. Saying so is the point of making this a review.
                reasons.append(RecommendationReason(
                    kind: .duplicate,
                    summary: "Duplicates can be intentional — each may hold different app data, accounts or test state that simctl cannot see. Choose which to keep before removing any.",
                    isObservedFact: false
                ))

                return Recommendation(
                    target: .deviceGroup(devices.map(\.id).sorted { $0.uuidString < $1.uuidString }),
                    action: .reviewDuplicates,
                    reasons: reasons,
                    cautions: devices.flatMap { context.cautions(forDevice: $0) },
                    confidence: 0.6,
                    recoverableBytes: othersBytes
                )
            }
    }

    /// Suggests the copy with the strongest evidence of use: most recently booted
    /// first, then largest, then by name so the choice is deterministic.
    private func suggestedKeeper(
        _ devices: [SimulatorDevice],
        context: RecommendationContext
    ) -> SimulatorDevice {
        devices.max { lhs, rhs in
            switch (lhs.lastBootedAt, rhs.lastBootedAt) {
            case let (left?, right?) where left != right: return left < right
            case (nil, .some): return true
            case (.some, nil): return false
            default: break
            }
            let leftBytes = context.measuredBytes(forDevice: lhs.id) ?? 0
            let rightBytes = context.measuredBytes(forDevice: rhs.id) ?? 0
            if leftBytes != rightBytes { return leftBytes < rightBytes }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        } ?? devices[0]
    }

    private func keeperRationale(
        _ keeper: SimulatorDevice,
        context: RecommendationContext
    ) -> String {
        if let booted = keeper.lastBootedAt {
            return "\"\(keeper.name)\" looks like the one in use — it was last booted on \(booted.formatted(date: .abbreviated, time: .omitted))."
        }
        return "None of these has a boot record, so there is no evidence favouring one over another. \"\(keeper.name)\" is suggested only as a starting point."
    }

    private struct DuplicateKey: Hashable {
        let deviceType: String
        let runtime: String
    }
}
