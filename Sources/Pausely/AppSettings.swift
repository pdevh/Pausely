import Foundation
import PauselyCore

class AppSettings {
    static let shared = AppSettings()
    
    private let defaults: UserDefaults
    
    private enum Keys {
        static let runOnStartup = "runOnStartup"
        static let workInterval = "workInterval"
        static let breakDuration = "breakDuration"
    }
    
    var runOnStartup: Bool {
        get { defaults.bool(forKey: Keys.runOnStartup) }
        set { defaults.set(newValue, forKey: Keys.runOnStartup) }
    }
    
    var workInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.workInterval)
            return DurationValue.isValid(value) ? value : 1200
        }
        set { defaults.set(newValue, forKey: Keys.workInterval) }
    }
    
    var breakDuration: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.breakDuration)
            return DurationValue.isValid(value) ? value : 20
        }
        set { defaults.set(newValue, forKey: Keys.breakDuration) }
    }
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Register defaults
        defaults.register(defaults: [
            Keys.runOnStartup: false,
            Keys.workInterval: 1200.0,
            Keys.breakDuration: 20.0
        ])
    }
}
