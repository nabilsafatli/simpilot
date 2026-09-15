import SwiftUI
import SimulatorManagerKit

/// The dry run. Lists every pending operation with its size and the total.
///
/// Nothing executes while this is open — the plan is a value that was built
/// without touching anything, and only the explicit "Clean Up" button below hands
/// it to the executor. That button is deliberately separate from the "Review"
/// action that opened this sheet.
struct CleanupPreviewView: View {
    let plan: CleanupPlan
    let onConfirm: (CleanupPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(plan.operations) { operation in
                        operationRow(operation)
                    }
                    if !plan.cautions.isEmpty { cautions }
                    commands
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review before cleaning up").font(.title3).fontWeight(.medium)
            Text("Nothing has been changed yet. These \(plan.operations.count) operation\(plan.operations.count == 1 ? "" : "s") will run only when you choose Clean Up.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func operationRow(_ operation: CleanupOperation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(operation.action.verb, systemImage: operation.action.isReversibleByRecreating ? "eraser" : "trash")
                    .font(.callout).fontWeight(.medium)
                Text(operation.action.targetName).foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormatting.approximate(operation.estimatedBytes))
                    .monospacedDigit().foregroundStyle(.secondary)
            }

            // The impact summary travels into the preview, so the last screen
            // before acting still says what survives.
            HStack(alignment: .top, spacing: 12) {
                miniColumn("Removes", operation.impact.willRemove.prefix(2).map(\.summary))
                miniColumn("Keeps", operation.impact.willKeep.prefix(2).map(\.summary))
            }

            Text(operation.command.displayString)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func miniColumn(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { Text($0).font(.caption2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cautions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Before you continue").font(.caption).fontWeight(.semibold)
            ForEach(plan.cautions) { caution in
                Label(caution.summary, systemImage: "exclamationmark.triangle")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 6) {
            EstimateFootnote(text: "Sizes are estimates. macOS shares disk blocks between cloned files, so you may recover less than shown. Simpilot measures the real figure afterwards.")
            CommandDisclosure(commands: plan.commands, label: "Show every command this will run")
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Up to \(ByteFormatting.string(plan.estimatedRecoverableBytes))")
                    .font(.callout).monospacedDigit()
                Text("estimated").font(.caption2).foregroundStyle(.secondary)
            }
            Button("Clean Up") { isConfirming = true }
                .buttonStyle(.borderedProminent)
                .confirmationDialog(
                    "Run \(plan.operations.count) operation\(plan.operations.count == 1 ? "" : "s")?",
                    isPresented: $isConfirming,
                    titleVisibility: .visible
                ) {
                    Button("Clean Up", role: .destructive) {
                        onConfirm(plan)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(plan.operations.map { "\($0.action.verb): \($0.action.targetName)" }
                        .joined(separator: "\n") + "\n\nDeletions cannot be undone.")
                }
        }
        .padding(12)
    }
}
