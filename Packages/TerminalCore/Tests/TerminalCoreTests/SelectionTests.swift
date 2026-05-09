import XCTest
@testable import TerminalCore

final class SelectionTests: XCTestCase {
    // MARK: - normalize

    func testNormalizeSwapsWhenAnchorAfterHead() {
        let anchor = GridPoint(row: 5, col: 2)
        let head = GridPoint(row: 1, col: 9)
        let selection = Selection(anchor: anchor, head: head, mode: .character)
        let (start, end) = selection.normalized()
        XCTAssertEqual(start, head)
        XCTAssertEqual(end, anchor)
    }

    func testNormalizeSameRowReversedColumns() {
        let anchor = GridPoint(row: 3, col: 10)
        let head = GridPoint(row: 3, col: 4)
        let selection = Selection(anchor: anchor, head: head, mode: .character)
        let (start, end) = selection.normalized()
        XCTAssertEqual(start, head)
        XCTAssertEqual(end, anchor)
    }

    func testNormalizeKeepsOrderWhenAnchorBeforeHead() {
        let anchor = GridPoint(row: 1, col: 2)
        let head = GridPoint(row: 4, col: 0)
        let selection = Selection(anchor: anchor, head: head, mode: .character)
        let (start, end) = selection.normalized()
        XCTAssertEqual(start, anchor)
        XCTAssertEqual(end, head)
    }

    // MARK: - isEmpty

    func testIsEmptyOnlyWhenAnchorEqualsHeadInCharacterMode() {
        let p = GridPoint(row: 2, col: 2)
        let other = GridPoint(row: 2, col: 3)

        let emptyChar = Selection(anchor: p, head: p, mode: .character)
        XCTAssertTrue(emptyChar.isEmpty)

        let nonEmptyChar = Selection(anchor: p, head: other, mode: .character)
        XCTAssertFalse(nonEmptyChar.isEmpty)

        // Word and line modes are never considered empty even when collapsed.
        let wordSel = Selection(anchor: p, head: p, mode: .word)
        XCTAssertFalse(wordSel.isEmpty)

        let lineSel = Selection(anchor: p, head: p, mode: .line)
        XCTAssertFalse(lineSel.isEmpty)
    }

    // MARK: - geometry

    func testGeometryExpandSingleRow() {
        let selection = Selection(
            anchor: GridPoint(row: 4, col: 3),
            head: GridPoint(row: 4, col: 9),
            mode: .character
        )
        let segments = SelectionGeometry.expand(selection, cols: 80)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].row, 4)
        XCTAssertEqual(segments[0].cols, 3...9)
    }

    func testGeometryExpandMultiRow() {
        let cols = 80
        let selection = Selection(
            anchor: GridPoint(row: 2, col: 5),
            head: GridPoint(row: 4, col: 12),
            mode: .character
        )
        let segments = SelectionGeometry.expand(selection, cols: cols)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].row, 2)
        XCTAssertEqual(segments[0].cols, 5...(cols - 1))
        XCTAssertEqual(segments[1].row, 3)
        XCTAssertEqual(segments[1].cols, 0...(cols - 1))
        XCTAssertEqual(segments[2].row, 4)
        XCTAssertEqual(segments[2].cols, 0...12)
    }

    func testGeometryExpandLineMode() {
        let cols = 40
        let selection = Selection(
            anchor: GridPoint(row: 1, col: 7),
            head: GridPoint(row: 3, col: 2),
            mode: .line
        )
        let segments = SelectionGeometry.expand(selection, cols: cols)
        XCTAssertEqual(segments.count, 3)
        for (offset, segment) in segments.enumerated() {
            XCTAssertEqual(segment.row, 1 + offset)
            XCTAssertEqual(segment.cols, 0...(cols - 1))
        }
    }
}
