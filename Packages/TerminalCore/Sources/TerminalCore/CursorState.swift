import Foundation

/// Cursor visual style.
public enum CursorStyle: Sendable {
    case block
    case underline
    case bar
    case blinkingBlock
    case blinkingUnderline
    case blinkingBar
}

/// Terminal cursor position and appearance.
public struct CursorState: Equatable, Sendable {
    public var row: Int
    public var col: Int
    public var style: CursorStyle
    public var visible: Bool

    public init(row: Int = 0, col: Int = 0, style: CursorStyle = .block, visible: Bool = true) {
        self.row = row
        self.col = col
        self.style = style
        self.visible = visible
    }
}
