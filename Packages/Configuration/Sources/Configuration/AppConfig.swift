import Foundation

/// Protocol for application configuration.
public protocol AppConfig {
    var fontName: String { get }
    var fontSize: CGFloat { get }
    var shellPath: String { get }
    var scrollbackLines: Int { get }
    var terminalCols: Int { get }
    var terminalRows: Int { get }
    var terminalType: String { get }
    var bellBehavior: BellBehavior { get }

    // MARK: - Visual / security knobs (v0.0.5)

    /// Alpha for the gutter band of a running command (status=running).
    var gutterRunningAlpha: Double { get }
    /// Alpha for the gutter band of a successfully completed command.
    var gutterSuccessAlpha: Double { get }
    /// Alpha for the gutter band of a failed command.
    var gutterFailureAlpha: Double { get }
    /// Width of the colored gutter strip in pixels.
    var gutterWidthPx: CGFloat { get }
    /// Whether to draw the 1px hairline at the top of a prompt row.
    var gutterSeparatorEnabled: Bool { get }

    /// URL schemes accepted by the OSC 8 / bare-text hyperlink opener.
    /// `file` is always cwd-gated regardless of presence in this set.
    var hyperlinkSchemeAllowlist: Set<String> { get }

    /// When the hover underline / cursor is shown for hyperlinks and paths.
    var hoverMode: HoverMode { get }
}
