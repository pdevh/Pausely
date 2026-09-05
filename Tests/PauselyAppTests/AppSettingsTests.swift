import XCTest
@testable import Pausely

final class AppSettingsTests: XCTestCase {
    func testCustomSettingsSurviveReload() throws {
        let name = "PauselyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.workInterval = 1517
        settings.breakDuration = 37
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.workInterval, 1517)
        XCTAssertEqual(reloaded.breakDuration, 37)
    }

    func testInvalidStoredDurationsUseDefaults() throws {
        let name = "PauselyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0, forKey: "workInterval")
        defaults.set(86401, forKey: "breakDuration")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.workInterval, 1200)
        XCTAssertEqual(settings.breakDuration, 20)
    }
}
