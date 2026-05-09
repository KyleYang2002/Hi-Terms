import Foundation

/// Hardcoded default configuration values.
public struct DefaultConfig: AppConfig, Sendable {
    public let fontName: String = "Menlo"
    public let fontSize: CGFloat = 13
    public let shellPath: String
    public let scrollbackLines: Int = 10_000
    public let terminalCols: Int = 80
    public let terminalRows: Int = 25
    public let terminalType: String = "xterm-256color"
    public let bellBehavior: BellBehavior = .visual

    public let gutterRunningAlpha: Double = 0.45
    public let gutterSuccessAlpha: Double = 0.55
    public let gutterFailureAlpha: Double = 0.65
    public let gutterWidthPx: CGFloat = 3.0
    public let gutterSeparatorEnabled: Bool = true

    public let hyperlinkSchemeAllowlist: Set<String> = ["http", "https", "file"]
    public let hoverMode: HoverMode = .always

    public init() {
        self.shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
