import XCTest
import AppKit
import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

/// End-to-end ⌘+click on a bare-text path:
/// 1. ⌘+click on a regex-detected, stat-validated, cwd-contained path → the
///    injected EditorJump opener receives `(absPath, line, col)`.
/// 2. ⌘+click without a hit (no path under cursor) → opener NOT called.
/// 3. Plain click on a path → opener NOT called (only ⌘ activates jump).
@MainActor
final class BareTextClickTests: XCTestCase {

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

    private struct OpenerCall: Equatable {
        let absPath: String
        let line: Int?
        let column: Int?
    }

    private struct Fixture {
        let view: TerminalView
        let session: RecordingSession
        let pipeline: DefaultTerminalPipeline
        let window: NSWindow
        let cwd: URL
        let recorded: NSMutableArray  // [OpenerCall]
    }

    private func makeFixture(cols: Int = 80, rows: Int = 25) throws -> Fixture {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("hi-terms-baretext-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cwd) }

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
        let recorded = NSMutableArray()
        view.bareTextOpener = { path, line, col in
            recorded.add(OpenerCall(absPath: path, line: line, column: col))
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

        // Tell the adapter about cwd via OSC 7.
        feedOSC7(adapter: adapter, cwd: cwd)

        return Fixture(view: view, session: session, pipeline: pipeline,
                       window: window, cwd: cwd, recorded: recorded)
    }

    private func feedOSC7(adapter: SwiftTermAdapter, cwd: URL) {
        // OSC 7;file://hostname/path\\
        let host = ProcessInfo.processInfo.hostName
        let encoded = cwd.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd.path
        let seq = "\u{1B}]7;file://\(host)\(encoded)\u{1B}\\"
        adapter.parse(data: Data(seq.utf8))
    }

    private func feedText(_ adapter: SwiftTermAdapter, _ text: String) {
        adapter.parse(data: Data(text.utf8))
    }

    private func touch(_ relative: String, in cwd: URL) throws -> URL {
        let url = cwd.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            in window: NSWindow,
                            atCol col: Int,
                            viewportRow row: Int,
                            view: TerminalView,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let metrics = FontMetrics.measure(font: NSFont(name: "Menlo", size: 13)!)
        let inset = TerminalLayout.contentInset
        let xCenter = inset.width + (CGFloat(col) + 0.5) * metrics.cellWidth
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

    func testCommandClickOnBarePathDispatchesToEditorJump() throws {
        let f = try makeFixture()
        let target = try touch("src/Foo.swift", in: f.cwd)
        // Layout: "see src/Foo.swift:42:7"
        //         0123456789012345678901
        // path occupies cols 4..15, suffix :42:7 cols 16..21
        feedText(f.pipeline.adapter, "see src/Foo.swift:42:7")

        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 8,
                               viewportRow: 0, view: f.view,
                               modifiers: [.command])
        f.view.mouseDown(with: event)

        XCTAssertEqual(f.recorded.count, 1)
        let call = f.recorded[0] as? OpenerCall
        XCTAssertEqual(call?.absPath, target.standardizedFileURL.path)
        XCTAssertEqual(call?.line, 42)
        XCTAssertEqual(call?.column, 7)
        XCTAssertNil(f.view.selectionController.current,
                     "⌘+click that consumed via EditorJump must not start a selection")
    }

    func testCommandClickOnNonPathFallsThroughToSelection() throws {
        let f = try makeFixture()
        _ = try touch("src/Foo.swift", in: f.cwd)
        feedText(f.pipeline.adapter, "see src/Foo.swift:42:7")

        // Col 0 ('s' of "see") — that prefix isn't a path.
        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 0,
                               viewportRow: 0, view: f.view,
                               modifiers: [.command])
        f.view.mouseDown(with: event)

        XCTAssertEqual(f.recorded.count, 0,
                       "⌘+click on a non-path cell must not call EditorJump")
    }

    func testPlainClickOnPathDoesNotDispatch() throws {
        let f = try makeFixture()
        _ = try touch("src/Foo.swift", in: f.cwd)
        feedText(f.pipeline.adapter, "see src/Foo.swift:42:7")

        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 8,
                               viewportRow: 0, view: f.view)  // no ⌘
        f.view.mouseDown(with: event)

        XCTAssertEqual(f.recorded.count, 0,
                       "plain click on a path must not invoke EditorJump")
    }

    func testCommandClickOutsideCwdRejected() throws {
        let f = try makeFixture()
        // /etc/passwd exists but is OUTSIDE cwd → detector must drop it.
        feedText(f.pipeline.adapter, "see /etc/passwd here")

        let event = mouseEvent(.leftMouseDown, in: f.window, atCol: 6,
                               viewportRow: 0, view: f.view,
                               modifiers: [.command])
        f.view.mouseDown(with: event)
        XCTAssertEqual(f.recorded.count, 0,
                       "outside-cwd absolute paths must not reach EditorJump")
    }
}
