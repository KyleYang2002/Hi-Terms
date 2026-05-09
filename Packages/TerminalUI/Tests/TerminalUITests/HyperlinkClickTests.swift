import XCTest
import AppKit
import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

/// End-to-end ⌘+click on an OSC 8 hyperlink:
///   1. ⌘+click on a linked cell → injected opener receives the URL,
///      selection is NOT created, no SGR bytes emitted.
///   2. Click without ⌘ on the same cell → normal path (selection / SGR),
///      opener NOT called.
///   3. Plain click on linked cell → opener NOT called.
///   4. ⌘+click on a non-linked cell → opener NOT called, normal path runs.
@MainActor
final class HyperlinkClickTests: XCTestCase {

    // MARK: - Fixtures

    private final class RecordingSession: Session {
        let id: SessionID = UUID()
        var state: SessionState = .running
        let createdAt: Date = Date()
        let launchCommand: String = "test-recording"
        let pipeline: any TerminalPipeline
        var onStateChanged: ((SessionState) -> Void)?
        private(set) var writes: [Data] = []
        init(pipeline: any TerminalPipeline) { self.pipeline = pipeline }
        func start() throws {}
        func stop() {}
        func write(data: Data) { writes.append(data) }
        func resize(cols: Int, rows: Int) {}
    }

    private struct Fixture {
        let view: TerminalView
        let session: RecordingSession
        let pipeline: DefaultTerminalPipeline
        let window: NSWindow
        let openedURLs: NSMutableArray
    }

    private func makeFixture(cols: Int = 80, rows: Int = 25) throws -> Fixture {
        let config = PTYConfiguration(
            shellPath: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            environment: [:],
            initialWindowSize: (UInt16(cols), UInt16(rows))
        )
        let ptyProcess = try PTYProcess(configuration: config)
        let adapter = SwiftTermAdapter(cols: cols, rows: rows)
        let dirty = DirtyRegion()
        let coord = RenderCoordinator(dirtyRegion: dirty)
        let pipeline = DefaultTerminalPipeline(
            ptyProcess: ptyProcess,
            adapter: adapter,
            dirtyRegion: dirty,
            renderCoordinator: coord
        )
        let session = RecordingSession(pipeline: pipeline)
        let view = TerminalView(
            session: session,
            pipeline: pipeline,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let opened = NSMutableArray()
        view.hyperlinkOpener = { url in
            opened.add(url)
            return true
        }
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        addTeardownBlock { pipeline.stop() }
        return Fixture(view: view, session: session, pipeline: pipeline,
                       window: window, openedURLs: opened)
    }

    /// Feeds an OSC 8 sequence linking "OPEN" to https://example.com at column 0
    /// of row 0, followed by plain "X" at column 4 (out of the link range).
    private func feedHyperlinkRow(_ adapter: SwiftTermAdapter) {
        let seq = "\u{1B}]8;;https://example.com\u{1B}\\OPEN\u{1B}]8;;\u{1B}\\X"
        adapter.parse(data: Data(seq.utf8))
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            in window: NSWindow,
                            atCol col: Int,
                            viewportRow row: Int,
                            view: TerminalView,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        // terminalCoordinate maps (col, row) back to view-local (x, y_local)
        // via cellWidth/cellHeight + inset. Reverse that to a window point.
        let metrics = FontMetrics.measure(font: NSFont(name: "Menlo", size: 13)!)
        let inset = TerminalLayout.contentInset
        // Aim for the cell's visual center in cell coordinates.
        let xCenter = inset.width + (CGFloat(col) + 0.5) * metrics.cellWidth
        // terminalCoordinate inverts Y: localY = (bounds.height - point.y) - inset.height
        // We want localY = (row + 0.5) * cellHeight, so:
        //   point.y = bounds.height - inset.height - localY
        let localY = (CGFloat(row) + 0.5) * metrics.cellHeight
        let pointY = view.bounds.height - inset.height - localY
        let point = NSPoint(x: xCenter, y: pointY)
        return NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    // MARK: - Tests

    func testCommandClickOnHyperlinkOpensURLAndSkipsSelection() throws {
        let f = try makeFixture()
        feedHyperlinkRow(f.pipeline.adapter)

        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 1,
                               viewportRow: 0, view: f.view,
                               modifiers: [.command])
        f.view.mouseDown(with: event)

        XCTAssertEqual(f.openedURLs.count, 1, "exactly one URL should reach the opener")
        XCTAssertEqual((f.openedURLs[0] as? URL)?.absoluteString, "https://example.com")
        XCTAssertNil(f.view.selectionController.current,
                     "⌘+click on a hyperlink must not start a local selection")
        XCTAssertTrue(f.session.writes.isEmpty,
                      "no SGR bytes should reach the session for a consumed hyperlink click")
    }

    func testPlainClickOnHyperlinkDoesNotOpenURL() throws {
        let f = try makeFixture()
        feedHyperlinkRow(f.pipeline.adapter)

        // Default mouseMode is .off, so a plain click should drive the local
        // selection path. Either way, the opener must NOT be called.
        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 1,
                               viewportRow: 0, view: f.view)
        f.view.mouseDown(with: event)

        XCTAssertEqual(f.openedURLs.count, 0,
                       "plain click without ⌘ must not invoke the opener")
    }

    func testCommandClickOnPlainCellDoesNotOpenURL() throws {
        let f = try makeFixture()
        feedHyperlinkRow(f.pipeline.adapter)

        // Col 4 holds the plain "X" — no hyperlink. ⌘+click should fall
        // through to the normal selection / SGR path (here: selection, since
        // mouseMode==.off by default) and the opener stays untouched.
        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 4,
                               viewportRow: 0, view: f.view,
                               modifiers: [.command])
        f.view.mouseDown(with: event)

        XCTAssertEqual(f.openedURLs.count, 0,
                       "⌘+click on a non-hyperlink cell must not invoke the opener")
    }

    func testCommandClickWithFailingOpenerFallsThroughToSelection() throws {
        let f = try makeFixture()
        feedHyperlinkRow(f.pipeline.adapter)
        // Replace opener with one that always fails (e.g. NSWorkspace failure).
        let attempted = NSMutableArray()
        f.view.hyperlinkOpener = { url in
            attempted.add(url)
            return false
        }

        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 1,
                               viewportRow: 0, view: f.view,
                               modifiers: [.command])
        f.view.mouseDown(with: event)

        XCTAssertEqual(attempted.count, 1, "opener was attempted once")
        // Falls through to selection (mouseMode==.off makes that the default).
        XCTAssertNotNil(f.view.selectionController.current,
                        "failed opener must yield to the regular selection path")
    }
}
