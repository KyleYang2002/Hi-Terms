import XCTest
@testable import TerminalCore

final class RowTextBuilderTests: XCTestCase {
    // MARK: - Fixtures

    private func makeSnapshot(rows lines: [String], cols: Int) -> ScreenBufferSnapshot {
        let buffer = ScreenBuffer(rows: lines.count, cols: cols)
        for (row, text) in lines.enumerated() {
            var col = 0
            for ch in text {
                guard col < cols else { break }
                if isWide(ch) {
                    if col + 1 >= cols { break }
                    buffer[row, col] = Cell(character: ch, attributes: .default, width: 2)
                    buffer[row, col + 1] = Cell(character: " ", attributes: .default, width: 0)
                    col += 2
                } else {
                    buffer[row, col] = Cell(character: ch, attributes: .default, width: 1)
                    col += 1
                }
            }
        }
        return buffer.snapshot()
    }

    private func isWide(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0xFF00...0xFF60).contains(v)
    }

    // MARK: - Plain ASCII

    func testBuildEmptyRowProducesEmptyText() {
        let snapshot = makeSnapshot(rows: [""], cols: 5)
        let row = RowTextBuilder.build(snapshot: snapshot, row: 0)
        // Each empty cell is " ", so produced text is 5 spaces.
        XCTAssertEqual(row.text, "     ")
        XCTAssertEqual(row.charCols, [0, 1, 2, 3, 4])
        XCTAssertEqual(row.cols, 5)
    }

    func testBuildAsciiTextProducesIdentityMapping() {
        let snapshot = makeSnapshot(rows: ["hello"], cols: 8)
        let row = RowTextBuilder.build(snapshot: snapshot, row: 0)
        // 5 chars + 3 trailing spaces (cells default to space)
        XCTAssertEqual(row.text, "hello   ")
        XCTAssertEqual(row.charCols, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    func testOutOfRangeRowReturnsEmpty() {
        let snapshot = makeSnapshot(rows: ["x"], cols: 4)
        let row = RowTextBuilder.build(snapshot: snapshot, row: 99)
        XCTAssertEqual(row.text, "")
        XCTAssertEqual(row.charCols, [])
        XCTAssertEqual(row.cols, 4)
    }

    // MARK: - CJK width handling

    func testCJKContinuationCellsAreSkipped() {
        let snapshot = makeSnapshot(rows: ["a你b"], cols: 6)
        // Layout: col0='a' w=1, col1='你' w=2, col2=' ' w=0, col3='b' w=1, col4..5 spaces
        let row = RowTextBuilder.build(snapshot: snapshot, row: 0)
        XCTAssertEqual(row.text, "a你b  ")
        XCTAssertEqual(row.charCols, [0, 1, 3, 4, 5])
    }

    func testCharIndexForColInsideCJKReturnsLeadChar() {
        let snapshot = makeSnapshot(rows: ["你x"], cols: 4)
        let row = RowTextBuilder.build(snapshot: snapshot, row: 0)
        // col 0 → 你 (lead), col 1 → 你 (continuation should map back to lead)
        let idx0 = row.charIndex(forCol: 0)
        let idx1 = row.charIndex(forCol: 1)
        XCTAssertNotNil(idx0)
        XCTAssertNotNil(idx1)
        XCTAssertEqual(row.text[idx0!], "你")
        XCTAssertEqual(row.text[idx1!], "你")
    }

    func testCharIndexForOutOfRangeReturnsNil() {
        let snapshot = makeSnapshot(rows: ["abc"], cols: 4)
        let row = RowTextBuilder.build(snapshot: snapshot, row: 0)
        XCTAssertNil(row.charIndex(forCol: -1))
        XCTAssertNil(row.charIndex(forCol: 4))
    }

    // MARK: - cellRange

    func testCellRangeForAsciiSlice() {
        let snapshot = makeSnapshot(rows: ["hello world"], cols: 12)
        let row = RowTextBuilder.build(snapshot: snapshot, row: 0)
        let lo = row.text.index(row.text.startIndex, offsetBy: 6)  // 'w'
        let hi = row.text.index(row.text.startIndex, offsetBy: 11) // after 'd'
        let r = row.cellRange(forCharRange: lo..<hi)
        XCTAssertEqual(r, 6...10)
    }

    func testCellRangeIncludesCJKContinuationCells() {
        let snapshot = makeSnapshot(rows: ["你好x"], cols: 6)
        let row = RowTextBuilder.build(snapshot: snapshot, row: 0)
        // text = "你好x  ", charCols = [0,2,4,5]
        let lo = row.text.startIndex
        let hi = row.text.index(row.text.startIndex, offsetBy: 2)  // [你, 好)
        let r = row.cellRange(forCharRange: lo..<hi)
        // 你 at col 0..1, 好 at col 2..3 → range should be 0...3
        XCTAssertEqual(r, 0...3)
    }
}
