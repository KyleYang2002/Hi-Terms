import XCTest
import AppKit
import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

/// Hover behavior for bare-text path detection. Mirrors `HyperlinkPublishTests`
/// in spirit: drive `mouseMoved` and verify the renderer state matches.
@MainActor
final class BareTextHoverTests: XCTestCase {

    private final class RecordingSession: Session {
        let id: SessionID = UUID()
        var state: SessionState = .running
        let createdAt: Date = Date()
        let launchCommand: String = "test-recording"
        let pipeline: any TerminalPipeline
        var onStateChanged: ((SessionState) -> Void)?
        init(pipeline: any TerminalPipeline) { self.pipeline = pipeline }
        func start() throws {}
        func stop() {}
        func write(data: Data) {}
        func resize(cols: Int, rows: Int) {}
    }

    private struct Fixture {
        let view: TerminalView
        let pipeline: DefaultTerminalPipeline
        let window: NSWindow
        let cwd: URL
    }

    private func makeFixture(cols: Int = 80, rows: Int = 25) throws -> Fixture {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("hi-terms-baretext-hover-\(UUID().uuidString)")
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
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        addTeardownBlock { pipeline.stop() }

        let host = ProcessInfo.processInfo.hostName
        let encoded = cwd.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd.path
        let osc7 = "\u{1B}]7;file://\(host)\(encoded)\u{1B}\\"
        adapter.parse(data: Data(osc7.utf8))

        return Fixture(view: view, pipeline: pipeline, window: window, cwd: cwd)
    }

    private func touch(_ relative: String, in cwd: URL) throws -> URL {
        let url = cwd.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    private func mouseMoveEvent(in window: NSWindow,
                                atCol col: Int,
                                viewportRow row: Int,
                                view: TerminalView) -> NSEvent {
        let metrics = FontMetrics.measure(font: NSFont(name: "Menlo", size: 13)!)
        let inset = TerminalLayout.contentInset
        let xCenter = inset.width + (CGFloat(col) + 0.5) * metrics.cellWidth
        let localY = (CGFloat(row) + 0.5) * metrics.cellHeight
        let pointY = view.bounds.height - inset.height - localY
        let point = NSPoint(x: xCenter, y: pointY)
        return NSEvent.mouseEvent(
            with: .mouseMoved,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    // MARK: - Tests

    func testHoverOnBarePathSetsRendererSpan() throws {
        let f = try makeFixture()
        _ = try touch("src/A.swift", in: f.cwd)
        f.pipeline.adapter.parse(data: Data("see src/A.swift here".utf8))

        // Col 6 should land inside "src/A.swift" (cols 4..14).
        let event = mouseMoveEvent(in: f.window, atCol: 6, viewportRow: 0, view: f.view)
        f.view.mouseMoved(with: event)

        let span = f.pipeline.renderCoordinator.currentBareTextHover()
        XCTAssertNotNil(span, "hovering a path must publish a hover span")
        XCTAssertEqual(span?.viewportRow, 0)
        XCTAssertTrue(span?.cols.contains(6) ?? false)
    }

    func testHoverOffPathClearsRendererSpan() throws {
        let f = try makeFixture()
        _ = try touch("src/A.swift", in: f.cwd)
        f.pipeline.adapter.parse(data: Data("see src/A.swift here".utf8))

        // Hover into the path
        f.view.mouseMoved(with: mouseMoveEvent(in: f.window, atCol: 6, viewportRow: 0, view: f.view))
        XCTAssertNotNil(f.pipeline.renderCoordinator.currentBareTextHover())

        // Hover way off (column 0 — "s" of "see", not part of any path)
        f.view.mouseMoved(with: mouseMoveEvent(in: f.window, atCol: 0, viewportRow: 0, view: f.view))
        XCTAssertNil(f.pipeline.renderCoordinator.currentBareTextHover(),
                     "moving off the path must clear the hover span")
    }

    func testMouseExitedClearsHover() throws {
        let f = try makeFixture()
        _ = try touch("src/A.swift", in: f.cwd)
        f.pipeline.adapter.parse(data: Data("see src/A.swift".utf8))

        f.view.mouseMoved(with: mouseMoveEvent(in: f.window, atCol: 6, viewportRow: 0, view: f.view))
        XCTAssertNotNil(f.pipeline.renderCoordinator.currentBareTextHover())

        // mouseExited needs an enter/exit event factory — the regular
        // `NSEvent.mouseEvent(with: .mouseExited, …)` rejects the type mask.
        let exitEvent = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: f.window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
        f.view.mouseExited(with: exitEvent)
        XCTAssertNil(f.pipeline.renderCoordinator.currentBareTextHover())
    }
}
