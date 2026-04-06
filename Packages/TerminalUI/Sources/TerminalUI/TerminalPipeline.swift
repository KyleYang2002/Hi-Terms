import Foundation
import TerminalCore

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
