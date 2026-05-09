import XCTest
@testable import TerminalCore

/// OSC 8 hyperlink payload propagation: SwiftTerm parses
/// `\e]8;params;URI\e\\TEXT\e]8;;\e\\` internally and attaches the URI to each
/// spanned cell's payload. `SwiftTermAdapter.getCell` / `readLine` must mirror
/// that into `Cell.hyperlinkURL`.
final class HyperlinkPayloadTests: XCTestCase {

    /// 5 cells of "HELLO" wrapped in OSC 8 ; ; <url> ST … OSC 8 ; ; ST should
    /// all carry the same URL. Text written **after** the close must not. Note
    /// that SwiftTerm's `oscHyperlink` close uses a closed-range `start...endCol`
    /// so the cell at the cursor's current position (col 5 here) is also marked;
    /// that is harmless because the cell is whitespace and never receives a
    /// glyph, but the next written character clears the payload.
    func testOSC8HyperlinkAttachesURLToSpannedCells() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // OSC 8 open + HELLO + OSC 8 close + WORLD (5 plain chars after close)
        let seq = "\u{1B}]8;;https://example.com\u{1B}\\HELLO\u{1B}]8;;\u{1B}\\WORLD"
        adapter.parse(data: Data(seq.utf8))

        let helloChars = Array("HELLO")
        for col in 0..<5 {
            let cell = adapter.getCell(col: col, row: 0)
            XCTAssertEqual(cell.character, helloChars[col],
                           "cell at col \(col) should hold the linked glyph")
            XCTAssertEqual(cell.hyperlinkURL, "https://example.com",
                           "cell at col \(col) should carry hyperlink URL")
        }

        let worldChars = Array("WORLD")
        for col in 5..<10 {
            let cell = adapter.getCell(col: col, row: 0)
            XCTAssertEqual(cell.character, worldChars[col - 5],
                           "post-link cell at col \(col) should hold the plain glyph")
            XCTAssertNil(cell.hyperlinkURL,
                         "text written after OSC 8 close must not carry URL (col \(col))")
        }
    }

    /// Plain text without OSC 8 must not gain a URL — guards against false
    /// positives from a stray payload on some unrelated SwiftTerm code path.
    func testCellsWithoutOSC8HaveNilHyperlink() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: Data("Hello".utf8))
        for col in 0..<5 {
            XCTAssertNil(adapter.getCell(col: col, row: 0).hyperlinkURL,
                         "plain text cell at col \(col) must have no URL")
        }
    }

    /// `OSC 8 ; id=foo ; <url> ST` — id parameter is informational only, the
    /// URL still lives in the second `;`-separated field. Adapter must
    /// surface only the URL, not the params.
    func testOSC8WithIDParameterStillExposesURL() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let seq = "\u{1B}]8;id=foo;https://example.com\u{1B}\\X\u{1B}]8;;\u{1B}\\"
        adapter.parse(data: Data(seq.utf8))
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.hyperlinkURL, "https://example.com")
    }

    /// `createSnapshot` reads cells via `readLine` (separate code path from
    /// `getCell`). Both must mirror the payload — otherwise renderer-side
    /// snapshots silently drop hyperlinks.
    func testSnapshotReadLineCarriesHyperlinkURL() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // AI is linked, then plain Z follows after the close
        let seq = "\u{1B}]8;;https://anthropic.com\u{1B}\\AI\u{1B}]8;;\u{1B}\\Z"
        adapter.parse(data: Data(seq.utf8))

        let snapshot = adapter.createSnapshot()
        XCTAssertEqual(snapshot[0, 0].hyperlinkURL, "https://anthropic.com")
        XCTAssertEqual(snapshot[0, 1].hyperlinkURL, "https://anthropic.com")
        XCTAssertEqual(snapshot[0, 2].character, "Z")
        XCTAssertNil(snapshot[0, 2].hyperlinkURL,
                     "plain text after close must not carry URL via snapshot path")
    }
}
