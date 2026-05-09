import XCTest
@testable import TerminalCore

/// Tests for SwiftTermAdapter: send callback, rangeChanged, scrollback, delegate forwarding.
/// All SwiftTerm callbacks fire synchronously during `parse`, so no expectations are needed.
final class SwiftTermAdapterTests: XCTestCase {

    // MARK: - A2: send() callback

    func testSendHandlerReceivesData() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)

        var receivedData: Data?
        adapter.sendHandler = { data in
            receivedData = data
        }

        adapter.parse(data: Data([0x1B, 0x5B, 0x63])) // ESC[c — DA query

        XCTAssertNotNil(receivedData, "sendHandler should receive DA response data")
        XCTAssertFalse(receivedData!.isEmpty, "DA response should not be empty")
    }

    // MARK: - A4: rangeChanged callback

    func testRangeChangedHandlerReceivesRowRange() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)

        var receivedStartY: Int?
        var receivedEndY: Int?
        adapter.rangeChangedHandler = { startY, endY in
            receivedStartY = startY
            receivedEndY = endY
        }

        adapter.parse(data: "Hello".data(using: .utf8)!)

        XCTAssertNotNil(receivedStartY, "rangeChangedHandler should be called")
        XCTAssertNotNil(receivedEndY, "rangeChangedHandler should provide endY")
        XCTAssertGreaterThanOrEqual(receivedEndY!, receivedStartY!,
                                    "endY should be >= startY")
    }

    // MARK: - A3: scrollback support

    func testScrollbackSnapshotReturnsHistoryLines() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 5)

        for i in 1...10 {
            adapter.parse(data: "Line \(i)\r\n".data(using: .utf8)!)
        }

        let current = adapter.createSnapshot(scrollbackOffset: 0)
        XCTAssertTrue(current.cursor.visible, "Cursor should be visible in current viewport")

        let scrolled = adapter.createSnapshot(scrollbackOffset: 3)
        XCTAssertFalse(scrolled.cursor.visible, "Cursor should be hidden in scrollback mode")

        let currentFirstRow = (0..<current.cols).map { String(current[0, $0].character) }.joined()
        let scrolledFirstRow = (0..<scrolled.cols).map { String(scrolled[0, $0].character) }.joined()
        XCTAssertNotEqual(currentFirstRow.trimmingCharacters(in: .whitespaces),
                         scrolledFirstRow.trimmingCharacters(in: .whitespaces),
                         "Scrollback should show different lines than current viewport")
    }

    func testScrollbackOffsetClampedToAvailable() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 5)
        let snapshot = adapter.createSnapshot(scrollbackOffset: 100)
        XCTAssertTrue(snapshot.cursor.visible,
                      "With no scrollback history, cursor should remain visible (offset clamped to 0)")
    }

    func testRangeChangedPreservesParserDelegate() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)

        let testDelegate = TestParserDelegate()
        adapter.delegate = testDelegate

        adapter.parse(data: "Hello".data(using: .utf8)!)

        XCTAssertTrue(testDelegate.actionReceived,
                      "TerminalParserDelegate should still receive .bufferUpdated")
    }

    // MARK: - Color SGR parsing → Cell.attributes

    /// Feeds an SGR escape + literal text and returns the first cell of row 0.
    private func cellAfterSGR(_ sgr: String, char: String = "X") -> Cell {
        let adapter = SwiftTermAdapter(cols: 20, rows: 2)
        let payload = "\u{1B}[\(sgr)m\(char)"
        adapter.parse(data: payload.data(using: .utf8)!)
        return adapter.getCell(col: 0, row: 0)
    }

    func testSGRForegroundAnsi8MapsToAnsi256() {
        // SGR 31 = red foreground. SwiftTerm exposes 0-7 as ansi256(code:).
        let cell = cellAfterSGR("31")
        XCTAssertEqual(cell.character, "X")
        XCTAssertEqual(cell.attributes.foregroundColor, .ansi256(code: 1))
    }

    func testSGRForegroundAnsi256IndexedColor() {
        // SGR 38;5;208 = orange (cube color)
        let cell = cellAfterSGR("38;5;208")
        XCTAssertEqual(cell.attributes.foregroundColor, .ansi256(code: 208))
    }

    func testSGRForegroundTrueColor() {
        // SGR 38;2;255;128;0 = orange via 24-bit RGB
        let cell = cellAfterSGR("38;2;255;128;0")
        XCTAssertEqual(cell.attributes.foregroundColor, .trueColor(r: 255, g: 128, b: 0))
    }

    func testSGRBackgroundTrueColor() {
        // SGR 48;2;10;20;30 = background true color
        let cell = cellAfterSGR("48;2;10;20;30")
        XCTAssertEqual(cell.attributes.backgroundColor, .trueColor(r: 10, g: 20, b: 30))
    }

    func testSGRGrayscaleAnsi256() {
        // SGR 38;5;240 = mid grayscale (index 240 → value 8 + 8*10 = 88)
        let cell = cellAfterSGR("38;5;240")
        XCTAssertEqual(cell.attributes.foregroundColor, .ansi256(code: 240))
    }

    func testSGRBoldPlusTrueColorPreservesBoth() {
        // SGR 1 = bold; combined with true color must keep both attributes.
        let cell = cellAfterSGR("1;38;2;100;200;50")
        XCTAssertTrue(cell.attributes.bold)
        XCTAssertEqual(cell.attributes.foregroundColor, .trueColor(r: 100, g: 200, b: 50))
    }

    // MARK: - Bracketed Paste Mode (DECSET 2004)

    func testBracketedPasteModeDefaultOff() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        XCTAssertFalse(adapter.terminal.bracketedPasteMode)
    }

    func testBracketedPasteModeEnableThenDisable() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)

        // Enable: ESC [ ? 2 0 0 4 h
        adapter.parse(data: "\u{1B}[?2004h".data(using: .utf8)!)
        XCTAssertTrue(adapter.terminal.bracketedPasteMode,
                      "DECSET 2004 (h) should enable bracketed paste mode")

        // Disable: ESC [ ? 2 0 0 4 l
        adapter.parse(data: "\u{1B}[?2004l".data(using: .utf8)!)
        XCTAssertFalse(adapter.terminal.bracketedPasteMode,
                       "DECRST 2004 (l) should disable bracketed paste mode")
    }

    // MARK: - Cursor style (DECSCUSR)

    func testDefaultCursorStyleIsBlinkingBlock() {
        // SwiftTerm's TerminalOptions defaults to `.blinkBlock`. The adapter
        // must surface that on every fresh snapshot so the renderer attaches
        // the blink animation without any extra setup.
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let snapshot = adapter.createSnapshot()
        XCTAssertEqual(snapshot.cursor.style, .blinkingBlock)
    }

    func testDECSCUSRSteadyBlock() {
        // CSI 2 SP q  →  steady block (no blink)
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1B}[2 q".data(using: .utf8)!)
        XCTAssertEqual(adapter.createSnapshot().cursor.style, .block)
    }

    func testDECSCUSRBlinkUnderline() {
        // CSI 3 SP q  →  blinking underline
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1B}[3 q".data(using: .utf8)!)
        XCTAssertEqual(adapter.createSnapshot().cursor.style, .blinkingUnderline)
    }

    func testDECSCUSRSteadyBar() {
        // CSI 6 SP q  →  steady bar
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1B}[6 q".data(using: .utf8)!)
        XCTAssertEqual(adapter.createSnapshot().cursor.style, .bar)
    }

    func testDECSCUSRTriggersRangeChanged() {
        // A bare DECSCUSR sequence emits no glyphs, so without an explicit
        // rangeChanged hook the cursor row would never repaint at the new
        // style. The adapter must mark the cursor's row dirty.
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        var changes: [(Int, Int)] = []
        adapter.rangeChangedHandler = { changes.append(($0, $1)) }

        adapter.parse(data: "\u{1B}[2 q".data(using: .utf8)!)

        XCTAssertFalse(changes.isEmpty,
                       "DECSCUSR must trigger a rangeChanged callback so the renderer redraws")
    }

    // MARK: - Alternate Screen Buffer (DECSET 1049)

    func testAlternateBufferDefaultOff() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        XCTAssertFalse(adapter.terminal.isCurrentBufferAlternate)
    }

    func testAlternateBufferEnableThenDisablePreservesPrimaryBuffer() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 5)

        // Write content to primary buffer
        adapter.parse(data: "primary line\r\n".data(using: .utf8)!)
        XCTAssertTrue(rowText(adapter, row: 0).contains("primary"),
                      "precondition: primary buffer should contain 'primary'")

        // Switch to alternate buffer (1049 = save cursor + clear alt + switch)
        // Then home the cursor so the next write lands at a known location.
        adapter.parse(data: "\u{1B}[?1049h\u{1B}[H".data(using: .utf8)!)
        XCTAssertTrue(adapter.terminal.isCurrentBufferAlternate,
                      "DECSET 1049 (h) should switch to alternate buffer")
        XCTAssertFalse(rowText(adapter, row: 0).contains("primary"),
                       "alt buffer should be cleared on enter, must not show primary content")

        adapter.parse(data: "alt line".data(using: .utf8)!)
        XCTAssertTrue(rowText(adapter, row: 0).contains("alt"),
                      "alt buffer row 0 should display 'alt line' after homing the cursor")

        // Switch back to primary buffer (1049 also restores cursor)
        adapter.parse(data: "\u{1B}[?1049l".data(using: .utf8)!)
        XCTAssertFalse(adapter.terminal.isCurrentBufferAlternate,
                       "DECRST 1049 (l) should switch back to primary buffer")

        // Primary buffer row 0 must still hold its original content (TUI restore behavior)
        XCTAssertTrue(rowText(adapter, row: 0).contains("primary"),
                      "primary buffer must be preserved across alt-screen toggle")
    }

    /// Concatenates a row's characters and trims trailing whitespace.
    private func rowText(_ adapter: SwiftTermAdapter, row: Int) -> String {
        (0..<adapter.terminal.cols)
            .map { String(adapter.getCell(col: $0, row: row).character) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - DECTCEM (cursor show/hide, ?25 h/l)

    func testCursorVisibleByDefault() {
        // Fresh adapter must report a visible cursor before any DECTCEM input.
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        XCTAssertTrue(adapter.createSnapshot().cursor.visible,
                      "Cursor should be visible by default on a fresh adapter")
    }

    func testCursorHiddenViaDECTCEM() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1B}[?25l".data(using: .utf8)!)
        XCTAssertFalse(adapter.createSnapshot().cursor.visible,
                       "DECRST 25 (?25l) should hide the cursor")
    }

    func testCursorShownViaDECTCEM() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1B}[?25l".data(using: .utf8)!)
        adapter.parse(data: "\u{1B}[?25h".data(using: .utf8)!)
        XCTAssertTrue(adapter.createSnapshot().cursor.visible,
                      "DECSET 25 (?25h) should re-show a previously hidden cursor")
    }

    func testDECTCEMTriggersRangeChanged() {
        // ?25l carries no glyphs, so without an explicit rangeChanged hook
        // the cursor row would never repaint. The adapter must mark the
        // cursor's row dirty so the renderer redraws it.
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        var changes: [(Int, Int)] = []
        adapter.rangeChangedHandler = { changes.append(($0, $1)) }

        adapter.parse(data: "\u{1B}[?25l".data(using: .utf8)!)

        XCTAssertFalse(changes.isEmpty,
                       "DECTCEM hide must trigger a rangeChanged callback")
        let y = adapter.terminal.buffer.y
        XCTAssertTrue(changes.contains(where: { $0.0 <= y && $0.1 >= y }),
                      "rangeChanged should cover the current cursor row (\(y))")
    }

    func testDECSTRSoftResetRestoresCursorVisible() {
        // Hide the cursor, then issue DECSTR (CSI ! p). The adapter must
        // resync to "visible" since SwiftTerm's cmdSoftReset clears
        // cursorHidden internally.
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1B}[?25l".data(using: .utf8)!)
        XCTAssertFalse(adapter.createSnapshot().cursor.visible)

        adapter.parse(data: "\u{1B}[!p".data(using: .utf8)!)
        XCTAssertTrue(adapter.createSnapshot().cursor.visible,
                      "DECSTR (CSI ! p) must restore cursor visibility")
    }

    func testMixedCSIWithCursorHide() {
        // Realistic TUI burst: set color, hide cursor, home, write text.
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1B}[31m\u{1B}[?25l\u{1B}[Hhello".data(using: .utf8)!)

        let snapshot = adapter.createSnapshot()
        XCTAssertFalse(snapshot.cursor.visible,
                       "Cursor must be hidden after a mixed CSI burst containing ?25l")

        let row0 = (0..<snapshot.cols).map { String(snapshot[0, $0].character) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(row0.contains("hello"),
                      "Row 0 should contain the literal text emitted after the CSI burst")
    }
}

// MARK: - Test helpers

private final class TestParserDelegate: TerminalParserDelegate {
    var actionReceived = false

    func parser(_ parser: any TerminalParser, didReceiveAction action: ParserAction) {
        actionReceived = true
    }
}
