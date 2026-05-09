import XCTest
import AppKit
import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

/// `TerminalView.publishShellMarkers()` integration tests:
///   * Empty shell-integration history → nil overlay published.
///   * After OSC 133 A/B/C/D succeeds, the overlay reflects the prompt+output
///     bands of the completed command.
///   * Failure exit code is propagated as the failure-status colour and a
///     trailing `✗ exit=N` badge on the last output row.
///   * Alt-screen flag is honoured: while in the alt buffer, publish emits
///     nil; switching back restores markers.
@MainActor
final class ShellMarkerPublishTests: XCTestCase {

    // MARK: - Fixtures

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
    }

    private func makeFixture(rows: Int = 25, cols: Int = 80) throws -> Fixture {
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
            ptyProcess: ptyProcess, adapter: adapter,
            dirtyRegion: dirty, renderCoordinator: coord
        )
        let session = RecordingSession(pipeline: pipeline)
        let view = TerminalView(
            session: session, pipeline: pipeline,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        addTeardownBlock { pipeline.stop() }
        return Fixture(view: view, pipeline: pipeline)
    }

    // MARK: - Tests

    func testEmptyHistoryPublishesNilOverlay() throws {
        let f = try makeFixture()
        f.view.publishShellMarkers()
        XCTAssertNil(f.pipeline.renderCoordinator.currentShellMarkers(),
                     "no shell-integration data → no overlay")
    }

    func testCompletedSuccessProducesPromptAndOutputRows() throws {
        let f = try makeFixture()
        let adapter = f.pipeline.adapter
        // A on row 0, B on row 0, C on row 1, D on row 3 with exit 0
        adapter.shellIntegration.handlePromptStart(line: 0)
        adapter.shellIntegration.handleCommandInputStart(line: 0)
        adapter.shellIntegration.handleCommandOutputStart(line: 1)
        adapter.shellIntegration.handleCommandEnd(line: 3, exitCode: 0)
        f.view.publishShellMarkers()

        let overlay = f.pipeline.renderCoordinator.currentShellMarkers()
        XCTAssertNotNil(overlay)
        XCTAssertFalse(overlay!.rows.isEmpty)
        // Prompt row 0 — promptTop true
        let promptTop = overlay!.rows.first { $0.viewportRow == 0 && $0.isPromptTop }
        XCTAssertNotNil(promptTop, "the first row of the prompt must be promptTop")
        // No badge for success
        let badges = overlay!.rows.compactMap { $0.failureBadgeExitCode }
        XCTAssertTrue(badges.isEmpty, "success commands have no badge")
        // Status is success on every row
        for r in overlay!.rows {
            XCTAssertEqual(r.status, .success)
        }
    }

    func testFailureCommandProducesBadgeOnLastOutputRow() throws {
        let f = try makeFixture()
        let adapter = f.pipeline.adapter
        adapter.shellIntegration.handlePromptStart(line: 0)
        adapter.shellIntegration.handleCommandInputStart(line: 0)
        adapter.shellIntegration.handleCommandOutputStart(line: 1)
        adapter.shellIntegration.handleCommandEnd(line: 4, exitCode: 1)
        f.view.publishShellMarkers()

        let overlay = f.pipeline.renderCoordinator.currentShellMarkers()
        XCTAssertNotNil(overlay)
        let badgeRows = overlay!.rows.filter { $0.failureBadgeExitCode != nil }
        XCTAssertEqual(badgeRows.count, 1, "exactly one badge for one failure")
        XCTAssertEqual(badgeRows.first?.failureBadgeExitCode, 1)
        // Last output row = endLine - 1 = 3 → projected to viewport row 3.
        XCTAssertEqual(badgeRows.first?.viewportRow, 3,
                       "badge sits on the last output row")
        XCTAssertEqual(badgeRows.first?.status, .failure(exitCode: 1))
    }

    func testAltScreenSuppressesOverlay() throws {
        let f = try makeFixture()
        let adapter = f.pipeline.adapter
        // Build a band first so there's something to suppress.
        adapter.shellIntegration.handlePromptStart(line: 0)
        adapter.shellIntegration.handleCommandInputStart(line: 0)
        adapter.shellIntegration.handleCommandOutputStart(line: 1)
        adapter.shellIntegration.handleCommandEnd(line: 3, exitCode: 0)
        f.view.publishShellMarkers()
        XCTAssertNotNil(f.pipeline.renderCoordinator.currentShellMarkers())

        // Flip into alt-screen via DECSET 1049 and re-publish.
        adapter.parse(data: Data("\u{1B}[?1049h".utf8))
        f.view.publishShellMarkers()
        XCTAssertNil(f.pipeline.renderCoordinator.currentShellMarkers(),
                     "alt-screen must suppress the marker overlay")

        // Flip back and re-publish — markers must reappear.
        adapter.parse(data: Data("\u{1B}[?1049l".utf8))
        f.view.publishShellMarkers()
        XCTAssertNotNil(f.pipeline.renderCoordinator.currentShellMarkers(),
                       "exiting alt-screen must restore the marker overlay")
    }

    func testRunningCommandProjectsOpenEndedOutputToBuffer() throws {
        let f = try makeFixture(rows: 5)
        let adapter = f.pipeline.adapter
        adapter.shellIntegration.handlePromptStart(line: 0)
        adapter.shellIntegration.handleCommandInputStart(line: 0)
        adapter.shellIntegration.handleCommandOutputStart(line: 1)
        // No D — output is open-ended.
        f.view.publishShellMarkers()

        let overlay = f.pipeline.renderCoordinator.currentShellMarkers()
        XCTAssertNotNil(overlay)
        // Status running on every row
        for r in overlay!.rows {
            XCTAssertEqual(r.status, .running)
        }
        // Output rows clamp to bottom of viewport (rows 1..4 with rows=5).
        let outputRows = overlay!.rows.filter { !$0.isPromptTop && $0.viewportRow > 0 }
        XCTAssertGreaterThan(outputRows.count, 0,
                             "running command must paint output rows up to the buffer bottom")
    }
}
