import SwiftUI
import SimulatorManagerKit

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case dashboard, recommendations, devices, runtimes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .recommendations: "Suggestions"
        case .devices: "Devices"
        case .runtimes: "Runtimes"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "chart.pie"
        case .recommendations: "lightbulb"
        case .devices: "iphone"
        case .runtimes: "shippingbox"
        }
    }
}

struct RootView: View {
    @State private var store = InventoryStore.live()
    @State private var screen: Screen = .dashboard

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.symbol)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) { statusBar }
        }
        .task {
            // First load happens on appearance; the window is usable throughout.
            if case .idle = store.state { await store.refreshAndWait() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if case .toolchainUnavailable(let reason) = store.state {
            ToolchainUnavailableView(reason: reason) { store.refresh() }
        } else {
            switch screen {
            case .dashboard: DashboardView(store: store)
            case .recommendations: RecommendationsView(store: store)
            case .devices: DevicesView(store: store)
            case .runtimes: RuntimesView(store: store)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.state.isBusy)
            .keyboardShortcut("r", modifiers: .command)
            .help("Re-read simulator state (⌘R)")
        }
    }

    /// Progress and provenance live at the bottom edge rather than in a modal, so
    /// a long scan never blocks reading what has already loaded.
    @ViewBuilder
    private var statusBar: some View {
        switch store.state {
        case _ where store.isExecutingCleanup:
            statusRow {
                ProgressView().controlSize(.small)
                if let operation = store.executingOperation {
                    Text("\(operation.action.verb): \(operation.action.targetName)…")
                } else {
                    Text("Applying changes…")
                }
            }
        case .loading:
            statusRow { ProgressView().controlSize(.small); Text("Reading simulator inventory…") }
        case .scanning(let progress):
            statusRow {
                if let progress, progress.totalDevices > 0 {
                    ProgressView(value: progress.fractionCompleted).frame(width: 120)
                    Text("Measuring \(progress.completedDevices) of \(progress.totalDevices) devices…")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Measuring disk usage…")
                }
            }
        case .failed(let message):
            statusRow {
                Label(message, systemImage: "exclamationmark.triangle").lineLimit(2)
            }
        case .ready:
            if !store.parseIssues.isEmpty {
                statusRow {
                    Label(
                        "\(store.parseIssues.count) entr\(store.parseIssues.count == 1 ? "y" : "ies") reported by simctl could not be read",
                        systemImage: "exclamationmark.triangle"
                    )
                    .help(store.parseIssues.map(\.detail).joined(separator: "\n"))
                }
            } else if let refreshed = store.lastRefreshedAt {
                statusRow {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
        case .idle, .toolchainUnavailable:
            EmptyView()
        }
    }

    private func statusRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content(); Spacer() }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}
