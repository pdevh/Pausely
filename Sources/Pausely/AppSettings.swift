import Foundation

class AppSettings {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let runOnStartup = "runOnStartup"
        static let workInterval = "workInterval"
        static let breakDuration = "breakDuration"
    }
    
    var autoUpdateEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoUpdateEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoUpdateEnabled) }
    }
    
    var runOnStartup: Bool {
        get { defaults.bool(forKey: Keys.runOnStartup) }
        set { defaults.set(newValue, forKey: Keys.runOnStartup) }
    }
    
    var workInterval: TimeInterval {
        get { defaults.double(forKey: Keys.workInterval) }
        set { defaults.set(newValue, forKey: Keys.workInterval) }
    }
    
    var breakDuration: TimeInterval {
        get { defaults.double(forKey: Keys.breakDuration) }
        set { defaults.set(newValue, forKey: Keys.breakDuration) }
    }
    
    private init() {
        // Register defaults
        defaults.register(defaults: [
            Keys.autoUpdateEnabled: false,
            Keys.runOnStartup: false,
            Keys.workInterval: 1200.0,
            Keys.breakDuration: 20.0
        ])
    }
}
