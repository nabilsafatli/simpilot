import SwiftUI
import SimulatorManagerKit

/// Reveals the exact `simctl` command behind a figure or an action.
///
/// This app exists because reaching these answers by hand was tedious. It should
/// not become a black box in the process: a developer who wants to verify what it
/// is about to do — or to learn the command for themselves — can always read and
/// copy the real thing.
struct CommandDisclosure: View {
    let commands: [SimctlCommand]
    var label: String = "Show commands"

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(commands, id: \.self) { command in
                    HStack(spacing: 8) {
                        Text(command.displayString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command.displayString, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy command")
                        .accessibilityLabel("Copy command \(command.displayString)")
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityHint("Shows the simctl commands used to produce this information")
    }
}
