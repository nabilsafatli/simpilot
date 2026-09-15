import Foundation

/// Rule E — an older runtime that may no longer be needed.
///
/// The most cautious rule here, and deliberately the weakest. A newer runtime does
/// not obsolete an older one: supporting an older OS is a product decision this app
/// cannot see, and an unused runtime may be exactly the one needed for the next
/// compatibility check. So this only ever suggests a review.
///
/// It requires all of: a newer installed runtime on the same platform, no recent
/// recorded use, and simctl's own confirmation that the runtime is deletable.
/// Where devices still depend on the runtime, the rule says how many would be
/// stranded rather than quietly counting their space as recoverable.
public struct RedundantRuntimeRule: RecommendationRule {
    public let identifier = "E.redundant-runtime"
    public let title = "Possibly redundant runtime"

    public static let unusedThresholdDays = 180

    public init() {}

    public func evaluate(_ context: RecommendationContext) -> [Recommendation] {
        let runtimes = context.inventory.runtimes

        return runtimes.compactMap { runtime -> Recommendation? in
            // simctl's flag is the authority. An undeletable runtime cannot be
            // acted on, so recommending a review of it would waste the user's time.
            guard runtime.isDeletable, runtime.isAvailable else { return nil }

            // A newer runtime must exist on the SAME platform. iOS 26 says
            // nothing about whether watchOS 11 is still needed.
            let newer = runtimes.filter {
                $0.platform == runtime.platform
                    && $0.isAvailable
                    && $0.version.compare(runtime.version, options: .numeric) == .orderedDescending
            }
            guard let newest = newer.max(by: {
                $0.version.compare($1.version, options: .numeric) == .orderedAscending
            }) else { return nil }

            guard let usageReason = usageReason(for: runtime, context: context) else { return nil }

            let dependents = context.inventory.devices(forRuntime: runtime.id)
            var reasons = [
                usageReason,
                RecommendationReason(
                    kind: .redundantCoverage,
                    summary: "\(newest.name) is also installed and is newer. That does not make \(runtime.name) unnecessary — keep it if you still support that OS version.",
                    isObservedFact: false
                )
            ]

            var cautions: [RecommendationCaution] = []
            if !dependents.isEmpty {
                cautions.append(RecommendationCaution(
                    kind: .runtimeInUse,
                    summary: "\(dependents.count) device\(dependents.count == 1 ? "" : "s") use\(dependents.count == 1 ? "s" : "") this runtime and would become unavailable."
                ))
                reasons.append(RecommendationReason(
                    kind: .redundantCoverage,
                    summary: "Devices that would be affected: \(dependents.map(\.name).sorted().joined(separator: ", ")).",
                    isObservedFact: true
                ))
            }

            return Recommendation(
                target: .runtime(runtime.id),
                action: .reviewRuntime,
                reasons: reasons,
                cautions: cautions,
                // Low by construction: this is a prompt to think, not a proposal.
                confidence: 0.35,
                recoverableBytes: runtime.sizeBytes ?? 0
            )
        }
    }

    private func usageReason(
        for runtime: SimulatorRuntime,
        context: RecommendationContext
    ) -> RecommendationReason? {
        guard let lastUsed = runtime.lastUsedAt else {
            return RecommendationReason(
                kind: .obsoleteRuntime,
                summary: "simctl has no usage record for \(runtime.name).",
                isObservedFact: true
            )
        }

        guard let days = context.days(since: lastUsed),
              days >= Self.unusedThresholdDays else { return nil }

        return RecommendationReason(
            kind: .obsoleteRuntime,
            summary: "\(runtime.name) was last used \(days) days ago, on \(lastUsed.formatted(date: .abbreviated, time: .omitted)).",
            isObservedFact: true
        )
    }
}
