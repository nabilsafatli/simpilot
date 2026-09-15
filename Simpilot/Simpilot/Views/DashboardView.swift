import SwiftUI
import SimulatorManagerKit

struct DashboardView: View {
    let store: InventoryStore

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let summary = store.summary {
                    if !store.recommendations.isEmpty { recommendationsSection }
                    storageSection(summary)
                    inventorySection(summary)
                    if summary.unavailableDeviceCount > 0 || summary.orphanedLogCount > 0 {
                        findingsSection(summary)
                    }
                    provenance
                } else {
                    ContentUnavailableView(
                        "No inventory loaded",
                        systemImage: "iphone.slash",
                        description: Text("Refresh to read the simulators installed on this Mac.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
    }

    // MARK: - Recommendations
    //
    // A count and a figure, not a call to action. There is no "Clean Up" button
    // here: acting requires reviewing specific targets on a screen that names
    // them, which is deliberately a separate step.

    @ViewBuilder
    private var recommendationsSection: some View {
        let actionable = store.recommendations.filter { $0.action.isDestructive }
        let reviews = store.recommendations.filter { !$0.action.isDestructive }

        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    title: "Suggestions",
                    value: "\(store.recommendations.count)",
                    caption: reviews.isEmpty
                        ? "All propose an action"
                        : "\(reviews.count) need a decision from you",
                    symbol: "lightbulb"
                )
                StatTile(
                    title: "If you acted on all of them",
                    value: ByteFormatting.approximate(store.actionableRecoverableBytes),
                    caption: "Across \(actionable.count) suggestion\(actionable.count == 1 ? "" : "s"). Reviews are not counted.",
                    symbol: "arrow.down.circle",
                    isEstimate: true
                )
            }

            Text("Nothing is removed without your confirmation on a screen that names the exact target.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        } header: {
            sectionHeader("Suggestions")
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private func storageSection(_ summary: DashboardSummary) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    title: "Total simulator storage",
                    value: ByteFormatting.string(summary.totalBytes),
                    caption: summary.isMeasured ? "Devices, runtimes, caches and logs" : "Runtimes only so far",
                    symbol: "internaldrive",
                    isEstimate: true
                )
                StatTile(
                    title: "Devices",
                    value: summary.isMeasured ? ByteFormatting.string(summary.deviceBytes) : "Measuring…",
                    caption: "\(summary.deviceCount) devices",
                    symbol: "iphone",
                    isEstimate: true
                )
                StatTile(
                    title: "Runtimes",
                    value: ByteFormatting.string(summary.runtimeBytes),
                    caption: "Reported by simctl",
                    symbol: "shippingbox",
                    isEstimate: true
                )
                StatTile(
                    title: "Caches and logs",
                    value: summary.isMeasured
                        ? ByteFormatting.string(summary.sharedBytes + summary.logBytes + summary.orphanedLogBytes)
                        : "Measuring…",
                    caption: "Belongs to no single device",
                    symbol: "doc.text",
                    isEstimate: true
                )
            }
        } header: {
            sectionHeader("Storage")
        }
    }

    // MARK: - Inventory

    @ViewBuilder
    private func inventorySection(_ summary: DashboardSummary) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    title: "Devices",
                    value: "\(summary.deviceCount)",
                    caption: summary.runningCount > 0 ? "\(summary.runningCount) running" : "None running",
                    symbol: "square.grid.2x2"
                )
                StatTile(
                    title: "Runtimes",
                    value: "\(summary.runtimeCount)",
                    caption: "\(summary.platformCount) platform\(summary.platformCount == 1 ? "" : "s")",
                    symbol: "shippingbox"
                )
                StatTile(
                    title: "No recorded boot",
                    value: "\(summary.neverBootedCount)",
                    caption: "simctl has no boot record for these",
                    symbol: "moon.zzz"
                )
            }
        } header: {
            sectionHeader("Inventory")
        }
    }

    // MARK: - Findings
    //
    // Observations, not recommendations. Nothing here proposes an action: the
    // recommendation engine does not exist yet, and a dashboard that implied
    // otherwise would be claiming a review it has not performed.

    @ViewBuilder
    private func findingsSection(_ summary: DashboardSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if summary.unavailableDeviceCount > 0 {
                    finding(
                        symbol: "exclamationmark.triangle",
                        title: "\(summary.unavailableDeviceCount) device\(summary.unavailableDeviceCount == 1 ? "" : "s") reference a runtime that is not installed",
                        detail: "simctl reports these as unavailable. They cannot be booted until their runtime is reinstalled."
                    )
                }
                if summary.orphanedLogCount > 0 {
                    finding(
                        symbol: "doc.badge.ellipsis",
                        title: "\(summary.orphanedLogCount) log folder\(summary.orphanedLogCount == 1 ? "" : "s") with no matching device — \(ByteFormatting.string(summary.orphanedLogBytes))",
                        detail: "Left behind by deleted devices. Simpilot reports these but does not remove them: there is no simctl command for it, and this app does not delete simulator data any other way."
                    )
                }
            }
        } header: {
            sectionHeader("Observations")
        }
    }

    private func finding(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Provenance

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 8) {
            EstimateFootnote(text: "Sizes are estimates. macOS shares disk blocks between cloned files, so removing something may free less than its measured size.")
            CommandDisclosure(
                commands: [.listDevices, .listRuntimes, .runtimeList, .listPairs],
                label: "How these figures were gathered"
            )
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
