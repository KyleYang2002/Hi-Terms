import Foundation

/// UserDefaults-backed configuration with fallback to defaults.
public final class UserDefaultsConfig: AppConfig {
    private let defaults: UserDefaults
    private let fallback = DefaultConfig()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var fontName: String {
        defaults.string(forKey: "fontName") ?? fallback.fontName
    }

    public var fontSize: CGFloat {
        let value = defaults.double(forKey: "fontSize")
        return value > 0 ? value : fallback.fontSize
    }

    public var shellPath: String {
        defaults.string(forKey: "shellPath") ?? fallback.shellPath
    }

    public var scrollbackLines: Int {
        let value = defaults.integer(forKey: "scrollbackLines")
        return value > 0 ? value : fallback.scrollbackLines
    }

    public var terminalCols: Int {
        let value = defaults.integer(forKey: "terminalCols")
        return value > 0 ? value : fallback.terminalCols
    }

    public var terminalRows: Int {
        let value = defaults.integer(forKey: "terminalRows")
        return value > 0 ? value : fallback.terminalRows
    }

    public var terminalType: String {
        defaults.string(forKey: "terminalType") ?? fallback.terminalType
    }

    public var bellBehavior: BellBehavior {
        guard let raw = defaults.string(forKey: "bellBehavior"),
              let value = BellBehavior(rawValue: raw) else {
            return fallback.bellBehavior
        }
        return value
    }

    // MARK: - v0.0.5 visual / security knobs

    public var gutterRunningAlpha: Double {
        positiveDouble(forKey: "gutterRunningAlpha", fallback: fallback.gutterRunningAlpha)
    }

    public var gutterSuccessAlpha: Double {
        positiveDouble(forKey: "gutterSuccessAlpha", fallback: fallback.gutterSuccessAlpha)
    }

    public var gutterFailureAlpha: Double {
        positiveDouble(forKey: "gutterFailureAlpha", fallback: fallback.gutterFailureAlpha)
    }

    public var gutterWidthPx: CGFloat {
        let value = defaults.double(forKey: "gutterWidthPx")
        return value > 0 ? CGFloat(value) : fallback.gutterWidthPx
    }

    public var gutterSeparatorEnabled: Bool {
        // Distinguish "never set" (use fallback) from "explicitly false".
        guard defaults.object(forKey: "gutterSeparatorEnabled") != nil else {
            return fallback.gutterSeparatorEnabled
        }
        return defaults.bool(forKey: "gutterSeparatorEnabled")
    }

    public var hyperlinkSchemeAllowlist: Set<String> {
        // `nil` = unset → fallback. An empty array is honored as "user disabled
        // all schemes" rather than coerced back to the default.
        guard let raw = defaults.stringArray(forKey: "hyperlinkSchemeAllowlist") else {
            return fallback.hyperlinkSchemeAllowlist
        }
        return Set(raw.map { $0.lowercased() })
    }

    public var hoverMode: HoverMode {
        guard let raw = defaults.string(forKey: "hoverMode"),
              let value = HoverMode(rawValue: raw) else {
            return fallback.hoverMode
        }
        return value
    }

    // MARK: - Helpers

    private func positiveDouble(forKey key: String, fallback fallbackValue: Double) -> Double {
        let value = defaults.double(forKey: key)
        return value > 0 ? value : fallbackValue
    }
}
