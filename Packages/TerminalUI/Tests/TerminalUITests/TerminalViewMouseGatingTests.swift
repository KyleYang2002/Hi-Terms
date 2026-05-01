import XCTest
import AppKit
import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

/// Verifies that `TerminalView` only forwards mouse reports to the session when
/// SwiftTerm's mouse mode actually requests them. Without this gating, a click
/// in a non-mouse-aware shell prompt is echoed back as garbled SGR parameters
/// (the bug captured in `refs/22.png`).
@MainActor
final class TerminalViewMouseGatingTests: XCTestCase {

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

    /// Builds a `TerminalView` wired to a recording session. The PTY points at
    /// `/bin/sh -c "sleep 5"` so the file descriptors stay valid for the
    /// duration of the test, matching the `TerminalViewResizeTests` pattern.
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
        return (view, session, pipeline)
    }

    /// Switches the SwiftTerm parser into the requested mouse reporting mode by
    /// feeding the corresponding DEC private mode set sequence.
    private func setMouseMode(_ mode: MouseReportingMode, on adapter: SwiftTermAdapter) {
        let sequence: String
        switch mode {
        case .off:                  sequence = "\u{1B}[?1000l"   // turn vt200 off
        case .x10:                  sequence = "\u{1B}[?9h"
        case .vt200:                sequence = "\u{1B}[?1000h"
        case .buttonEventTracking:  sequence = "\u{1B}[?1002h"
        case .anyEvent:             sequence = "\u{1B}[?1003h"
        }
        adapter.parse(data: Data(sequence.utf8))
        XCTAssertEqual(adapter.mouseReportingMode, mode,
                       "expected SwiftTerm to enter \(mode) after parsing \(sequence.debugDescription)")
    }

    private func makeMouseEvent(
        _ type: NSEvent.EventType,
        in window: NSWindow,
        at point: NSPoint = NSPoint(x: 50, y: 50)
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    /// Wraps the view in an off-screen window so NSEvent location math works.
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

    // MARK: - .off

    func testOffModeSuppressesEverything() throws {
        let (view, session, pipeline) = try makeView()
        let window = attach(view)

        // Default is .off — verify and exercise all four event kinds.
        XCTAssertEqual(pipeline.adapter.mouseReportingMode, .off)

        view.mouseDown(with: makeMouseEvent(.leftMouseDown, in: window))
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, in: window))
        view.mouseUp(with: makeMouseEvent(.leftMouseUp, in: window))
        view.mouseMoved(with: makeMouseEvent(.mouseMoved, in: window))

        XCTAssertTrue(session.writes.isEmpty,
                      "no mouse bytes should reach the session in .off mode (got \(session.writes))")
    }

    // MARK: - .x10

    func testX10ModeSendsPressOnly() throws {
        let (view, session, pipeline) = try makeView()
        let window = attach(view)

        setMouseMode(.x10, on: pipeline.adapter)

        view.mouseDown(with: makeMouseEvent(.leftMouseDown, in: window))
        view.mouseUp(with: makeMouseEvent(.leftMouseUp, in: window))
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, in: window))
        view.mouseMoved(with: makeMouseEvent(.mouseMoved, in: window))

        XCTAssertEqual(session.writes.count, 1, "x10 must report press only")
        XCTAssertTrue(session.writes[0].starts(with: Data("\u{1B}[<0;".utf8)),
                      "press should encode left button as id 0")
        // 'M' (press) suffix
        XCTAssertEqual(session.writes[0].last, UInt8(ascii: "M"))
    }

    // MARK: - .vt200

    func testVT200ModeSendsPressAndRelease() throws {
        let (view, session, pipeline) = try makeView()
        let window = attach(view)

        setMouseMode(.vt200, on: pipeline.adapter)

        view.mouseDown(with: makeMouseEvent(.leftMouseDown, in: window))
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, in: window))
        view.mouseUp(with: makeMouseEvent(.leftMouseUp, in: window))
        view.mouseMoved(with: makeMouseEvent(.mouseMoved, in: window))

        XCTAssertEqual(session.writes.count, 2,
                       "vt200 must report press + release only (no drag/move)")
        XCTAssertEqual(session.writes[0].last, UInt8(ascii: "M"), "press uses 'M' suffix")
        XCTAssertEqual(session.writes[1].last, UInt8(ascii: "m"), "release uses 'm' suffix")
    }

    // MARK: - .buttonEventTracking

    func testButtonEventTrackingSendsDragButNotMove() throws {
        let (view, session, pipeline) = try makeView()
        let window = attach(view)

        setMouseMode(.buttonEventTracking, on: pipeline.adapter)

        view.mouseDown(with: makeMouseEvent(.leftMouseDown, in: window))
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, in: window))
        view.mouseMoved(with: makeMouseEvent(.mouseMoved, in: window))
        view.mouseUp(with: makeMouseEvent(.leftMouseUp, in: window))

        XCTAssertEqual(session.writes.count, 3,
                       "buttonEventTracking should report press + drag + release, suppressing no-button move")
        // Drag carries button + 32 (left = 0 → 32). Confirm the second event is the drag.
        let dragString = String(data: session.writes[1], encoding: .utf8)
        XCTAssertEqual(dragString?.hasPrefix("\u{1B}[<32;"), true,
                       "drag must be encoded as button + 32; got \(dragString ?? "nil")")
    }

    // MARK: - .anyEvent

    func testAnyEventModeSendsEverything() throws {
        let (view, session, pipeline) = try makeView()
        let window = attach(view)

        setMouseMode(.anyEvent, on: pipeline.adapter)

        view.mouseDown(with: makeMouseEvent(.leftMouseDown, in: window))
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, in: window))
        view.mouseUp(with: makeMouseEvent(.leftMouseUp, in: window))
        view.mouseMoved(with: makeMouseEvent(.mouseMoved, in: window))

        XCTAssertEqual(session.writes.count, 4,
                       "anyEvent should report press + drag + release + move")
        let moveString = String(data: session.writes[3], encoding: .utf8)
        XCTAssertEqual(moveString?.hasPrefix("\u{1B}[<35;"), true,
                       "no-button move must be encoded with id 35; got \(moveString ?? "nil")")
    }
}
