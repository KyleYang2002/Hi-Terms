import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit

/// Orchestrates the data pipeline: PTY -> Parser -> ScreenBuffer -> Renderer.
///
/// V0.0 provides the protocol definition and a stub implementation.
/// V0.1 will add the full pipeline with CADisplayLink-driven rendering.
public protocol TerminalPipeline: AnyObject {
    var parser: any TerminalParser { get }
    var screenBuffer: ScreenBuffer { get }

    func start()
    func stop()
    func write(data: Data)
    func resize(cols: Int, rows: Int)
}

/// Stub implementation for V0.0. Does nothing — exists to verify
/// the protocol compiles and the module dependency graph is correct.
public final class TerminalPipelineStub: TerminalPipeline {
    public let parser: any TerminalParser
    public let screenBuffer: ScreenBuffer

    public init(parser: any TerminalParser, screenBuffer: ScreenBuffer) {
        self.parser = parser
        self.screenBuffer = screenBuffer
    }

    public func start() {}
    public func stop() {}
    public func write(data: Data) {}
    public func resize(cols: Int, rows: Int) {}
}
