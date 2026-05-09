import XCTest
import AppKit
import QuartzCore
import TerminalCore
@testable import TerminalRenderer

/// Mock renderer for verifying RenderCoordinator callback behavior.
private final class MockRenderer: TerminalRendering {
    var renderCallCount = 0
    var lastBuffer: ScreenBufferSnapshot?
    var lastCursor: CursorState?
    var lastSelection: SelectionOverlay?
    var lastHoveredHyperlinkURL: String?
    var lastBareTextHover: BareTextHoverSpan?

    var lastShellMarkers: ShellMarkerOverlay?

    func render(buffer: ScreenBufferSnapshot, dirtyRegion: DirtyRegion,
                cursor: CursorState, selection: SelectionOverlay?,
                shellMarkers: ShellMarkerOverlay?,
                hoveredHyperlinkURL: String?,
                bareTextHover: BareTextHoverSpan?,
                into layer: CALayer) {
        renderCallCount += 1
        lastBuffer = buffer
        lastCursor = cursor
        lastSelection = selection
        lastShellMarkers = shellMarkers
        lastHoveredHyperlinkURL = hoveredHyperlinkURL
        lastBareTextHover = bareTextHover
    }

    func measure(font: NSFont) -> FontMetrics {
        FontMetrics.measure(font: font)
    }
}

final class RenderCoordinatorTests: XCTestCase {
    private func makeSnapshot(rows: Int = 25, cols: Int = 80) -> ScreenBufferSnapshot {
        let buffer = ScreenBuffer(rows: rows, cols: cols)
        return buffer.snapshot()
    }

    func testInitialization() {
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)
        XCTAssertNil(coordinator.renderer)
        XCTAssertNil(coordinator.targetLayer)
    }

    func testSubmitSnapshotDoesNotCrash() {
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)
        let snapshot = makeSnapshot()
        coordinator.submitSnapshot(snapshot)
        // Submitting multiple snapshots should work without issue
        coordinator.submitSnapshot(makeSnapshot(rows: 10, cols: 40))
    }

    func testStartAndStopDisplayLink() {
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)

        // Start and stop should not crash
        coordinator.startDisplayLink()
        coordinator.stopDisplayLink()

        // Double stop should be safe
        coordinator.stopDisplayLink()

        // Restart should work
        coordinator.startDisplayLink()
        coordinator.stopDisplayLink()
    }

    func testConcurrentSubmitDoesNotCrash() {
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)

        let iterations = 1000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let snapshot = self.makeSnapshot(rows: 25, cols: 80)
            coordinator.submitSnapshot(snapshot)
        }
        // If we get here without crashing, thread safety is working
        XCTAssertNotNil(coordinator)
    }

    // MARK: - Bare-text hover

    func testUpdateBareTextHoverStoresSpanAndDirtiesRow() {
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)
        XCTAssertNil(coordinator.currentBareTextHover())

        let span = BareTextHoverSpan(viewportRow: 3, cols: 5...12)
        coordinator.updateBareTextHover(span)
        XCTAssertEqual(coordinator.currentBareTextHover(), span)

        let dirty = dirtyRegion.swapAndClear()
        XCTAssertTrue(dirty.contains(3),
                      "setting hover on a row must mark that row dirty")
    }

    func testUpdateBareTextHoverNilDirtiesPreviousRow() {
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)

        coordinator.updateBareTextHover(BareTextHoverSpan(viewportRow: 7, cols: 0...3))
        _ = dirtyRegion.swapAndClear()  // drain the dirty from the set

        coordinator.updateBareTextHover(nil)
        XCTAssertNil(coordinator.currentBareTextHover())

        let dirty = dirtyRegion.swapAndClear()
        XCTAssertTrue(dirty.contains(7),
                      "clearing hover must mark the previously-hovered row dirty")
    }

    func testUpdateBareTextHoverIdempotentWhenSpanUnchanged() {
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)
        let span = BareTextHoverSpan(viewportRow: 1, cols: 0...4)
        coordinator.updateBareTextHover(span)
        _ = dirtyRegion.swapAndClear()

        coordinator.updateBareTextHover(span)
        let dirty = dirtyRegion.swapAndClear()
        XCTAssertTrue(dirty.isEmpty, "no-op updates must not generate dirty rows")
    }
}
