import SwiftUI
import SimulatorManagerKit

struct RecommendationsView: View {
    let store: InventoryStore

    @State private var selected: Set<UUID> = []
    @State private var detail: Recommendation?
    @State private var previewPlan: CleanupPlan?

    /// Only actionable suggestions can be selected. Reviews stay in the list —
    /// they are the ones most worth reading — but cannot be swept into a plan.
    private var actionable: [Recommendation] {
        store.recommendations.filter { $0.action.isDestructive }
    }

    private var selectedRecommendations: [Recommendation] {
        actionable.filter { selected.contains($0.id) }
    }

    var body: some View {
        Group {
            if store.recommendations.isEmpty {
                ContentUnavailableView(
                    "Nothing to suggest",
                    systemImage: "checkmark.circle",
                    description: Text("Simpilot found no simulators or runtimes worth reviewing. That is a normal result on a machine in active use.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Suggestions")
        .toolbar { toolbar }
        .sheet(item: $detail) { recommendation in
            RecommendationDetailView(recommendation: recommendation, store: store) { plan in
                previewPlan = plan
            }
        }
        .sheet(item: $previewPlan) { plan in
            CleanupPreviewView(plan: plan) { confirmed in
                Task { await store.executeCleanup(confirmed) }
                selected.removeAll()
            }
        }
        .sheet(isPresented: .init(
            get: { store.cleanupOutcome != nil },
            set: { if !$0 { store.dismissCleanupOutcome() } }
        )) {
            if let outcome = store.cleanupOutcome {
                CleanupResultView(outcome: outcome) { store.dismissCleanupOutcome() }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.recommendations) { recommendation in
                    row(recommendation)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    EstimateFootnote(text: "Simpilot never removes anything on its own. Selecting items builds a plan you review before anything runs.")
                    CommandDisclosure(
                        commands: [.listDevices, .listRuntimes, .runtimeList, .listPairs],
                        label: "How these suggestions were derived"
                    )
                }
                .padding(.top, 8)
            }
        }
    }

    private func row(_ recommendation: Recommendation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if recommendation.action.isDestructive {
                Toggle(isOn: .init(
                    get: { selected.contains(recommendation.id) },
                    set: { isOn in
                        if isOn { selected.insert(recommendation.id) }
                        else { selected.remove(recommendation.id) }
                    }
                )) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel("Select \(title(recommendation))")
            } else {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .help("Needs a decision from you; cannot be selected for cleanup")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(recommendation)).fontWeight(.medium)
                    Spacer()
                    if recommendation.recoverableBytes > 0 {
                        Text(ByteFormatting.approximate(recommendation.recoverableBytes))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                Text(recommendation.action.verb)
                    .font(.caption).foregroundStyle(.secondary)

                if let first = recommendation.reasons.first {
                    Text(first.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(recommendation.level.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    if !recommendation.cautions.isEmpty {
                        Label("\(recommendation.cautions.count)", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(recommendation.cautions.map(\.summary).joined(separator: "\n"))
                    }
                }
            }

            Button("Details") { detail = recommendation }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { detail = recommendation }
    }

    private func title(_ recommendation: Recommendation) -> String {
        let names = recommendation.target.deviceIDs.compactMap { id in
            store.rows.first { $0.id == id }?.device.name
        }
        if !names.isEmpty { return names.joined(separator: ", ") }
        if case .runtime(let identifier) = recommendation.target {
            return store.runtimes.first { $0.id == identifier }?.name ?? identifier
        }
        return recommendation.action.verb
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button("Select all actionable") {
                selected = Set(actionable.map(\.id))
            }
            .disabled(actionable.isEmpty || selected.count == actionable.count)
        }
        ToolbarItem(placement: .automatic) {
            // "Review" is deliberately not "Clean Up": this opens the dry run.
            Button {
                previewPlan = store.plan(for: selectedRecommendations)
            } label: {
                Label("Review \(selected.count) selected", systemImage: "list.bullet.rectangle")
            }
            .disabled(selected.isEmpty || store.isExecutingCleanup)
        }
    }
}

extension CleanupPlan: @retroactive Identifiable {
    public var id: Date { builtAt }
}
