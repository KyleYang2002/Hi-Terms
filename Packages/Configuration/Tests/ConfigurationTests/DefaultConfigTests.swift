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

    // MARK: - v0.0.5 visual / security knobs

    func testDefaultGutterAndHoverValues() {
        let config = DefaultConfig()
        XCTAssertEqual(config.gutterRunningAlpha, 0.45, accuracy: 0.0001)
        XCTAssertEqual(config.gutterSuccessAlpha, 0.55, accuracy: 0.0001)
        XCTAssertEqual(config.gutterFailureAlpha, 0.65, accuracy: 0.0001)
        XCTAssertEqual(config.gutterWidthPx, 3.0, accuracy: 0.0001)
        XCTAssertTrue(config.gutterSeparatorEnabled)
        XCTAssertEqual(config.hyperlinkSchemeAllowlist, ["http", "https", "file"])
        XCTAssertEqual(config.hoverMode, .always)
    }

    func testUserDefaultsConfigOverridesGutterAlphas() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set(0.9, forKey: "gutterRunningAlpha")
        defaults.set(1.0, forKey: "gutterSuccessAlpha")
        defaults.set(0.2, forKey: "gutterFailureAlpha")
        defaults.set(6.0, forKey: "gutterWidthPx")
        defaults.set(false, forKey: "gutterSeparatorEnabled")

        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.gutterRunningAlpha, 0.9, accuracy: 0.0001)
        XCTAssertEqual(config.gutterSuccessAlpha, 1.0, accuracy: 0.0001)
        XCTAssertEqual(config.gutterFailureAlpha, 0.2, accuracy: 0.0001)
        XCTAssertEqual(config.gutterWidthPx, 6.0, accuracy: 0.0001)
        XCTAssertFalse(config.gutterSeparatorEnabled,
                       "explicit `false` must beat fallback `true`")
    }

    func testUserDefaultsConfigOverridesHyperlinkAllowlist() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set(["http", "https", "ssh"], forKey: "hyperlinkSchemeAllowlist")
        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.hyperlinkSchemeAllowlist, ["http", "https", "ssh"])
    }

    func testUserDefaultsConfigEmptyAllowlistIsHonored() {
        // Empty array is meaningful: user disabled all schemes. We must not
        // coerce it back to the fallback set.
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set([String](), forKey: "hyperlinkSchemeAllowlist")
        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.hyperlinkSchemeAllowlist, [])
    }

    func testUserDefaultsConfigAllowlistIsLowercased() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set(["HTTP", "Https"], forKey: "hyperlinkSchemeAllowlist")
        let config = UserDefaultsConfig(defaults: defaults)
        XCTAssertEqual(config.hyperlinkSchemeAllowlist, ["http", "https"])
    }

    func testUserDefaultsConfigOverridesHoverMode() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("commandKey", forKey: "hoverMode")
        XCTAssertEqual(UserDefaultsConfig(defaults: defaults).hoverMode, .commandKey)

        defaults.set("off", forKey: "hoverMode")
        XCTAssertEqual(UserDefaultsConfig(defaults: defaults).hoverMode, .off)

        defaults.set("garbage", forKey: "hoverMode")
        XCTAssertEqual(UserDefaultsConfig(defaults: defaults).hoverMode, .always,
                       "unknown raw value must fall back to default")
    }
}
