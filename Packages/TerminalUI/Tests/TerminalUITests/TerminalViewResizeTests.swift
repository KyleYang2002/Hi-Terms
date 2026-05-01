import XCTest
import AppKit
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

@MainActor
final class TerminalViewResizeTests: XCTestCase {

    // MARK: - gridSize calculation
    //
    // `gridSize(for:fontMetrics:)` interprets `size` as the *view frame* (the
    // value `setFrameSize` receives), which already includes a content inset
    // on each side, so test inputs add `2 * inset` before feeding the helper.

    private static let inset = TerminalLayout.contentInset

    func testGridSizeMatchesIntegerCellCount() {
        let font = NSFont(name: "Menlo", size: 13)!
        let metrics = FontMetrics.measure(font: font)
        let inset = Self.inset

        let size = NSSize(
            width: metrics.cellWidth * 80 + 2 * inset.width,
            height: metrics.cellHeight * 24 + 2 * inset.height
        )
        let (cols, rows) = TerminalView.gridSize(for: size, fontMetrics: metrics)
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
    }

    func testGridSizeFloorsPartialCells() {
        let font = NSFont(name: "Menlo", size: 13)!
        let metrics = FontMetrics.measure(font: font)
        let inset = Self.inset

        let size = NSSize(
            width: metrics.cellWidth * 80 + metrics.cellWidth * 0.6 + 2 * inset.width,
            height: metrics.cellHeight * 24 + metrics.cellHeight * 0.4 + 2 * inset.height
        )
        let (cols, rows) = TerminalView.gridSize(for: size, fontMetrics: metrics)
        XCTAssertEqual(cols, 80, "fractional column should floor")
        XCTAssertEqual(rows, 24, "fractional row should floor")
    }

    func testGridSizeClampedAtMinimum() {
        let font = NSFont(name: "Menlo", size: 13)!
        let metrics = FontMetrics.measure(font: font)

        let (cols, rows) = TerminalView.gridSize(for: NSSize(width: 0, height: 0), fontMetrics: metrics)
        XCTAssertEqual(cols, 1, "must clamp to at least 1 col")
        XCTAssertEqual(rows, 1, "must clamp to at least 1 row")
    }

    func testGridSizeSubtractsContentInset() {
        let font = NSFont(name: "Menlo", size: 13)!
        let metrics = FontMetrics.measure(font: font)
        let inset = Self.inset

        // Exactly enough room for 80 columns of glyphs, but the surrounding
        // inset eats the last fractional cell — should round down to 79.
        let size = NSSize(
            width: metrics.cellWidth * 80 + inset.width,    // half the inset short
            height: metrics.cellHeight * 24 + 2 * inset.height
        )
        let (cols, _) = TerminalView.gridSize(for: size, fontMetrics: metrics)
        XCTAssertLessThan(cols, 80,
                          "inset must reduce usable width below the raw column count")
    }

    // MARK: - applyResize forwards to pipeline (and dedupes)

    func testApplyResizePropagatesGridChangeAndDedupes() throws {
        // Build a real but inert pipeline (no shell I/O needed for this test).
        let config = PTYConfiguration(
            shellPath: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            environment: [:],
            initialWindowSize: (80, 25)
        )
        let ptyProcess = try PTYProcess(configuration: config)
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let dirtyRegion = DirtyRegion()
        let coordinator = RenderCoordinator(dirtyRegion: dirtyRegion)
        let pipeline = DefaultTerminalPipeline(
            ptyProcess: ptyProcess,
            adapter: adapter,
            dirtyRegion: dirtyRegion,
            renderCoordinator: coordinator
        )
        defer { pipeline.stop() }

        let session = TerminalSession(launchCommand: "/bin/sh", pipeline: pipeline)
        let view = TerminalView(
            session: session,
            pipeline: pipeline,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        // First resize crosses a grid boundary → SwiftTerm should observe new dims.
        let metrics = FontMetrics.measure(font: NSFont(name: "Menlo", size: 13)!)
        let inset = TerminalLayout.contentInset
        // The frame includes `2 * inset` of chrome around the grid, matching
        // what NSWindow forwards to `setFrameSize` in production.
        let bigger = NSSize(
            width: metrics.cellWidth * 100 + 2 * inset.width,
            height: metrics.cellHeight * 30 + 2 * inset.height
        )
        view.applyResize(for: bigger)
        XCTAssertEqual(adapter.terminal.cols, 100)
        XCTAssertEqual(adapter.terminal.rows, 30)

        // Sub-cell delta on the same grid cell should NOT trigger a resize.
        let stillSameGrid = NSSize(
            width: bigger.width + 0.4 * metrics.cellWidth,
            height: bigger.height + 0.4 * metrics.cellHeight
        )
        view.applyResize(for: stillSameGrid)
        XCTAssertEqual(adapter.terminal.cols, 100, "sub-cell delta must not re-resize")
        XCTAssertEqual(adapter.terminal.rows, 30)

        // Crossing the next grid boundary should resize again.
        let smaller = NSSize(
            width: metrics.cellWidth * 60 + 2 * inset.width,
            height: metrics.cellHeight * 20 + 2 * inset.height
        )
        view.applyResize(for: smaller)
        XCTAssertEqual(adapter.terminal.cols, 60)
        XCTAssertEqual(adapter.terminal.rows, 20)
    }
}
