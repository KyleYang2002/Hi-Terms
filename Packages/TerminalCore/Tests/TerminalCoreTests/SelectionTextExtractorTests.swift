import XCTest
@testable import TerminalCore

final class SelectionTextExtractorTests: XCTestCase {
    // MARK: - Fixture helpers

    /// Build a `ScreenBufferSnapshot` from an array of plain strings.
    /// Each row is left-padded with spaces to `cols`. CJK fullwidth characters
    /// are detected via Unicode scalar ranges and emitted as a width=2 lead
    /// cell followed by a width=0 continuation cell, matching SwiftTerm's
    /// reported geometry.
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
        // Common CJK / fullwidth ranges sufficient for these tests.
        return (0x1100...0x115F).contains(v) ||      // Hangul Jamo
               (0x2E80...0x303E).contains(v) ||      // CJK Radicals / symbols
               (0x3041...0x33FF).contains(v) ||      // Hiragana / Katakana / CJK symbols
               (0x3400...0x4DBF).contains(v) ||      // CJK Ext A
               (0x4E00...0x9FFF).contains(v) ||      // CJK Unified Ideographs
               (0xA000...0xA4CF).contains(v) ||      // Yi Syllables
               (0xAC00...0xD7A3).contains(v) ||      // Hangul Syllables
               (0xF900...0xFAFF).contains(v) ||      // CJK Compat Ideographs
               (0xFE30...0xFE4F).contains(v) ||      // CJK Compat Forms
               (0xFF00...0xFF60).contains(v) ||      // Fullwidth forms
               (0xFFE0...0xFFE6).contains(v)
    }

    // MARK: - extract

    func testExtractTrimsTrailingSpacesWhenSelectionReachesRowEnd() {
        let cols = 10
        let snapshot = makeSnapshot(rows: ["hello"], cols: cols)
        // Select the whole row [0...9]; the row only has "hello" then 5 spaces.
        let selection = Selection(
            anchor: GridPoint(row: 0, col: 0),
            head: GridPoint(row: 0, col: cols - 1),
            mode: .character
        )
        let text = SelectionTextExtractor.extract(from: snapshot, selection: selection, cols: cols)
        XCTAssertEqual(text, "hello")
    }

    func testExtractKeepsInteriorSpaces() {
        let cols = 20
        let snapshot = makeSnapshot(rows: ["foo   bar"], cols: cols)
        // Select only "foo   bar" without reaching the right edge.
        let selection = Selection(
            anchor: GridPoint(row: 0, col: 0),
            head: GridPoint(row: 0, col: 8),
            mode: .character
        )
        let text = SelectionTextExtractor.extract(from: snapshot, selection: selection, cols: cols)
        XCTAssertEqual(text, "foo   bar")
    }

    func testExtractSkipsCJKContinuation() {
        let cols = 20
        // "你" at col 0 (width=2, continuation at col 1)
        // "好" at col 2 (width=2, continuation at col 3)
        // "world" starts at col 4
        let snapshot = makeSnapshot(rows: ["你好world"], cols: cols)
        // Select "好w": starts at col 2 (好 lead), ends at col 4 (w).
        let selection = Selection(
            anchor: GridPoint(row: 0, col: 2),
            head: GridPoint(row: 0, col: 4),
            mode: .character
        )
        let text = SelectionTextExtractor.extract(from: snapshot, selection: selection, cols: cols)
        XCTAssertEqual(text, "好w")
    }

    func testExtractMultiRowJoinsWithNewline() {
        let cols = 10
        let snapshot = makeSnapshot(rows: ["abc", "def", "ghi"], cols: cols)
        let selection = Selection(
            anchor: GridPoint(row: 0, col: 0),
            head: GridPoint(row: 2, col: 2),
            mode: .character
        )
        let text = SelectionTextExtractor.extract(from: snapshot, selection: selection, cols: cols)
        XCTAssertEqual(text, "abc\ndef\nghi")
    }

    func testExtractEmptyRowProducesBlankLine() {
        let cols = 10
        let snapshot = makeSnapshot(rows: ["foo", "", "bar"], cols: cols)
        let selection = Selection(
            anchor: GridPoint(row: 0, col: 0),
            head: GridPoint(row: 2, col: 2),
            mode: .character
        )
        let text = SelectionTextExtractor.extract(from: snapshot, selection: selection, cols: cols)
        XCTAssertEqual(text, "foo\n\nbar")
        XCTAssertTrue(text.contains("\n\n"))
    }

    func testExtractLineModeAppendsTrailingNewline() {
        let cols = 10
        let snapshot = makeSnapshot(rows: ["abc", "def"], cols: cols)
        let selection = Selection(
            anchor: GridPoint(row: 0, col: 0),
            head: GridPoint(row: 1, col: 0),
            mode: .line
        )
        let text = SelectionTextExtractor.extract(from: snapshot, selection: selection, cols: cols)
        XCTAssertEqual(text, "abc\ndef\n")
    }

    // MARK: - expandToWord

    func testExpandToWordIncludesAlnumAndPathChars() {
        let cols = 20
        // "foo bar/baz" — "bar/baz" spans cols 4...10 inclusive.
        let snapshot = makeSnapshot(rows: ["foo bar/baz"], cols: cols)
        for col in 4...10 {
            let (start, end) = SelectionTextExtractor.expandToWord(
                at: GridPoint(row: 0, col: col),
                in: snapshot,
                cols: cols
            )
            XCTAssertEqual(start, 4, "wrong start at col \(col)")
            XCTAssertEqual(end, 10, "wrong end at col \(col)")
        }
    }

    func testExpandToWordStopsAtWhitespace() {
        let cols = 20
        // "foo bar" — "bar" spans cols 4...6.
        let snapshot = makeSnapshot(rows: ["foo bar"], cols: cols)
        let (start, end) = SelectionTextExtractor.expandToWord(
            at: GridPoint(row: 0, col: 5),
            in: snapshot,
            cols: cols
        )
        XCTAssertEqual(start, 4)
        XCTAssertEqual(end, 6)
    }

    func testExpandToWordReturnsPointWhenLandingOnWhitespace() {
        let cols = 20
        let snapshot = makeSnapshot(rows: ["foo bar"], cols: cols)
        let (start, end) = SelectionTextExtractor.expandToWord(
            at: GridPoint(row: 0, col: 3), // the space
            in: snapshot,
            cols: cols
        )
        XCTAssertEqual(start, 3)
        XCTAssertEqual(end, 3)
    }
}
