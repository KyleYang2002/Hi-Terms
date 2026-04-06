import Foundation

/// Orchestrates the data pipeline: PTY -> Parser -> ScreenBuffer -> Renderer.
///
/// Defined in TerminalCore so that Session (also in TerminalCore) can hold
/// a pipeline reference without depending on TerminalUI.
/// Concrete implementations (e.g., DefaultTerminalPipeline) live in TerminalUI.
public protocol TerminalPipeline: AnyObject {
    var parser: any TerminalParser { get }
    var screenBuffer: ScreenBuffer { get }

    func start()
    func stop()
    func write(data: Data)
    func resize(cols: Int, rows: Int)
}
