import SwiftUI

/// Shown when `simctl` cannot be reached.
///
/// A distinct state from "no devices". The Simulator tools ship with Xcode, not
/// with the Command Line Tools, so a developer can have a perfectly working
/// `swift` and `git` and still have nothing here. Showing an empty dashboard
/// would read as "you have no simulators", which is a different and wrong claim.
struct ToolchainUnavailableView: View {
    let reason: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Xcode not found", systemImage: "wrench.and.screwdriver")
        } description: {
            VStack(spacing: 12) {
                Text("Simpilot reads simulator state with `simctl`, which is installed as part of Xcode. The Command Line Tools package does not include it.")

                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text("If Xcode is installed, check which toolchain is selected:")
                        .font(.caption)
                    Text("xcode-select -p")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxWidth: 420)
        } actions: {
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }
}
