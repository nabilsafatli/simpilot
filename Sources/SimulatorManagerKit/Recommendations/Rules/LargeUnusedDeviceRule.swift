import Foundation

/// Rule C — an unused device that is also large.
///
/// Deliberately fires only where Rule B already applies. Size alone is never a
/// reason to remove anything: the largest simulator on a machine is usually the
/// one being worked in. What size changes is priority, not justification, so this
/// rule raises confidence above Rule B and adds a reason explaining the footprint
/// — it never originates a recommendation on its own.
///
/// The engine merges this with Rule B's recommendation for the same device, so
/// the user sees one entry carrying both reasons.
public struct LargeUnusedDeviceRule: RecommendationRule {
    public let identifier = "C.large-unused-device"
    public let title = "Large and unused"

    public static let largeThresholdBytes: Int64 = 5_368_709_120  // 5 GB

    public init() {}

    public func evaluate(_ context: RecommendationContext) -> [Recommendation] {
        context.inventory.devices.compactMap { device in
            guard device.isAvailable else { return nil }

            // Same unused test as Rule B. Without a measured size this rule
            // cannot apply at all — it will not guess from simctl's cached figure.
            guard isUnused(device, context: context),
                  let measured = context.measuredBytes(forDevice: device.id),
                  measured >= Self.largeThresholdBytes else { return nil }

            return Recommendation(
                target: .device(device.id),
                action: .deleteDevice,
                reasons: [
                    RecommendationReason(
                        kind: .largeUnusedDevice,
                        summary: "Uses \(ByteFormatting.string(measured)) of measured disk space, and has no recent recorded use.",
                        isObservedFact: false
                    )
                ],
                cautions: context.cautions(forDevice: device),
                confidence: 0.7,
                recoverableBytes: measured
            )
        }
    }

    private func isUnused(_ device: SimulatorDevice, context: RecommendationContext) -> Bool {
        guard let lastBooted = device.lastBootedAt else { return true }
        guard let days = context.days(since: lastBooted) else { return false }
        return days >= UnusedDeviceRule.staleThresholdDays
    }
}
