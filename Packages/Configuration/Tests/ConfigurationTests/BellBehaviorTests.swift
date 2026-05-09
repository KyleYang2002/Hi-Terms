import XCTest
@testable import Configuration

final class BellBehaviorTests: XCTestCase {
    func testDefaultBellBehaviorIsVisual() {
        let config = DefaultConfig()
        XCTAssertEqual(config.bellBehavior, .visual)
    }

    func testUserDefaultsConfigParsesValidValue() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("silent", forKey: "bellBehavior")

        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.bellBehavior, .silent)
    }

    func testUserDefaultsConfigParsesVisualAndNotification() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("visualAndNotification", forKey: "bellBehavior")

        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.bellBehavior, .visualAndNotification)
    }

    func testUserDefaultsConfigFallsBackOnInvalid() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("bogus", forKey: "bellBehavior")

        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.bellBehavior, DefaultConfig().bellBehavior)
        XCTAssertEqual(config.bellBehavior, .visual)
    }

    func testUserDefaultsConfigFallsBackWhenMissing() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.bellBehavior, DefaultConfig().bellBehavior)
        XCTAssertEqual(config.bellBehavior, .visual)
    }

    func testAllCasesRoundTripThroughRawValue() {
        for behavior in BellBehavior.allCases {
            XCTAssertEqual(BellBehavior(rawValue: behavior.rawValue), behavior)
        }
    }
}
