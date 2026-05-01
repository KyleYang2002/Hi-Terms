import XCTest
import AppKit
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

@MainActor
final class TerminalViewPasteTests: XCTestCase {

    // MARK: - Test fixtures

    /// Builds a TerminalView wired to a SpySession that captures every write.
    private func makeFixture() throws -> (TerminalView, SpySession, SwiftTermAdapter) {
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

        let session = SpySession(pipeline: pipeline)
        let view = TerminalView(
            session: session,
            pipeline: pipeline,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        // Stop pipeline at end of test (TerminalView holds it via reference but
        // PTY needs explicit termination).
        addTeardownBlock { pipeline.stop() }

        return (view, session, adapter)
    }

    // MARK: - Bracketed paste OFF

    func testPasteWithoutBracketedModeSendsRawData() throws {
        let (view, session, _) = try makeFixture()

        view.applyPaste("ls -la")

        XCTAssertEqual(session.writes.count, 1)
        XCTAssertEqual(session.writes.first, "ls -la".data(using: .utf8))
    }

    // MARK: - Bracketed paste ON

    func testPasteWithBracketedModeWrapsWithMarkers() throws {
        let (view, session, adapter) = try makeFixture()

        // Enable bracketed paste mode via DECSET
        adapter.parse(data: "\u{1B}[?2004h".data(using: .utf8)!)
        XCTAssertTrue(adapter.terminal.bracketedPasteMode, "precondition: mode must be on")
        // The DECSET write produces no output back to the session; clear any noise just in case.
        session.writes.removeAll()

        view.applyPaste("git status")

        XCTAssertEqual(session.writes.count, 1)
        let expected = Data("\u{1B}[200~git status\u{1B}[201~".utf8)
        XCTAssertEqual(session.writes.first, expected,
                       "Bracketed paste must wrap payload with ESC[200~ ... ESC[201~")
    }

    func testPasteAfterModeDisabledReturnsToRaw() throws {
        let (view, session, adapter) = try makeFixture()

        // Toggle on then off
        adapter.parse(data: "\u{1B}[?2004h".data(using: .utf8)!)
        adapter.parse(data: "\u{1B}[?2004l".data(using: .utf8)!)
        XCTAssertFalse(adapter.terminal.bracketedPasteMode)
        session.writes.removeAll()

        view.applyPaste("hello")
        XCTAssertEqual(session.writes.first, "hello".data(using: .utf8),
                       "After mode disabled, paste must drop the markers")
    }

    func testPasteOfMultilineContentWrapsOnce() throws {
        let (view, session, adapter) = try makeFixture()

        adapter.parse(data: "\u{1B}[?2004h".data(using: .utf8)!)
        session.writes.removeAll()

        let payload = "line1\nline2\nline3"
        view.applyPaste(payload)

        XCTAssertEqual(session.writes.count, 1, "must be a single wrapped write")
        let expected = Data("\u{1B}[200~\(payload)\u{1B}[201~".utf8)
        XCTAssertEqual(session.writes.first, expected)
    }
}

// MARK: - SpySession

/// A minimal Session implementation that captures every write call.
@MainActor
private final class SpySession: @MainActor Session {
    let id: SessionID = UUID()
    var state: SessionState = .running
    let createdAt: Date = Date()
    let launchCommand: String = "spy"
    let pipeline: any TerminalPipeline
    var onStateChanged: ((SessionState) -> Void)?

    var writes: [Data] = []

    init(pipeline: any TerminalPipeline) {
        self.pipeline = pipeline
    }

    func start() throws {}
    func stop() {}
    func write(data: Data) { writes.append(data) }
    func resize(cols: Int, rows: Int) {}
}
