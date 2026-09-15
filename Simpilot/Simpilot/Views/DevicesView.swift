import SwiftUI
import SimulatorManagerKit

struct DevicesView: View {
    let store: InventoryStore

    @State private var filter: DeviceFilter = .all
    @State private var sort: DeviceSort = .size
    @State private var searchText = ""
    @State private var selection: UUID?

    private var rows: [DeviceRow] {
        store.rows.applying(filter: filter, sort: sort, searchText: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .navigationTitle("Devices")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Name, runtime or UDID")
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(DeviceFilter.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Sort by", selection: $sort) {
                    ForEach(DeviceSort.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Spacer()

                Text("\(rows.count) of \(store.rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Showing \(rows.count) of \(store.rows.count) devices")
            }

            // The criterion is always visible, so a filtered list never leaves the
            // user guessing why something is missing.
            Text(filter.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.rows.isEmpty {
            ContentUnavailableView(
                "No devices",
                systemImage: "iphone.slash",
                description: Text("This Mac has Xcode installed but no simulator devices have been created.")
            )
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.device.name)
                        if row.isPaired, let counterpart = row.pair?.counterpart(of: row.device.id) {
                            Label("Paired with \(counterpart.name)", systemImage: "applewatch")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                TableColumn("Runtime") { row in
                    if let name = row.runtimeName {
                        Text(name)
                    } else {
                        // Naming the missing runtime is more useful than the word
                        // "unavailable" on its own.
                        Text(shortRuntime(row.device.runtimeIdentifier))
                            .foregroundStyle(.secondary)
                    }
                }
                TableColumn("Status") { row in
                    statusLabel(row)
                }
                TableColumn("Last booted") { row in
                    if let relative = DateFormatting.lastUsed(row.device.lastBootedAt) {
                        Text(relative)
                            .help(DateFormatting.absolute(row.device.lastBootedAt) ?? "")
                    } else {
                        Text("No record")
                            .foregroundStyle(.secondary)
                            .help("simctl reports no boot for this device. It may still be wanted.")
                    }
                }
                TableColumn("Size") { row in
                    if let bytes = row.measuredBytes {
                        Text(ByteFormatting.string(bytes))
                            .monospacedDigit()
                    } else {
                        Text("Measuring…").foregroundStyle(.secondary)
                    }
                }
            }
            .tableStyle(.inset)
        }
    }

    @ViewBuilder
    private func statusLabel(_ row: DeviceRow) -> some View {
        if !row.device.isAvailable {
            Label("Unavailable", systemImage: "exclamationmark.triangle")
                .help(row.device.availabilityError ?? "Its runtime is not installed.")
        } else if row.device.state.isActive {
            Label(row.device.state.displayName, systemImage: "play.circle")
        } else {
            Text(row.device.state.displayName).foregroundStyle(.secondary)
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` → `iOS 17.0`
    private func shortRuntime(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: ".SimRuntime.").last ?? identifier
        let parts = tail.components(separatedBy: "-")
        guard parts.count >= 2 else { return tail }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}
