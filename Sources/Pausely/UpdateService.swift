import Foundation
import AppKit
import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the application.
/// Sparkle provides the update prompt, release notes, skip/remind behavior,
/// archive verification, installation, and relaunch flow.
final class UpdateService: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateService()

    private var updaterController: SPUStandardUpdaterController!

    private override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    /// Presents Sparkle's standard update UI for a user-initiated check.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Performs a quiet launch check while preserving Sparkle's scheduling.
    func checkForUpdatesInBackground() {
        guard automaticallyChecksForUpdates else { return }
        updaterController.updater.checkForUpdatesInBackground()
    }

    // Pausely is a menu-bar app without a Dock icon. Bring Sparkle's standard
    // update window forward so a scheduled update is not hidden behind the
    // user's other applications.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
