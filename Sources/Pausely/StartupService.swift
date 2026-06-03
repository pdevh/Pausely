import Foundation
import ServiceManagement

class StartupService {
    static let shared = StartupService()
    
    private init() {}
    
    /// Registers the app as a Login Item using SMAppService (macOS 13+).
    func register() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Best-effort — may fail if not code-signed or user denied
            print("StartupService: Failed to register login item: \(error)")
        }
    }
    
    /// Removes the app from Login Items.
    func deregister() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            // Best-effort
            print("StartupService: Failed to unregister login item: \(error)")
        }
    }
    
    /// Returns whether the app is currently registered as a Login Item.
    var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }
    
    /// Reconciles the persisted setting with the actual OS state.
    /// Call on app startup to handle cases where the user manually removed
    /// the login item via System Settings.
    func reconcile() {
        let settings = AppSettings.shared
        let osRegistered = isRegistered
        
        if settings.runOnStartup && !osRegistered {
            // Setting says enabled, but login item is missing — re-register
            register()
        } else if !settings.runOnStartup && osRegistered {
            // Setting says disabled, but login item exists — deregister
            deregister()
        }
    }
}
