import SwiftUI

@main
struct SimpilotApp: App {
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Replaces the template's New Window item, which this app has no use for.
            CommandGroup(replacing: .newItem) { }

            // Sits directly under "About Simpilot", where macOS users look for it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}
