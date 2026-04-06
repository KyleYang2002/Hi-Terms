import XCTest
@testable import Configuration

final class DefaultConfigTests: XCTestCase {
    func testDefaultValues() {
        let config = DefaultConfig()
        XCTAssertEqual(config.fontName, "Menlo")
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertFalse(config.shellPath.isEmpty)
        XCTAssertEqual(config.scrollbackLines, 10_000)
        XCTAssertEqual(config.terminalCols, 80)
        XCTAssertEqual(config.terminalRows, 25)
        XCTAssertEqual(config.terminalType, "xterm-256color")
    }

    func testUserDefaultsConfigFallback() {
        let config = UserDefaultsConfig(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        // With empty UserDefaults, should fall back to DefaultConfig values
        XCTAssertEqual(config.fontName, "Menlo")
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertEqual(config.terminalCols, 80)
    }

    func testUserDefaultsConfigCustomValues() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("SF Mono", forKey: "fontName")
        defaults.set(14.0, forKey: "fontSize")
        defaults.set(120, forKey: "terminalCols")
        defaults.set("/bin/bash", forKey: "shellPath")

        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.fontName, "SF Mono")
        XCTAssertEqual(config.fontSize, 14.0)
        XCTAssertEqual(config.terminalCols, 120)
        XCTAssertEqual(config.shellPath, "/bin/bash")
        // Non-overridden values fall back to defaults
        XCTAssertEqual(config.terminalRows, 25)
        XCTAssertEqual(config.scrollbackLines, 10_000)
    }
}
