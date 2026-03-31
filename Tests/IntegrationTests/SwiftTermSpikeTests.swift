import XCTest
import TerminalCore

/// SwiftTerm evaluation spike tests.
/// These tests verify the five evaluation dimensions for A04/A05.
final class SwiftTermSpikeTests: XCTestCase {

    // MARK: - Dimension 1: VT100/xterm Compatibility

    func testBasicTextOutput() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "Hello World".data(using: .utf8)!)
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "H")
        let cell4 = adapter.getCell(col: 4, row: 0)
        XCTAssertEqual(cell4.character, "o")
    }

    func testCursorPosition() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // CUP: ESC[5;10H moves cursor to row 5, col 10 (1-indexed)
        adapter.parse(data: "\u{1b}[5;10HA".data(using: .utf8)!)
        let cell = adapter.getCell(col: 9, row: 4) // 0-indexed
        XCTAssertEqual(cell.character, "A")
    }

    func testSGRAttributes() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // Bold + red foreground
        adapter.parse(data: "\u{1b}[1;31mX\u{1b}[0m".data(using: .utf8)!)
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "X")
        XCTAssertTrue(cell.attributes.bold)
    }

    func testEraseInDisplay() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "AAAA".data(using: .utf8)!)
        // ED mode 2: erase entire display
        adapter.parse(data: "\u{1b}[2J".data(using: .utf8)!)
        let cell = adapter.getCell(col: 0, row: 0)
        // After erase, cell should not be 'A' anymore
        XCTAssertNotEqual(cell.character, "A")
    }

    func testLineFeedAndCarriageReturn() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "AB\r\nCD".data(using: .utf8)!)
        let cellA = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cellA.character, "A")
        let cellC = adapter.getCell(col: 0, row: 1)
        XCTAssertEqual(cellC.character, "C")
    }

    func testScrollRegion() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // DECSTBM: set scroll region lines 1-5
        adapter.parse(data: "\u{1b}[1;5r".data(using: .utf8)!)
        // This should not crash
        adapter.parse(data: "Test".data(using: .utf8)!)
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "T")
    }

    func testInsertDeleteLines() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "Line1\r\nLine2\r\nLine3".data(using: .utf8)!)
        // Move to row 2 and insert a line
        adapter.parse(data: "\u{1b}[2;1H\u{1b}[1L".data(using: .utf8)!)
        // Line2 should have shifted down — the inserted line should not start with 'L'
        let cell = adapter.getCell(col: 0, row: 1)
        XCTAssertNotEqual(cell.character, "L", "Inserted line should be blank, not original Line2")
    }

    func test256Color() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // 256-color foreground (color 196 = bright red)
        adapter.parse(data: "\u{1b}[38;5;196mX\u{1b}[0m".data(using: .utf8)!)
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "X")
        XCTAssertEqual(cell.attributes.foregroundColor, .ansi256(code: 196))
    }

    // MARK: - Dimension 2: Parse Performance

    func testParsePerformance() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // Generate 1MB of mixed terminal data for a quick check
        var data = Data()
        let asciiLine = "The quick brown fox jumps over the lazy dog. 0123456789\r\n"
        let colorSeq = "\u{1b}[38;5;196mX\u{1b}[0m"
        let cursorMove = "\u{1b}[1;1H"

        for _ in 0..<10000 {
            data.append(asciiLine.data(using: .utf8)!)
            data.append(colorSeq.data(using: .utf8)!)
            data.append(cursorMove.data(using: .utf8)!)
        }

        let start = CFAbsoluteTimeGetCurrent()
        let chunkSize = 8192
        for offset in stride(from: 0, to: data.count, by: chunkSize) {
            let end = min(offset + chunkSize, data.count)
            adapter.parse(data: data[offset..<end])
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let throughputMBs = Double(data.count) / elapsed / 1_000_000

        print("Parse throughput: \(String(format: "%.1f", throughputMBs)) MB/s (\(data.count) bytes in \(String(format: "%.3f", elapsed))s)")
        // Log performance; no hard assertion for spike test
    }

    // MARK: - Dimension 3: Advanced Features

    func testAlternateScreenBuffer() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "Normal".data(using: .utf8)!)
        // Enable alternate screen
        adapter.parse(data: "\u{1b}[?1049h".data(using: .utf8)!)
        adapter.parse(data: "Alt".data(using: .utf8)!)
        // Restore normal screen
        adapter.parse(data: "\u{1b}[?1049l".data(using: .utf8)!)
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "N") // "Normal" restored
    }

    func testBracketedPasteMode() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "\u{1b}[?2004h".data(using: .utf8)!)
        XCTAssertTrue(adapter.terminal.bracketedPasteMode)
        adapter.parse(data: "\u{1b}[?2004l".data(using: .utf8)!)
        XCTAssertFalse(adapter.terminal.bracketedPasteMode)
    }

    func testTrueColor() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // True color foreground: RGB(255, 128, 0)
        adapter.parse(data: "\u{1b}[38;2;255;128;0mX\u{1b}[0m".data(using: .utf8)!)
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "X")
        XCTAssertEqual(cell.attributes.foregroundColor, .trueColor(r: 255, g: 128, b: 0))
    }

    // MARK: - Dimension 4: API Integrability

    func testTerminalParserProtocolConformance() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // Verify it conforms to TerminalParser
        let parser: any TerminalParser = adapter
        parser.parse(data: "Test".data(using: .utf8)!)
        // Should not crash and data should be processed
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "T")
    }

    func testParserProtocolInterface() {
        // Verify the TerminalParser protocol can be used polymorphically
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let parser: any TerminalParser = adapter

        // Protocol interface: parse data and delegate assignment
        parser.delegate = nil
        parser.parse(data: "Protocol test".data(using: .utf8)!)

        // Verify data was processed through the protocol interface
        let cell = adapter.getCell(col: 0, row: 0)
        XCTAssertEqual(cell.character, "P")

        // Verify snapshot creation works after protocol-based parsing
        let snapshot = adapter.createSnapshot()
        XCTAssertEqual(snapshot[0, 9].character, "t")
    }

    // MARK: - Dimension 5: ScreenBuffer Accessibility

    func testCellLevelDataAccess() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // Bold + underline + true color fg + true color bg
        adapter.parse(data: "\u{1b}[1;4;38;2;255;0;0;48;2;0;255;0mStyled\u{1b}[0m".data(using: .utf8)!)

        let expectedChars: [Character] = ["S", "t", "y", "l", "e", "d"]
        for (col, expected) in expectedChars.enumerated() {
            let cell = adapter.getCell(col: col, row: 0)
            XCTAssertEqual(cell.character, expected, "Character at col \(col)")
            XCTAssertTrue(cell.attributes.bold, "Bold at col \(col)")
            XCTAssertTrue(cell.attributes.underline, "Underline at col \(col)")
            XCTAssertEqual(cell.attributes.foregroundColor, .trueColor(r: 255, g: 0, b: 0), "FG at col \(col)")
            XCTAssertEqual(cell.attributes.backgroundColor, .trueColor(r: 0, g: 255, b: 0), "BG at col \(col)")
        }
    }

    func testSnapshotCreation() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: "Hello".data(using: .utf8)!)
        let snapshot = adapter.createSnapshot()
        XCTAssertEqual(snapshot.rows, 25)
        XCTAssertEqual(snapshot.cols, 80)
        XCTAssertEqual(snapshot[0, 0].character, "H")

        // Mutate and verify snapshot independence
        adapter.parse(data: "\u{1b}[2JAAAA".data(using: .utf8)!)
        XCTAssertEqual(snapshot[0, 0].character, "H") // Unchanged
    }
}
