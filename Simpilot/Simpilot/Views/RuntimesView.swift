import SwiftUI
import SimulatorManagerKit

struct RuntimesView: View {
    let store: InventoryStore

    var body: some View {
        Group {
            if store.runtimes.isEmpty {
                ContentUnavailableView(
                    "No runtimes",
                    systemImage: "shippingbox",
                    description: Text("No simulator runtimes are installed. Xcode installs one with each platform.")
                )
            } else {
                List {
                    ForEach(store.runtimes) { runtime in
                        RuntimeRow(runtime: runtime, store: store)
                    }
                    Section {
                        EstimateFootnote(text: "Runtime sizes are reported by simctl. macOS clones runtime images where it can, so removing one may free less than the size shown.")
                        CommandDisclosure(commands: [.listRuntimes, .runtimeList])
                    }
                }
            }
        }
        .navigationTitle("Runtimes")
    }
}

private struct RuntimeRow: View {
    let runtime: SimulatorRuntime
    let store: InventoryStore

    private var deviceCount: Int { store.deviceCount(forRuntime: runtime.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(runtime.name).font(.headline)
                Text(runtime.platform.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(ByteFormatting.stringOrUnknown(runtime.sizeBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label("\(deviceCount) device\(deviceCount == 1 ? "" : "s")", systemImage: "iphone")
                if let used = DateFormatting.lastUsed(runtime.lastUsedAt) {
                    Label("Used \(used)", systemImage: "clock")
                } else {
                    Label("No recorded use", systemImage: "clock")
                }
                Text("Build \(runtime.build)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            statusNotes
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// States the user needs before forming any intention about this runtime.
    /// Deletability is simctl's answer, not a guess from age or size.
    @ViewBuilder
    private var statusNotes: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !runtime.isAvailable {
                Label(
                    runtime.availabilityError ?? "This runtime is installed but not available.",
                    systemImage: "exclamationmark.triangle"
                )
            }
            if !runtime.isDeletable {
                Label(
                    runtime.imageUUID == nil
                        ? "No separate disk image — bundled with Xcode and not removable here."
                        : "simctl reports this runtime as not deletable.",
                    systemImage: "lock"
                )
            }
            if deviceCount > 0 {
                Label(
                    "Removing this runtime would leave \(deviceCount) device\(deviceCount == 1 ? "" : "s") unavailable.",
                    systemImage: "info.circle"
                )
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
