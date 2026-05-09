import XCTest
import AppKit
import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

/// Wave 2-A: verifies that mouse events are dispatched to either the SGR
/// reporter OR the local `SelectionController`, never both, based on:
///   - SwiftTerm's `mouseMode`
///   - whether the user is holding Option (override)
///
/// This complements `TerminalViewMouseGatingTests`, which only covers the
/// SGR path. Those tests must continue to pass — selection introduction
/// must not regress mouse reporting for TUI apps.
@MainActor
final class SelectionGatingTests: XCTestCase {

    // MARK: - Recording session

    private final class RecordingSession: Session {
        let id: SessionID = UUID()
        var state: SessionState = .running
        let createdAt: Date = Date()
        let launchCommand: String = "test-recording"
        let pipeline: any TerminalPipeline
        var onStateChanged: ((SessionState) -> Void)?
        private(set) var writes: [Data] = []

        init(pipeline: any TerminalPipeline) {
            self.pipeline = pipeline
        }

        func start() throws {}
        func stop() {}
        func write(data: Data) { writes.append(data) }
        func resize(cols: Int, rows: Int) {}
    }

    // MARK: - Helpers

    private func makeView() throws -> (view: TerminalView,
                                       session: RecordingSession,
                                       pipeline: DefaultTerminalPipeline) {
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
        let session = RecordingSession(pipeline: pipeline)
        let view = TerminalView(
            session: session,
            pipeline: pipeline,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        addTeardownBlock { pipeline.stop() }
        return (view, session, pipeline)
    }

    private func setMouseMode(_ mode: MouseReportingMode, on adapter: SwiftTermAdapter) {
        let sequence: String
        switch mode {
        case .off:                  sequence = "\u{1B}[?1000l"
        case .x10:                  sequence = "\u{1B}[?9h"
        case .vt200:                sequence = "\u{1B}[?1000h"
        case .buttonEventTracking:  sequence = "\u{1B}[?1002h"
        case .anyEvent:             sequence = "\u{1B}[?1003h"
        }
        adapter.parse(data: Data(sequence.utf8))
    }

    private func attach(_ view: TerminalView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return window
    }

    private func makeMouseEvent(
        _ type: NSEvent.EventType,
        in window: NSWindow,
        at point: NSPoint = NSPoint(x: 50, y: 50),
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        )!
    }

    // MARK: - Tests

    /// Mouse mode is on, no Option modifier — input must flow through the
    /// SGR encoder, NOT the local selection. Catches a regression where the
    /// gating order accidentally inverted.
    func testSelectionDoesNotEmitWhenMouseModeOnAndNoOption() throws {
        let (view, session, pipeline) = try makeView()
        let window = attach(view)
        setMouseMode(.buttonEventTracking, on: pipeline.adapter)

        view.mouseDown(with: makeMouseEvent(.leftMouseDown, in: window))
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, in: window))
        view.mouseUp(with: makeMouseEvent(.leftMouseUp, in: window))

        XCTAssertNil(view.selectionController.current,
                     "no selection should be built while SGR is in charge")
        XCTAssertEqual(session.writes.count, 3,
                       "buttonEventTracking should still emit press + drag + release")
    }

    /// Mouse mode is on, but Option held — selection must own the gesture and
    /// the SGR encoder must stay silent.
    func testSelectionEmitsNoSGRWhenMouseModeOnWithOption() throws {
        let (view, session, pipeline) = try makeView()
        let window = attach(view)
        setMouseMode(.buttonEventTracking, on: pipeline.adapter)

        view.mouseDown(with: makeMouseEvent(.leftMouseDown, in: window,
                                            at: NSPoint(x: 80, y: 200),
                                            modifiers: [.option]))
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, in: window,
                                               at: NSPoint(x: 200, y: 200),
                                               modifiers: [.option]))
        view.mouseUp(with: makeMouseEvent(.leftMouseUp, in: window,
                                          at: NSPoint(x: 200, y: 200),
                                          modifiers: [.option]))

        XCTAssertNotNil(view.selectionController.current,
                        "Option-held drag must build a local selection")
        XCTAssertTrue(session.writes.isEmpty,
                      "no SGR bytes should reach the session when Option overrides; got \(session.writes)")
    }

    /// Default mouse mode (off) → selection path. After dragging, asking the
    /// controller to copy must write extracted text to the (test-injected)
    /// pasteboard. Uses a private named pasteboard to avoid touching the
    /// system clipboard.
    func testCopyToPasteboardWritesExtractedText() throws {
        let (view, _, _) = try makeView()
        _ = attach(view)

        // Feed some content so the underlying buffer has characters to copy.
        view.applyPaste("hello world")

        // The view's controller defaults to .general; for a hermetic test we
        // build a separate controller against a private pasteboard and drive
        // it directly. Selection lives at row 0 cols 0-4 — covers "hello".
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hiterms-test-\(UUID().uuidString)"))
        let controller = SelectionController(pasteboard: pasteboard)
        controller.beginDrag(at: GridPoint(row: 0, col: 0), clickCount: 1)
        controller.extendDrag(to: GridPoint(row: 0, col: 4))

        // Build a snapshot mirroring "hello" in the first row.
        let buffer = ScreenBuffer(rows: 1, cols: 80)
        for (i, ch) in "hello".enumerated() {
            buffer[0, i] = Cell(character: ch, attributes: .default, width: 1)
        }
        let snapshot = buffer.snapshot()

        let didWrite = controller.copyToPasteboard(snapshot: snapshot, cols: snapshot.cols)
        XCTAssertTrue(didWrite, "extracted text should be non-empty")
        XCTAssertEqual(pasteboard.string(forType: .string), "hello",
                       "pasteboard must contain the extracted selection text")
    }

    /// Resizing must clear the selection — the underlying grid changes shape
    /// so any stale anchor/head rows would point at different content.
    func testResizeClearsSelection() throws {
        let (view, _, _) = try makeView()
        _ = attach(view)

        // Build a selection via the controller directly (mode .off path).
        view.selectionController.beginDrag(at: GridPoint(row: 0, col: 0), clickCount: 1)
        view.selectionController.extendDrag(to: GridPoint(row: 0, col: 4))
        XCTAssertNotNil(view.selectionController.current)

        // Trigger a real grid resize.
        let metrics = FontMetrics.measure(font: NSFont(name: "Menlo", size: 13)!)
        let inset = TerminalLayout.contentInset
        let bigger = NSSize(
            width: metrics.cellWidth * 100 + 2 * inset.width,
            height: metrics.cellHeight * 30 + 2 * inset.height)
        view.applyResize(for: bigger)

        XCTAssertNil(view.selectionController.current,
                     "applyResize must clear the selection")
    }
}
