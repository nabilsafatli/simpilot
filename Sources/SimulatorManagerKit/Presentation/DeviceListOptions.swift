import Foundation

/// How the Devices list is ordered.
public enum DeviceSort: String, CaseIterable, Identifiable, Sendable {
    case size, name, runtime, lastUsed, state

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .runtime: "Runtime"
        case .lastUsed: "Last Used"
        case .state: "State"
        }
    }
}

/// Which devices the list shows.
///
/// Deliberately omits a "recommended for deletion" case: recommendations do not
/// exist until the engine does, and offering a filter that silently matches
/// nothing would misrepresent the inventory as already reviewed.
public enum DeviceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unavailable
    case neverBooted
    case large
    case running
    case shutdown
    case paired

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .unavailable: "Unavailable"
        case .neverBooted: "Never Booted"
        case .large: "Large"
        case .running: "Running"
        case .shutdown: "Shut Down"
        case .paired: "Paired"
        }
    }

    /// What the filter actually means, shown in the UI so a filtered list never
    /// leaves the user guessing at the criterion.
    public var explanation: String {
        switch self {
        case .all: "Every simulator device on this Mac."
        case .unavailable: "Devices whose runtime is no longer installed. simctl reports these as unavailable."
        case .neverBooted: "Devices with no recorded boot. They may still be wanted for a future test matrix."
        case .large: "Devices using more than \(ByteFormatting.string(DeviceFilter.largeThreshold)) of measured disk space."
        case .running: "Devices that are booted or in transition."
        case .shutdown: "Devices that are not running."
        case .paired: "Devices paired with a Watch. Deleting either half breaks the pair."
        }
    }

    /// The size at which a device is called "large".
    ///
    /// A threshold, not a judgement: being large is never itself a reason to
    /// delete something, and the UI must not imply otherwise.
    public static let largeThreshold: Int64 = 5_368_709_120  // 5 GB

    func matches(_ row: DeviceRow) -> Bool {
        switch self {
        case .all: true
        case .unavailable: !row.device.isAvailable
        case .neverBooted: !row.hasEverBooted
        case .large: (row.measuredBytes ?? 0) >= Self.largeThreshold
        case .running: row.device.state.isActive
        case .shutdown: !row.device.state.isActive
        case .paired: row.isPaired
        }
    }
}

public extension Array where Element == DeviceRow {
    /// Applies a filter, a search term and an ordering.
    ///
    /// Devices whose size has not been measured sort last rather than as zero, so
    /// an in-progress scan never makes a large device look empty.
    func applying(
        filter: DeviceFilter,
        sort: DeviceSort,
        ascending: Bool = false,
        searchText: String = ""
    ) -> [DeviceRow] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        let filtered = self.filter { row in
            guard filter.matches(row) else { return false }
            guard !term.isEmpty else { return true }
            return row.device.name.localizedCaseInsensitiveContains(term)
                || (row.runtimeName?.localizedCaseInsensitiveContains(term) ?? false)
                || row.device.id.uuidString.localizedCaseInsensitiveContains(term)
        }

        let sorted = filtered.sorted { lhs, rhs in
            switch sort {
            case .size:
                let left = lhs.measuredBytes ?? -1
                let right = rhs.measuredBytes ?? -1
                if left != right { return left > right }
            case .name:
                let comparison = lhs.device.name.localizedStandardCompare(rhs.device.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .runtime:
                let left = lhs.runtimeName ?? lhs.device.runtimeIdentifier
                let right = rhs.runtimeName ?? rhs.device.runtimeIdentifier
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            case .lastUsed:
                // Never-booted devices have no date at all; they sort last under
                // a descending "most recent first" ordering.
                switch (lhs.device.lastBootedAt, rhs.device.lastBootedAt) {
                case let (left?, right?) where left != right: return left > right
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
            case .state:
                if lhs.device.state.displayName != rhs.device.state.displayName {
                    return lhs.device.state.displayName < rhs.device.state.displayName
                }
            }
            // Stable tiebreak so the list never reorders between identical renders.
            return lhs.device.name.localizedStandardCompare(rhs.device.name) == .orderedAscending
        }

        return ascending ? sorted.reversed() : sorted
    }
}
