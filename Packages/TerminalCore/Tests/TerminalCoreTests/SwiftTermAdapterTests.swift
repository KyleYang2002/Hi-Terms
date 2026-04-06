import XCTest
@testable import TerminalCore

final class SwiftTermAdapterTests: XCTestCase {

    // MARK: - A2: send() callback

    func testSendHandlerReceivesData() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let expectation = expectation(description: "sendHandler called")

        var receivedData: Data?
        adapter.sendHandler = { data in
            receivedData = data
            expectation.fulfill()
        }

        // Send DA (Device Attributes) query — SwiftTerm responds with a DA reply
        adapter.parse(data: Data([0x1B, 0x5B, 0x63])) // ESC[c

        waitForExpectations(timeout: 1)
        XCTAssertNotNil(receivedData, "sendHandler should receive DA response data")
        XCTAssertFalse(receivedData!.isEmpty, "DA response should not be empty")
    }

    // MARK: - A4: rangeChanged callback

    func testRangeChangedHandlerReceivesRowRange() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let expectation = expectation(description: "rangeChangedHandler called")
        expectation.assertForOverFulfill = false

        var receivedStartY: Int?
        var receivedEndY: Int?
        adapter.rangeChangedHandler = { startY, endY in
            receivedStartY = startY
            receivedEndY = endY
            expectation.fulfill()
        }

        // Write text to row 0 — should trigger rangeChanged for that row
        adapter.parse(data: "Hello".data(using: .utf8)!)

        waitForExpectations(timeout: 1)
        XCTAssertNotNil(receivedStartY, "rangeChangedHandler should be called")
        XCTAssertNotNil(receivedEndY, "rangeChangedHandler should provide endY")
        XCTAssertGreaterThanOrEqual(receivedEndY!, receivedStartY!,
                                    "endY should be >= startY")
    }

    // MARK: - A3: scrollback support

    func testScrollbackSnapshotReturnsHistoryLines() {
        // Create a small terminal (80x5) so scrollback triggers quickly
        let adapter = SwiftTermAdapter(cols: 80, rows: 5)

        // Feed 10 lines — first 5 will scroll into history
        for i in 1...10 {
            adapter.parse(data: "Line \(i)\r\n".data(using: .utf8)!)
        }

        // Current viewport (offset 0) should show later lines
        let current = adapter.createSnapshot(scrollbackOffset: 0)
        XCTAssertTrue(current.cursor.visible, "Cursor should be visible in current viewport")

        // Scrollback (offset > 0) should show earlier lines and hide cursor
        let scrolled = adapter.createSnapshot(scrollbackOffset: 3)
        XCTAssertFalse(scrolled.cursor.visible, "Cursor should be hidden in scrollback mode")

        // Verify scrollback contains different content than current viewport
        let currentFirstRow = (0..<current.cols).map { current[0, $0].character }.joined()
        let scrolledFirstRow = (0..<scrolled.cols).map { scrolled[0, $0].character }.joined()
        XCTAssertNotEqual(currentFirstRow.trimmingCharacters(in: .whitespaces),
                         scrolledFirstRow.trimmingCharacters(in: .whitespaces),
                         "Scrollback should show different lines than current viewport")
    }

    func testScrollbackOffsetClampedToAvailable() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 5)
        // With no scrollback history, offset should be clamped to 0
        let snapshot = adapter.createSnapshot(scrollbackOffset: 100)
        XCTAssertTrue(snapshot.cursor.visible,
                      "With no scrollback history, cursor should remain visible (offset clamped to 0)")
    }

    func testRangeChangedPreservesParserDelegate() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let expectation = expectation(description: "delegate called")
        expectation.assertForOverFulfill = false

        let delegateAdapter = TestParserDelegate()
        delegateAdapter.onAction = { _ in
            expectation.fulfill()
        }
        adapter.delegate = delegateAdapter

        adapter.parse(data: "Hello".data(using: .utf8)!)

        waitForExpectations(timeout: 1)
        XCTAssertTrue(delegateAdapter.actionReceived,
                      "TerminalParserDelegate should still receive .bufferUpdated")
    }
}

// MARK: - Test helpers

private class TestParserDelegate: TerminalParserDelegate {
    var actionReceived = false
    var onAction: ((ParserAction) -> Void)?

    func parser(_ parser: any TerminalParser, didReceiveAction action: ParserAction) {
        actionReceived = true
        onAction?(action)
    }
}
