import Foundation

class AppSettings {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let runOnStartup = "runOnStartup"
    }
    
    var autoUpdateEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoUpdateEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoUpdateEnabled) }
    }
    
    var runOnStartup: Bool {
        get { defaults.bool(forKey: Keys.runOnStartup) }
        set { defaults.set(newValue, forKey: Keys.runOnStartup) }
    }
    
    private init() {
        // Register defaults — both false (explicit opt-in)
        defaults.register(defaults: [
            Keys.autoUpdateEnabled: false,
            Keys.runOnStartup: false
        ])
    }
}
