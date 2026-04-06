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
}
