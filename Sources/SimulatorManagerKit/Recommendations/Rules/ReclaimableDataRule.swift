import Foundation

/// Rule F — a device holding far more data than a fresh one would.
///
/// The only rule where size is the primary trigger, and the only one that
/// proposes erasing. That combination needs justifying, because the brief is
/// explicit that "large" must never be sufficient reason to delete a device.
///
/// Erasing is not deleting. The device survives with its name, its identifier and
/// its runtime, so schemes and scripts referring to it keep working; what goes is
/// its contents. On a machine in active use this is usually where the space
/// actually is — a simulator that has built and run an app for months accumulates
/// gigabytes of caches and databases on top of an 18 MB baseline — and none of
/// the disuse-based rules will ever surface it, because the device is being used.
///
/// The cost is real and often invisible until it bites: logins, seeded test
/// accounts, downloaded content and anything not reproducible from a build are
/// gone. So this rule stays at low confidence no matter how large the device,
/// leads with what is lost rather than what is gained, and never proposes
/// deletion as an alternative.
public struct ReclaimableDataRule: RecommendationRule {
    public let identifier = "F.reclaimable-data"
    public let title = "Reclaimable app data"

    /// A freshly created device measured exactly 18,337,792 bytes on the Phase 0
    /// machine, identically across all nine never-booted devices. Erasing returns
    /// a device to approximately this, so only the excess is reclaimable.
    public static let freshDeviceBaselineBytes: Int64 = 18_337_792

    /// Minimum excess before this is worth a developer's attention. Below a
    /// gigabyte the disruption is rarely worth the space.
    public static let minimumReclaimableBytes: Int64 = 1_073_741_824  // 1 GB

    /// How long a device must have gone unused before its data is worth
    /// questioning.
    ///
    /// Without this, the rule fires on the simulator someone was working in an
    /// hour ago, whose contents are live state by definition. A week is the line
    /// because it spans a normal working rhythm: a simulator untouched across one
    /// is plausibly left over from finished work, while one used yesterday is not.
    /// Size is never allowed to override this — a 20 GB simulator in daily use
    /// stays unflagged.
    public static let minimumIdleDays = 7

    public init() {}

    public func evaluate(_ context: RecommendationContext) -> [Recommendation] {
        context.inventory.devices.compactMap { device in
            // An unavailable device cannot be erased meaningfully — its runtime
            // is gone — and Rule A already proposes removing it. Offering an
            // action that would fail helps nobody.
            guard device.isAvailable else { return nil }

            // A never-booted device sits at the baseline, so there is nothing to
            // reclaim; if it somehow holds data, Rule B's deletion is the better
            // answer than erasing a device that was never wanted.
            guard let lastBooted = device.lastBootedAt else { return nil }

            // Recently used means the data is live working state.
            guard let idleDays = context.days(since: lastBooted),
                  idleDays >= Self.minimumIdleDays else { return nil }

            // Requires measurement. This rule will not act on simctl's cached
            // figure, which Phase 0 found running 9-12% low on exactly the
            // used devices this rule targets.
            guard let measured = context.measuredBytes(forDevice: device.id) else { return nil }

            let reclaimable = measured - Self.freshDeviceBaselineBytes
            guard reclaimable >= Self.minimumReclaimableBytes else { return nil }

            return Recommendation(
                target: .device(device.id),
                action: .eraseDevice,
                reasons: reasons(device: device, measured: measured, reclaimable: reclaimable, idleDays: idleDays),
                cautions: cautions(device: device, context: context),
                // Low regardless of size. A 20 GB simulator in daily use is not a
                // stronger case for erasing than a 2 GB one — it is a bigger
                // number attached to the same unanswerable question.
                confidence: 0.4,
                recoverableBytes: reclaimable
            )
        }
    }

    private func reasons(
        device: SimulatorDevice,
        measured: Int64,
        reclaimable: Int64,
        idleDays: Int
    ) -> [RecommendationReason] {
        [
            RecommendationReason(
                kind: .reclaimableData,
                summary: "Uses \(ByteFormatting.string(measured)), against \(ByteFormatting.string(Self.freshDeviceBaselineBytes)) for a newly created device. About \(ByteFormatting.string(reclaimable)) is app data rather than the device itself.",
                isObservedFact: true
            ),
            RecommendationReason(
                kind: .reclaimableData,
                summary: "Last booted \(idleDays) days ago.",
                isObservedFact: true
            ),
            RecommendationReason(
                kind: .reclaimableData,
                summary: "Erasing returns it to a clean state. The simulator, its name and its identifier are kept, so build schemes and scripts that reference it keep working.",
                isObservedFact: true
            ),
            // Size says nothing about whether the contents matter. Say so, rather
            // than letting a large number imply the answer.
            RecommendationReason(
                kind: .reclaimableData,
                summary: "Only you can tell whether what it holds is still needed. Size alone is not a reason to clear it.",
                isObservedFact: false
            )
        ]
    }

    private func cautions(
        device: SimulatorDevice,
        context: RecommendationContext
    ) -> [RecommendationCaution] {
        var cautions = context.cautions(forDevice: device)
        // Leads the list: this is the consequence people underestimate.
        cautions.insert(
            RecommendationCaution(
                kind: .dataLoss,
                summary: "Installed apps, databases, logins, seeded test accounts and downloaded content on “\(device.name)” are permanently lost. Anything not reproducible from a build cannot be recovered."
            ),
            at: 0
        )
        return cautions
    }
}
