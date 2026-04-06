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
}
