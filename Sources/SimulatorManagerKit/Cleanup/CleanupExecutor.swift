import Foundation

/// What happened when a plan ran.
public struct CleanupOutcome: Sendable {
    public struct Failure: Sendable {
        public let operation: CleanupOperation
        public let message: String

        public init(operation: CleanupOperation, message: String) {
            self.operation = operation
            self.message = message
        }
    }

    public let succeeded: [CleanupOperation]
    /// At most one: execution stops at the first failure rather than pressing on.
    public let failure: Failure?
    /// Operations that were never attempted because an earlier one failed.
    /// Listed separately so the user is never left guessing what ran.
    public let notAttempted: [CleanupOperation]

    /// Space actually recovered, measured by re-scanning afterwards.
    /// Nil when the re-scan could not be completed.
    public let measuredRecoveredBytes: Int64?
    /// What the plan predicted, retained so the two can be shown side by side.
    public let estimatedRecoverableBytes: Int64

    public var didCompleteFully: Bool { failure == nil && notAttempted.isEmpty }

    public init(
        succeeded: [CleanupOperation],
        failure: Failure? = nil,
        notAttempted: [CleanupOperation] = [],
        measuredRecoveredBytes: Int64? = nil,
        estimatedRecoverableBytes: Int64 = 0
    ) {
        self.succeeded = succeeded
        self.failure = failure
        self.notAttempted = notAttempted
        self.measuredRecoveredBytes = measuredRecoveredBytes
        self.estimatedRecoverableBytes = estimatedRecoverableBytes
    }
}

/// Runs a confirmed plan.
///
/// Two rules govern this type, both from the brief:
///
/// - **Stop at the first failure.** A destructive operation that failed is never
///   retried, and nothing after it is attempted. A failure usually means the
///   world is not as the plan assumed — a device booted, a runtime mounted — and
///   continuing would compound a mistake rather than recover from it.
/// - **Confirmation is not this type's job.** It executes what it is given, which
///   is exactly why it must only ever be handed a plan the user confirmed on a
///   screen that named every target.
public struct CleanupExecutor: Sendable {
    private let service: any SimulatorService

    public init(service: any SimulatorService) {
        self.service = service
    }

    public func execute(
        _ plan: CleanupPlan,
        progress: (@Sendable (CleanupOperation) -> Void)? = nil
    ) async -> CleanupOutcome {
        var succeeded: [CleanupOperation] = []

        for (index, operation) in plan.operations.enumerated() {
            progress?(operation)
            do {
                try await perform(operation.action)
                succeeded.append(operation)
            } catch {
                let message = (error as? SimctlError)?.errorDescription ?? error.localizedDescription
                return CleanupOutcome(
                    succeeded: succeeded,
                    failure: .init(operation: operation, message: message),
                    notAttempted: Array(plan.operations.dropFirst(index + 1)),
                    estimatedRecoverableBytes: plan.estimatedRecoverableBytes
                )
            }
        }

        return CleanupOutcome(
            succeeded: succeeded,
            estimatedRecoverableBytes: plan.estimatedRecoverableBytes
        )
    }

    private func perform(_ action: CleanupAction) async throws {
        switch action {
        case .deleteDevice(let id, _): try await service.deleteDevice(id: id)
        case .eraseDevice(let id, _): try await service.eraseDevice(id: id)
        case .deleteRuntime(let imageUUID, _): try await service.deleteRuntime(imageUUID: imageUUID)
        case .deleteUnavailableDevices: try await service.deleteUnavailableDevices()
        }
    }
}
