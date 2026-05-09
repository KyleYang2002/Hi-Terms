import Foundation

/// Orchestrates the data pipeline: PTY -> Parser -> ScreenBuffer -> Renderer.
///
/// Defined in TerminalCore so that Session (also in TerminalCore) can hold
/// a pipeline reference without depending on TerminalUI.
/// Concrete implementations (e.g., DefaultTerminalPipeline) live in TerminalUI.
public protocol TerminalPipeline: AnyObject {
    var parser: any TerminalParser { get }
    var screenBuffer: ScreenBuffer { get }

    /// Shell integration state aggregated from OSC 7 + OSC 133. Owned by the
    /// adapter and surfaced here so `Session` can expose it without taking a
    /// dependency on `SwiftTermAdapter`. V0.0.3 T1.
    var shellIntegration: ShellIntegrationState { get }

    func start()
    func stop()
    func write(data: Data)
    func resize(cols: Int, rows: Int)
}
