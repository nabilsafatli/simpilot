import Foundation

/// Rule A — a device whose runtime is no longer installed.
///
/// The only rule allowed to state its rationale as fact. `isAvailable` comes
/// straight from simctl and needs no inference: the device cannot boot, and it
/// will not become bootable again unless its runtime is reinstalled. Confidence
/// is high because the *finding* is certain — the user may still want to keep the
/// device and reinstall the runtime, which is why this remains a recommendation
/// and not an automatic action.
public struct UnavailableDeviceRule: RecommendationRule {
    public let identifier = "A.unavailable-device"
    public let title = "Unavailable device"

    public init() {}

    public func evaluate(_ context: RecommendationContext) -> [Recommendation] {
        context.inventory.devices
            .filter { !$0.isAvailable }
            .map { device in
                var reasons = [
                    RecommendationReason(
                        kind: .unavailableRuntime,
                        summary: "simctl reports this device as unavailable: \(runtimeDescription(device, context)) is not installed.",
                        isObservedFact: true
                    )
                ]

                // simctl's own words, when it gave any. Shown as supporting
                // detail, never as the thing the rule keys on.
                if let error = device.availabilityError, !error.isEmpty {
                    reasons.append(RecommendationReason(
                        kind: .unavailableRuntime,
                        summary: "simctl's explanation: \(error)",
                        isObservedFact: true
                    ))
                }

                return Recommendation(
                    target: .device(device.id),
                    action: .deleteDevice,
                    reasons: reasons,
                    cautions: context.cautions(forDevice: device),
                    confidence: 0.95,
                    recoverableBytes: context.measuredBytes(forDevice: device.id) ?? 0
                )
            }
    }

    /// Names the missing runtime, which is more useful than the word "unavailable".
    private func runtimeDescription(_ device: SimulatorDevice, _ context: RecommendationContext) -> String {
        if let runtime = context.runtime(device.runtimeIdentifier) {
            return runtime.name
        }
        let tail = device.runtimeIdentifier.components(separatedBy: ".SimRuntime.").last
            ?? device.runtimeIdentifier
        let parts = tail.components(separatedBy: "-")
        guard parts.count >= 2 else { return tail }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}
