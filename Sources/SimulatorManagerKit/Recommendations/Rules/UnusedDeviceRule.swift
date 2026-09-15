import Foundation

/// Rule B — a device with no recorded use.
///
/// Phase 0 established that simctl records boot history, so the *evidence* here is
/// an observation rather than the filesystem-timestamp guess the original plan
/// assumed. The reason text says exactly what was observed; the inference that the
/// device is therefore unwanted lives in the confidence score, which stays medium.
///
/// A developer may legitimately keep an unbooted device for a test matrix they
/// have not run yet. This rule must never say "safe to delete".
public struct UnusedDeviceRule: RecommendationRule {
    public let identifier = "B.unused-device"
    public let title = "No recorded use"

    /// Days after which a booted device is also considered unused.
    public static let staleThresholdDays = 180

    public init() {}

    public func evaluate(_ context: RecommendationContext) -> [Recommendation] {
        context.inventory.devices.compactMap { device in
            // Unavailable devices are Rule A's; flagging them twice for weaker
            // reasons would clutter the list without adding information.
            guard device.isAvailable else { return nil }
            guard let reason = reason(for: device, context: context) else { return nil }

            return Recommendation(
                target: .device(device.id),
                action: .deleteDevice,
                reasons: [reason],
                cautions: context.cautions(forDevice: device),
                confidence: 0.5,
                recoverableBytes: context.measuredBytes(forDevice: device.id) ?? 0
            )
        }
    }

    private func reason(
        for device: SimulatorDevice,
        context: RecommendationContext
    ) -> RecommendationReason? {
        guard let lastBooted = device.lastBootedAt else {
            return RecommendationReason(
                kind: .neverUsed,
                // Precisely what simctl said, and nothing more.
                summary: "simctl has no boot record for this device. It may still be wanted for a test matrix you have not run yet.",
                isObservedFact: true
            )
        }

        guard let days = context.days(since: lastBooted),
              days >= Self.staleThresholdDays else { return nil }

        return RecommendationReason(
            kind: .stale,
            summary: "Last booted \(days) days ago, on \(lastBooted.formatted(date: .abbreviated, time: .omitted)).",
            isObservedFact: true
        )
    }
}
