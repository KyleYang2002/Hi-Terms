import XCTest
import AppKit
import Foundation
import TerminalCore
@testable import TerminalUI

/// Wave 2-C: verifies the absolute-row selection model.
///
/// All Wave 2-C behaviour funnels through two seams:
///
/// 1. `SelectionController.projectToViewport(topScrollInvariantRow:viewportRows:cols:)`
///    — translates absolute row ids back to viewport-relative segments and
///    clips out-of-viewport segments. This is what `TerminalView`
///    publishes to the renderer overlay.
///
/// 2. `SelectionController.copyToPasteboard(snapshot:cols:topScrollInvariantRow:)`
///    — uses the same anchor to project the selection into snapshot
///    coordinates before invoking the extractor.
///
/// Tests target those two seams directly so they don't have to spin up an
/// NSWindow + display link, while still exercising real `SwiftTermAdapter`
/// state for the integration check.
@MainActor
final class SelectionScrollInvariantTests: XCTestCase {

    // MARK: - 1. projection at rest

    /// yDisp == 0 (no scroll, no scrollback): an absolute selection on rows
    /// 5..8 must paint at the same viewport rows.
    func testProjectionViewportRelativeWhenNotScrolled() {
        let controller = SelectionController()
        controller.beginDrag(at: GridPoint(row: 5, col: 3), clickCount: 1)
        controller.extendDrag(to: GridPoint(row: 8, col: 10))

        let segments = controller.projectToViewport(
            topScrollInvariantRow: 0,
            viewportRows: 25,
            cols: 80)

        XCTAssertEqual(segments.count, 4,
                       "rows 5,6,7,8 → 4 viewport segments")
        XCTAssertEqual(segments.map(\.viewportRow), [5, 6, 7, 8])
        XCTAssertEqual(segments.first?.cols, 3...79,
                       "first row starts at the selection start col")
        XCTAssertEqual(segments.last?.cols, 0...10,
                       "last row ends at the selection end col")
    }

    // MARK: - 2. projection follows scroll

    /// The selection (absolute rows) does not move when the buffer scrolls;
    /// projecting against a higher `topScrollInvariantRow` shifts the
    /// viewport rows downward (new viewport top = larger absolute id =
    /// smaller viewport row for the same absolute row).
    func testProjectionShiftsWithScrollback() {
        let controller = SelectionController()
        // Pick absolute rows 100..103 — well inside a typical scrollback.
        controller.beginDrag(at: GridPoint(row: 100, col: 0), clickCount: 1)
        controller.extendDrag(to: GridPoint(row: 103, col: 5))

        // Initially the viewport top sits at absolute row 95 → selection
        // shows up at viewport rows 5..8.
        let initial = controller.projectToViewport(
            topScrollInvariantRow: 95,
            viewportRows: 25,
            cols: 80)
        XCTAssertEqual(initial.map(\.viewportRow), [5, 6, 7, 8])

        // After PTY pushes ~3 lines into scrollback, viewport top is now at
        // absolute row 98 → same selection shows up at viewport rows 2..5.
        let later = controller.projectToViewport(
            topScrollInvariantRow: 98,
            viewportRows: 25,
            cols: 80)
        XCTAssertEqual(later.map(\.viewportRow), [2, 3, 4, 5],
                       "scroll moves the projection without altering the stored selection")

        // Stored selection is unchanged — it is scroll-invariant.
        XCTAssertEqual(controller.current?.anchor, GridPoint(row: 100, col: 0))
        XCTAssertEqual(controller.current?.head, GridPoint(row: 103, col: 5))
    }

    // MARK: - 3. clip top

    /// Selection straddles the top of the viewport: rows that project to a
    /// negative viewport row must be dropped, the rest preserved.
    func testProjectionClipsSegmentsAboveViewport() {
        let controller = SelectionController()
        // Absolute rows 50..55. Viewport top = 53 → only rows 53,54,55 are
        // visible (viewport rows 0,1,2). Rows 50,51,52 sit above the top.
        controller.beginDrag(at: GridPoint(row: 50, col: 0), clickCount: 1)
        controller.extendDrag(to: GridPoint(row: 55, col: 4))

        let segments = controller.projectToViewport(
            topScrollInvariantRow: 53,
            viewportRows: 25,
            cols: 80)

        XCTAssertEqual(segments.map(\.viewportRow), [0, 1, 2],
                       "rows 50,51,52 are above the viewport top → clipped")
        XCTAssertEqual(segments.last?.cols, 0...4,
                       "the bottom-most surviving row keeps its original endCol")
    }

    // MARK: - 4. clip bottom

    /// Selection straddles the bottom of the viewport: rows whose projection
    /// falls past `viewportRows - 1` are dropped.
    func testProjectionClipsSegmentsBelowViewport() {
        let controller = SelectionController()
        // Absolute rows 200..210. Viewport top = 200, height = 5 → rows
        // 200..204 fit (viewport rows 0..4); rows 205..210 fall off.
        controller.beginDrag(at: GridPoint(row: 200, col: 2), clickCount: 1)
        controller.extendDrag(to: GridPoint(row: 210, col: 9))

        let segments = controller.projectToViewport(
            topScrollInvariantRow: 200,
            viewportRows: 5,
            cols: 80)

        XCTAssertEqual(segments.map(\.viewportRow), [0, 1, 2, 3, 4],
                       "rows past viewport bottom → clipped")
        XCTAssertEqual(segments.first?.cols, 2...79,
                       "first row keeps its original startCol")
        XCTAssertEqual(segments.last?.cols, 0...79,
                       "last surviving row is a middle row, full width")
    }

    // MARK: - 5. copy after scroll

    /// End-to-end: feed enough lines into a real SwiftTermAdapter to push
    /// the buffer into scrollback, then copy a selection that points at a
    /// row that's still in the viewport. The pasteboard contents must
    /// match the row we picked, proving the absolute-row → snapshot-row
    /// projection in `copyToPasteboard` is correct.
    func testCopyAfterScrollKeepsCorrectText() {
        let adapter = SwiftTermAdapter(cols: 20, rows: 5)

        // Feed 12 numbered lines. With rows=5, lines 1..7 spill into
        // scrollback; lines 8..12 stay visible. yDisp ends up at >= 7.
        for i in 1...12 {
            adapter.parse(data: "row\(i)\r\n".data(using: .utf8)!)
        }

        let (snapshot, topAbs, isAlt) = adapter.createSnapshotWithAnchor(scrollbackOffset: 0)
        XCTAssertFalse(isAlt, "feeding plain text must not switch to alt buffer")
        XCTAssertGreaterThan(topAbs, 0,
                             "12 lines into a 5-row terminal should bump yDisp above 0")

        // Read viewport row 0 directly from the snapshot, treating cells with
        // a NUL character (Cell.empty) as spaces — that's what the extractor
        // does internally. Trimming trailing whitespace gives us the visible
        // text of that line.
        let firstViewportText: String = {
            let raw = (0..<snapshot.cols).map { col -> String in
                let ch = snapshot[0, col].character
                return ch == "\0" ? " " : String(ch)
            }.joined()
            // Trim the trailing run of spaces (extractor does the same when
            // a segment reaches the right edge of the row).
            var trimmed = raw
            while trimmed.last == " " { trimmed.removeLast() }
            return trimmed
        }()
        XCTAssertFalse(firstViewportText.isEmpty,
                       "viewport row 0 must be populated after feeding")
        XCTAssertTrue(firstViewportText.hasPrefix("row"),
                      "viewport row 0 should be one of the numbered lines we fed")

        // Select the *whole* viewport row 0 in absolute coordinates. With
        // the right edge included, the extractor will trim trailing spaces
        // so the result equals `firstViewportText`.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hiterms-test-\(UUID().uuidString)"))
        let controller = SelectionController(pasteboard: pasteboard)
        let absRow = topAbs  // viewport row 0 → absolute row == top
        controller.beginDrag(at: GridPoint(row: absRow, col: 0), clickCount: 1)
        controller.extendDrag(to: GridPoint(row: absRow, col: snapshot.cols - 1))

        let didWrite = controller.copyToPasteboard(
            snapshot: snapshot,
            cols: snapshot.cols,
            topScrollInvariantRow: topAbs)

        XCTAssertTrue(didWrite, "non-empty selection should write to the pasteboard")
        XCTAssertEqual(pasteboard.string(forType: .string), firstViewportText,
                       "pasteboard must contain the visible text of the projected snapshot row")
    }

    // MARK: - bonus: empty / nil selection projection

    /// Defensive: with no live selection, projection returns an empty array
    /// (so `TerminalView` can publish a nil overlay without special-casing).
    func testProjectionWithNoSelectionReturnsEmpty() {
        let controller = SelectionController()
        XCTAssertNil(controller.current)
        let segments = controller.projectToViewport(
            topScrollInvariantRow: 7,
            viewportRows: 25,
            cols: 80)
        XCTAssertTrue(segments.isEmpty)
    }
}
