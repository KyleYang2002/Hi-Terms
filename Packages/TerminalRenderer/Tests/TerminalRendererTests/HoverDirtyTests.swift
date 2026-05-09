import XCTest
import AppKit
import QuartzCore
import TerminalCore
@testable import TerminalRenderer

/// `RenderCoordinator.updateHover(_:)` must:
///  1. Mark only rows containing the *new* URL dirty when entering a link.
///  2. Mark BOTH old and new URL rows dirty when transitioning between two
///     different links (so the previous underline clears and the new one paints).
///  3. Mark only rows containing the *old* URL dirty when leaving (URL → nil).
///  4. Be idempotent — repeated `updateHover(sameURL)` is a no-op.
final class HoverDirtyTests: XCTestCase {

    /// Builds a 5-row × 10-col snapshot:
    ///   row 0: plain text, no URL
    ///   row 1: cells 0..2 hyperlink "u1"
    ///   row 2: plain text, no URL
    ///   row 3: cells 4..6 hyperlink "u2"
    ///   row 4: plain text, no URL
    private func makeSnapshot() -> ScreenBufferSnapshot {
        let buffer = ScreenBuffer(rows: 5, cols: 10)
        for col in 0...2 {
            buffer[1, col] = Cell(character: "a", attributes: .default,
                                  width: 1, hyperlinkURL: "u1")
        }
        for col in 4...6 {
            buffer[3, col] = Cell(character: "b", attributes: .default,
                                  width: 1, hyperlinkURL: "u2")
        }
        return buffer.snapshot()
    }

    private func makeCoordinator() -> (RenderCoordinator, DirtyRegion) {
        let dirty = DirtyRegion()
        let coord = RenderCoordinator(dirtyRegion: dirty)
        return (coord, dirty)
    }

    func testEnteringLinkMarksOnlyMatchingRowsDirty() {
        let (coord, dirty) = makeCoordinator()
        coord.submitSnapshot(makeSnapshot())
        _ = dirty.swapAndClear() // clear any submission-side dirt
        coord.updateHover("u1")
        let rows = dirty.swapAndClear()
        XCTAssertEqual(rows, IndexSet(integer: 1),
                       "only the row carrying u1 should be dirty after entering it")
    }

    func testTransitioningBetweenLinksMarksBothRowsDirty() {
        let (coord, dirty) = makeCoordinator()
        coord.submitSnapshot(makeSnapshot())
        coord.updateHover("u1")
        _ = dirty.swapAndClear()
        coord.updateHover("u2")
        let rows = dirty.swapAndClear()
        XCTAssertEqual(rows, IndexSet([1, 3]),
                       "transition u1 → u2 must repaint both rows")
    }

    func testLeavingLinkMarksOldRowDirty() {
        let (coord, dirty) = makeCoordinator()
        coord.submitSnapshot(makeSnapshot())
        coord.updateHover("u2")
        _ = dirty.swapAndClear()
        coord.updateHover(nil)
        let rows = dirty.swapAndClear()
        XCTAssertEqual(rows, IndexSet(integer: 3),
                       "leaving u2 must repaint row 3 to clear the underline")
    }

    func testRepeatedSameURLIsIdempotent() {
        let (coord, dirty) = makeCoordinator()
        coord.submitSnapshot(makeSnapshot())
        coord.updateHover("u1")
        _ = dirty.swapAndClear()
        coord.updateHover("u1")
        XCTAssertTrue(dirty.swapAndClear().isEmpty,
                      "same URL twice must be a no-op")
    }

    func testHoverUpdateBeforeSnapshotDoesNothing() {
        let (coord, dirty) = makeCoordinator()
        coord.updateHover("u1") // no snapshot yet
        XCTAssertTrue(dirty.swapAndClear().isEmpty,
                      "without a snapshot there is nothing to mark dirty")
    }

    func testHoverURLNotPresentInSnapshotMarksNothing() {
        let (coord, dirty) = makeCoordinator()
        coord.submitSnapshot(makeSnapshot())
        _ = dirty.swapAndClear()
        coord.updateHover("does-not-exist")
        XCTAssertTrue(dirty.swapAndClear().isEmpty,
                      "URLs absent from the snapshot must not produce dirty rows")
    }

    func testCurrentHoverURLReflectsLatestUpdate() {
        let (coord, _) = makeCoordinator()
        coord.submitSnapshot(makeSnapshot())
        XCTAssertNil(coord.currentHoverURL())
        coord.updateHover("u1")
        XCTAssertEqual(coord.currentHoverURL(), "u1")
        coord.updateHover(nil)
        XCTAssertNil(coord.currentHoverURL())
    }
}
