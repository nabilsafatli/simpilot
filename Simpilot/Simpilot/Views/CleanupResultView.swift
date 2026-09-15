import SwiftUI
import SimulatorManagerKit

/// What actually happened, with successes and failures listed separately.
///
/// Reports **measured** recovery from a fresh scan rather than echoing the
/// prediction back. The two are shown together when they disagree, because with
/// APFS cloning they legitimately can, and quietly presenting the estimate as the
/// result would be the easiest lie in the app to tell.
struct CleanupResultView: View {
    let outcome: CleanupOutcome
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !outcome.succeeded.isEmpty { succeeded }
                    if let failure = outcome.failure { failed(failure) }
                    if !outcome.notAttempted.isEmpty { notAttempted }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                outcome.didCompleteFully ? "Cleanup finished" : "Cleanup stopped",
                systemImage: outcome.didCompleteFully ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .font(.title3).fontWeight(.medium)

            if let measured = outcome.measuredRecoveredBytes {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteFormatting.string(measured)) recovered")
                        .font(.title2).fontWeight(.medium).monospacedDigit()
                    Text("Measured by re-scanning after the changes.")
                        .font(.caption).foregroundStyle(.secondary)

                    // Only mention the estimate when it actually differed.
                    if measured != outcome.estimatedRecoverableBytes {
                        Text("The estimate beforehand was \(ByteFormatting.string(outcome.estimatedRecoverableBytes)). macOS shares disk blocks between cloned files, so the two can differ.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("The amount recovered could not be measured, because the scan afterwards did not complete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var succeeded: some View {
        group("Completed", symbol: "checkmark.circle", items: outcome.succeeded.map {
            "\($0.action.verb): \($0.action.targetName)"
        })
    }

    private func failed(_ failure: CleanupOutcome.Failure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Failed", systemImage: "xmark.circle").font(.headline)
            Text("\(failure.operation.action.verb): \(failure.operation.action.targetName)")
                .font(.callout)
            Text(failure.message)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Simpilot stopped here and did not retry. Nothing after this was attempted.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var notAttempted: some View {
        group("Not attempted", symbol: "minus.circle", items: outcome.notAttempted.map {
            "\($0.action.verb): \($0.action.targetName)"
        })
    }

    private func group(_ title: String, symbol: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline)
            ForEach(items, id: \.self) { Text($0).font(.callout) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
