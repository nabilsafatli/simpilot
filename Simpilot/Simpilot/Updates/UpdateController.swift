import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle's updater and exposes just enough of it for the menu item.
///
/// Automatic checking is off by default (`SUEnableAutomaticChecks` is false in
/// Info.plist), so Sparkle asks permission on first launch rather than quietly
/// contacting a server. That is the consistent choice for a tool whose entire
/// premise is not doing things behind the user's back — an app that refuses to
/// delete a simulator without confirmation should not phone home without it
/// either.
@MainActor
final class UpdateController: ObservableObject {
    /// Mirrors Sparkle's own readiness, so the menu item disables itself while a
    /// check is already running rather than starting a second one.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true schedules Sparkle's own lifecycle. The delegates
        // are nil because the standard user driver's behaviour is what we want:
        // it presents the update, the release notes and the install prompt.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// The feed the app will actually contact, for display in a diagnostics view.
    var feedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "not configured"
    }
}
