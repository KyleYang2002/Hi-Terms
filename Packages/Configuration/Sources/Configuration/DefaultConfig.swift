import Foundation

/// Hardcoded default configuration values.
public struct DefaultConfig: AppConfig, Sendable {
    public let fontName: String = "Menlo"
    public let fontSize: CGFloat = 13
    public let shellPath: String
    public let scrollbackLines: Int = 10_000
    public let terminalCols: Int = 80
    public let terminalRows: Int = 25

    public init() {
        self.shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
