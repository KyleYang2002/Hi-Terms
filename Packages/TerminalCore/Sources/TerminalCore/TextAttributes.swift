import Foundation

/// Terminal color representation.
public enum TerminalColor: Equatable, Sendable {
    case `default`
    case defaultInverted
    case ansi256(code: UInt8)
    case trueColor(r: UInt8, g: UInt8, b: UInt8)
}

/// Text styling attributes for a terminal cell.
public struct TextAttributes: Equatable, Sendable {
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var inverse: Bool
    public var invisible: Bool
    public var dim: Bool
    public var foregroundColor: TerminalColor
    public var backgroundColor: TerminalColor

    public init(
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        inverse: Bool = false,
        invisible: Bool = false,
        dim: Bool = false,
        foregroundColor: TerminalColor = .default,
        backgroundColor: TerminalColor = .default
    ) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.inverse = inverse
        self.invisible = invisible
        self.dim = dim
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }

    public static let `default` = TextAttributes()
}
