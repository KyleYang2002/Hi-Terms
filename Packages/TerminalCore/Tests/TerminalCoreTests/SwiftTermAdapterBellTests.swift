import XCTest
@testable import TerminalCore

/// Tests that SwiftTermAdapter forwards SwiftTerm's `bell` delegate callback
/// as a `ParserAction.bell` so higher layers (Wave1-C BellHandler) can decide
/// on audible/visual feedback. BEL = 0x07.
final class SwiftTermAdapterBellTests: XCTestCase {

    func testBELEmitsBellAction() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let recorder = ActionRecorder()
        adapter.delegate = recorder

        adapter.parse(data: Data([0x07])) // BEL

        XCTAssertTrue(recorder.actions.contains(where: { if case .bell = $0 { return true } else { return false } }),
                      "Single BEL byte must produce at least one ParserAction.bell")
    }

    func testMultipleBELsEmitMultipleBellActions() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let recorder = ActionRecorder()
        adapter.delegate = recorder

        adapter.parse(data: Data([0x07, 0x07, 0x07]))

        let bellCount = recorder.actions.filter {
            if case .bell = $0 { return true } else { return false }
        }.count
        XCTAssertEqual(bellCount, 3, "Three BEL bytes must produce three .bell actions")
    }

    func testBELMixedWithTextEmitsBellAndPreservesText() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let recorder = ActionRecorder()
        adapter.delegate = recorder

        var payload = Data("hi".utf8)
        payload.append(0x07)
        payload.append(contentsOf: Data("there".utf8))
        adapter.parse(data: payload)

        XCTAssertTrue(recorder.actions.contains(where: { if case .bell = $0 { return true } else { return false } }),
                      "BEL embedded in a text run must still emit .bell")
        let row0 = (0..<adapter.terminal.cols)
            .map { String(adapter.getCell(col: $0, row: 0).character) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(row0.contains("hithere"),
                      "Surrounding text must still land on row 0 (BEL is non-printing)")
    }
}

// MARK: - Test helpers

private final class ActionRecorder: TerminalParserDelegate {
    var actions: [ParserAction] = []

    func parser(_ parser: any TerminalParser, didReceiveAction action: ParserAction) {
        actions.append(action)
    }
}
