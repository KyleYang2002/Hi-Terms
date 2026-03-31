import Foundation

/// Actions emitted by the terminal parser.
public enum ParserAction {
    case printText(String)
    case moveCursor(row: Int, col: Int)
    case setAttribute(TextAttributes)
    case scroll(lines: Int)
    case eraseInDisplay(mode: Int)
    case eraseInLine(mode: Int)
    case lineFeed
    case carriageReturn
    case bell
    case bufferUpdated
}

/// Delegate that receives parser actions.
public protocol TerminalParserDelegate: AnyObject {
    func parser(_ parser: any TerminalParser, didReceiveAction action: ParserAction)
}

/// Protocol for terminal escape sequence parsers.
///
/// Implementations are stateful and process raw byte streams from PTY output,
/// emitting `ParserAction` values via the delegate. The canonical implementation
/// wraps SwiftTerm's `Terminal` type.
public protocol TerminalParser: AnyObject {
    var delegate: TerminalParserDelegate? { get set }
    func parse(data: Data)
}
