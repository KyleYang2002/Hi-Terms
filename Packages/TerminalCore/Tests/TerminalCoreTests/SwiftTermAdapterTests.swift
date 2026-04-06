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
}

// MARK: - Test helpers

private final class TestParserDelegate: TerminalParserDelegate {
    var actionReceived = false

    func parser(_ parser: any TerminalParser, didReceiveAction action: ParserAction) {
        actionReceived = true
    }
}
