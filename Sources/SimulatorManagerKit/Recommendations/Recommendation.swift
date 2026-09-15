import CryptoKit
import Foundation

/// What a recommendation is about.
public enum RecommendationTarget: Hashable, Sendable {
    case device(UUID)
    /// Several devices considered together. Used where the useful decision is a
    /// choice among them rather than an action on any one — duplicates, for
    /// instance, where deleting the whole set is never the right answer.
    case deviceGroup([UUID])
    case runtime(String)

    /// A stable textual key. Used to give recommendations an identity that
    /// survives a refresh, so ordering is deterministic and UI selection does not
    /// jump when the inventory is re-read.
    public var stableKey: String {
        switch self {
        case .device(let id): "device:\(id.uuidString)"
        case .deviceGroup(let ids): "group:\(ids.map(\.uuidString).sorted().joined(separator: ","))"
        case .runtime(let identifier): "runtime:\(identifier)"
        }
    }

    public var deviceIDs: [UUID] {
        switch self {
        case .device(let id): [id]
        case .deviceGroup(let ids): ids
        case .runtime: []
        }
    }
}

/// What the app suggests doing.
///
/// `review` actions are first-class rather than a weaker delete: some findings
/// genuinely resolve to "look at this and decide", and dressing that up as a
/// pending deletion would overstate what the app knows.
public enum RecommendedAction: Hashable, Sendable {
    case deleteDevice
    case eraseDevice
    case deleteRuntime
    case reviewDuplicates
    case reviewRuntime

    public var isDestructive: Bool {
        switch self {
        case .deleteDevice, .eraseDevice, .deleteRuntime: true
        case .reviewDuplicates, .reviewRuntime: false
        }
    }

    public var verb: String {
        switch self {
        case .deleteDevice: "Delete simulator"
        case .eraseDevice: "Erase simulator"
        case .deleteRuntime: "Delete runtime"
        case .reviewDuplicates: "Review duplicates"
        case .reviewRuntime: "Review runtime"
        }
    }
}

/// One piece of evidence behind a recommendation.
///
/// Carries its own wording rather than an enum the UI must translate blindly, and
/// records whether it is an **observation** or an **inference**. That distinction
/// is the whole product: "its runtime is not installed" is something simctl told
/// us, while "you probably don't need it" never is. The UI renders the two
/// differently, and no amount of accumulated inference is allowed to read as fact.
public struct RecommendationReason: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case unavailableRuntime
        case neverUsed
        case stale
        case duplicate
        case redundantCoverage
        case largeUnusedDevice
        case obsoleteRuntime
        /// App data on a device far above its fresh-install size. Unlike the
        /// other kinds this says nothing about whether the device is wanted —
        /// only that its contents, not the device itself, account for the space.
        case reclaimableData
    }

    public let kind: Kind
    /// Specific, human-readable, and safe to render directly.
    public let summary: String
    /// True when simctl reported this directly; false when the app inferred it.
    public let isObservedFact: Bool

    public var id: String { "\(kind.rawValue):\(summary)" }

    public init(kind: Kind, summary: String, isObservedFact: Bool) {
        self.kind = kind
        self.summary = summary
        self.isObservedFact = isObservedFact
    }
}

/// Something the user must weigh that the recommendation does not resolve.
///
/// Cautions are never netted off against confidence. A high-confidence deletion
/// that would break a Watch pairing stays high-confidence *and* carries the
/// caution, because the two facts are independent and hiding either would be
/// dishonest.
public struct RecommendationCaution: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case deviceIsRunning
        case breaksPairing
        case runtimeInUse
        case sizeNotMeasured
        /// Content that cannot be recovered after the action. Distinct from the
        /// others: those describe disruption, this describes permanent loss.
        case dataLoss
    }

    public let kind: Kind
    public let summary: String

    public var id: String { "\(kind.rawValue):\(summary)" }

    public init(kind: Kind, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

public enum ConfidenceLevel: String, Hashable, Sendable {
    case high, medium, low

    public var displayName: String {
        switch self {
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .low: "For review"
        }
    }
}

public struct Recommendation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let target: RecommendationTarget
    public let action: RecommendedAction
    public let reasons: [RecommendationReason]
    public let cautions: [RecommendationCaution]
    /// 0...1. Confidence that the action is appropriate, never that it is safe —
    /// safety is the confirmation screen's job.
    public let confidence: Double
    /// Estimated space the action would free. Always an estimate: APFS clones
    /// share blocks, so the real figure is only known after a re-scan.
    public let recoverableBytes: Int64

    public var level: ConfidenceLevel {
        switch confidence {
        case 0.8...: .high
        case 0.5..<0.8: .medium
        default: .low
        }
    }

    /// True when every *reason* is something simctl reported.
    ///
    /// Says nothing about whether the recommended action is warranted. Rule B's
    /// evidence is fully observed — simctl really does have no boot record — yet
    /// the conclusion drawn from it is an inference, which is why that rule stays
    /// at medium confidence. Read this as "the evidence is observed", never as
    /// "the recommendation is certain"; ``level`` is the only thing that speaks to
    /// the latter.
    public var hasOnlyObservedEvidence: Bool {
        !reasons.isEmpty && reasons.allSatisfy { $0.isObservedFact }
    }

    /// Identity derived from the target and action rather than generated fresh.
    ///
    /// Two evaluations of the same inventory therefore produce equal ids, which is
    /// what makes engine output reproducible and keeps list selection stable
    /// across a refresh.
    public static func identity(target: RecommendationTarget, action: RecommendedAction) -> UUID {
        let digest = SHA256.hash(data: Data("\(target.stableKey)|\(action)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5, name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public init(
        id: UUID? = nil,
        target: RecommendationTarget,
        action: RecommendedAction,
        reasons: [RecommendationReason],
        cautions: [RecommendationCaution] = [],
        confidence: Double,
        recoverableBytes: Int64 = 0
    ) {
        self.id = id ?? Recommendation.identity(target: target, action: action)
        self.target = target
        self.action = action
        self.reasons = reasons
        self.cautions = cautions
        self.confidence = min(max(confidence, 0), 1)
        self.recoverableBytes = recoverableBytes
    }
}
