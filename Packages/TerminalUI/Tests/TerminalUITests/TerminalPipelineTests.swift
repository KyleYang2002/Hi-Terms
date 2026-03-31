import XCTest
@testable import TerminalUI
import TerminalCore

/// Minimal stub parser for testing pipeline instantiation.
private class StubParser: TerminalParser {
    weak var delegate: TerminalParserDelegate?
    func parse(data: Data) {}
}

final class TerminalPipelineTests: XCTestCase {
    func testStubInstantiation() {
        let parser = StubParser()
        let buffer = ScreenBuffer(rows: 25, cols: 80)
        let pipeline = TerminalPipelineStub(parser: parser, screenBuffer: buffer)

        // Verify the stub can be created and its properties are accessible
        XCTAssertNotNil(pipeline.parser)
        XCTAssertEqual(pipeline.screenBuffer.rows, 25)
        XCTAssertEqual(pipeline.screenBuffer.cols, 80)

        // Verify stub methods don't crash
        pipeline.start()
        pipeline.stop()
        pipeline.write(data: Data([0x41]))
        pipeline.resize(cols: 120, rows: 40)
    }
}
