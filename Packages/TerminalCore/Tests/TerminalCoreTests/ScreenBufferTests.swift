import XCTest
@testable import TerminalCore

final class ScreenBufferTests: XCTestCase {
    func testCreateBufferWithDimensions() {
        let buffer = ScreenBuffer(rows: 25, cols: 80)
        XCTAssertEqual(buffer.rows, 25)
        XCTAssertEqual(buffer.cols, 80)
    }

    func testReadWriteCell() {
        let buffer = ScreenBuffer(rows: 25, cols: 80)
        let cell = Cell(
            character: "A",
            attributes: TextAttributes(bold: true, foregroundColor: .ansi256(code: 1))
        )
        buffer[0, 0] = cell
        let readBack = buffer[0, 0]
        XCTAssertEqual(readBack.character, "A")
        XCTAssertTrue(readBack.attributes.bold)
        XCTAssertEqual(readBack.attributes.foregroundColor, .ansi256(code: 1))
    }

    func testSnapshotIsIndependent() {
        let buffer = ScreenBuffer(rows: 25, cols: 80)
        buffer[0, 0] = Cell(character: "X")
        let snapshot = buffer.snapshot()
        // Mutate the live buffer after snapshot
        buffer[0, 0] = Cell(character: "Y")
        // Snapshot should still have the old value
        XCTAssertEqual(snapshot[0, 0].character, "X")
        // Live buffer should have the new value
        XCTAssertEqual(buffer[0, 0].character, "Y")
    }

    func testOutOfBoundsAccess() {
        let buffer = ScreenBuffer(rows: 2, cols: 2)
        // Reading out of bounds should return empty cell
        XCTAssertEqual(buffer[-1, 0], .empty)
        XCTAssertEqual(buffer[0, 5], .empty)
        XCTAssertEqual(buffer[10, 0], .empty)
    }

    func testDefaultCellIsSpace() {
        let buffer = ScreenBuffer(rows: 25, cols: 80)
        XCTAssertEqual(buffer[0, 0].character, " ")
        XCTAssertEqual(buffer[0, 0].attributes, .default)
    }
}
