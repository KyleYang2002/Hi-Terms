import XCTest
@testable import TerminalCore

final class CellTests: XCTestCase {
    func testCellCreation() {
        let cell = Cell(character: "H", attributes: .default)
        XCTAssertEqual(cell.character, "H")
        XCTAssertEqual(cell.attributes, .default)
    }

    func testCellEquality() {
        let a = Cell(character: "A", attributes: TextAttributes(bold: true))
        let b = Cell(character: "A", attributes: TextAttributes(bold: true))
        let c = Cell(character: "B", attributes: TextAttributes(bold: true))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testEmptyCell() {
        let empty = Cell.empty
        XCTAssertEqual(empty.character, " ")
        XCTAssertEqual(empty.attributes, .default)
    }

    func testTextAttributesDefault() {
        let attrs = TextAttributes.default
        XCTAssertFalse(attrs.bold)
        XCTAssertFalse(attrs.italic)
        XCTAssertFalse(attrs.underline)
        XCTAssertEqual(attrs.foregroundColor, .default)
        XCTAssertEqual(attrs.backgroundColor, .default)
    }

    func testTerminalColorEquality() {
        XCTAssertEqual(TerminalColor.ansi256(code: 1), TerminalColor.ansi256(code: 1))
        XCTAssertNotEqual(TerminalColor.ansi256(code: 1), TerminalColor.ansi256(code: 2))
        XCTAssertEqual(
            TerminalColor.trueColor(r: 255, g: 0, b: 0),
            TerminalColor.trueColor(r: 255, g: 0, b: 0)
        )
    }
}
