import SwiftUI
import SimulatorManagerKit

/// Everything behind one suggestion: what was observed, what was inferred, what
/// an action would remove and — given equal weight — what it would leave alone.
struct RecommendationDetailView: View {
    let recommendation: Recommendation
    let store: InventoryStore
    var onAct: ((CleanupPlan) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingAction = false

    private var plan: CleanupPlan { store.plan(for: [recommendation]) }
    private var operation: CleanupOperation? { plan.operations.first }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    reasonsSection
                    if let operation { impactSection(operation) }
                    if !recommendation.cautions.isEmpty { cautionsSection }
                    commandSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 580)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(targetName).font(.title2).fontWeight(.medium)

            HStack(spacing: 10) {
                Label(recommendation.level.displayName, systemImage: confidenceSymbol)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())

                if recommendation.recoverableBytes > 0 {
                    Text(ByteFormatting.approximate(recommendation.recoverableBytes))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Says plainly whether this is a conclusion or a question.
            Text(recommendation.action.isDestructive
                 ? "Simpilot suggests this action. It has not been taken."
                 : "This needs a decision from you. Simpilot will not act on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var confidenceSymbol: String {
        switch recommendation.level {
        case .high: "checkmark.seal"
        case .medium: "questionmark.circle"
        case .low: "eye"
        }
    }

    private var targetName: String {
        let names = recommendation.target.deviceIDs.compactMap { id in
            store.rows.first { $0.id == id }?.device.name
        }
        if !names.isEmpty { return names.joined(separator: ", ") }
        if case .runtime(let identifier) = recommendation.target {
            return store.runtimes.first { $0.id == identifier }?.name ?? identifier
        }
        return recommendation.action.verb
    }

    // MARK: - Reasons

    private var reasonsSection: some View {
        section("Why this was flagged") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recommendation.reasons) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        // The distinction the whole app rests on: an observation
                        // from simctl versus something Simpilot worked out.
                        Text(reason.isObservedFact ? "Observed" : "Inferred")
                            .font(.caption2).fontWeight(.medium)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(reason.isObservedFact ? .quaternary : .quinary, in: Capsule())
                            .frame(width: 66)

                        Text(reason.summary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !recommendation.hasOnlyObservedEvidence {
                    Text("Items marked Inferred are Simpilot's judgement, not something simctl reported.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Impact

    private func impactSection(_ operation: CleanupOperation) -> some View {
        section("What \(operation.action.verb.lowercased()) does") {
            HStack(alignment: .top, spacing: 14) {
                impactColumn(
                    title: "This will remove",
                    symbol: "minus.circle",
                    items: operation.impact.willRemove
                )
                Divider()
                impactColumn(
                    title: "This will NOT remove",
                    symbol: "checkmark.circle",
                    items: operation.impact.willKeep
                )
            }
        }
    }

    private func impactColumn(title: String, symbol: String, items: [ImpactItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption).fontWeight(.semibold)

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.summary).font(.caption)
                        if let bytes = item.bytes {
                            Spacer()
                            Text(ByteFormatting.string(bytes))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cautions

    private var cautionsSection: some View {
        section("Before you act") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(recommendation.cautions) { caution in
                    Label(caution.summary, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var commandSection: some View {
        section("Command") {
            if let operation {
                CommandDisclosure(commands: [operation.command], label: "Show the command this runs")
            } else {
                Text("This suggestion has no automatic action. Decide which devices to keep, then act on them individually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()

            if let operation {
                Text(ByteFormatting.approximate(operation.estimatedBytes))
                    .font(.caption).foregroundStyle(.secondary)

                // Its own confirmation, naming the exact target.
                Button(operation.action.verb) { confirmingAction = true }
                    .buttonStyle(.borderedProminent)
                    .confirmationDialog(
                        "\(operation.action.verb) “\(operation.action.targetName)”?",
                        isPresented: $confirmingAction,
                        titleVisibility: .visible
                    ) {
                        Button(operation.action.verb, role: .destructive) {
                            onAct?(plan)
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text(confirmationMessage(operation))
                    }
            }
        }
        .padding(12)
    }

    private func confirmationMessage(_ operation: CleanupOperation) -> String {
        var lines = [operation.command.displayString]
        if operation.action.isReversibleByRecreating {
            lines.append("The simulator itself is kept. Its apps and data are cleared and cannot be recovered.")
        } else {
            lines.append("This cannot be undone.")
        }
        for caution in operation.cautions { lines.append(caution.summary) }
        return lines.joined(separator: "\n\n")
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
