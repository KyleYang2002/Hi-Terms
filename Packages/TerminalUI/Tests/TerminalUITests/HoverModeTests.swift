import XCTest
import AppKit
import Foundation
import Configuration
import TerminalCore
import TerminalRenderer
import PTYKit
@testable import TerminalUI

/// `appConfig.hoverMode` gates the visual hover signal at the cell under the
/// pointer. ⌘+click is **not** gated and must still open links/paths even
/// when hover is off. We assert behavior end-to-end through `mouseMoved` /
/// `flagsChanged` / `mouseDown` so the wiring through TerminalView is covered.
@MainActor
final class HoverModeTests: XCTestCase {

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

    private struct StubConfig: AppConfig {
        var fontName = "Menlo"
        var fontSize: CGFloat = 13
        var shellPath = "/bin/sh"
        var scrollbackLines = 1_000
        var terminalCols = 80
        var terminalRows = 25
        var terminalType = "xterm-256color"
        var bellBehavior: BellBehavior = .silent
        var gutterRunningAlpha = 0.45
        var gutterSuccessAlpha = 0.55
        var gutterFailureAlpha = 0.65
        var gutterWidthPx: CGFloat = 3.0
        var gutterSeparatorEnabled = true
        var hyperlinkSchemeAllowlist: Set<String> = ["http", "https", "file"]
        var hoverMode: HoverMode = .always
    }

    private struct Fixture {
        let view: TerminalView
        let pipeline: DefaultTerminalPipeline
        let window: NSWindow
        let opened: NSMutableArray
    }

    private func makeFixture(hoverMode: HoverMode) throws -> Fixture {
        let cfg = PTYConfiguration(
            shellPath: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            environment: [:],
            initialWindowSize: (80, 25)
        )
        let pty = try PTYProcess(configuration: cfg)
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let dirty = DirtyRegion()
        let coord = RenderCoordinator(dirtyRegion: dirty)
        let pipeline = DefaultTerminalPipeline(
            ptyProcess: pty, adapter: adapter,
            dirtyRegion: dirty, renderCoordinator: coord
        )
        let session = RecordingSession(pipeline: pipeline)
        var stub = StubConfig()
        stub.hoverMode = hoverMode
        let view = TerminalView(
            session: session,
            pipeline: pipeline,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            appConfig: stub
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
        return Fixture(view: view, pipeline: pipeline, window: window, opened: opened)
    }

    private func feedHyperlinkRow(_ adapter: SwiftTermAdapter) {
        let seq = "\u{1B}]8;;https://example.com\u{1B}\\OPEN\u{1B}]8;;\u{1B}\\X"
        adapter.parse(data: Data(seq.utf8))
    }

    private func mouseMoved(in window: NSWindow, atCol col: Int, viewportRow row: Int,
                            view: TerminalView,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let metrics = FontMetrics.measure(font: NSFont(name: "Menlo", size: 13)!)
        let inset = TerminalLayout.contentInset
        let xCenter = inset.width + (CGFloat(col) + 0.5) * metrics.cellWidth
        let localY = (CGFloat(row) + 0.5) * metrics.cellHeight
        let pointY = view.bounds.height - inset.height - localY
        return NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: xCenter, y: pointY),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    private func mouseDown(in window: NSWindow, atCol col: Int, viewportRow row: Int,
                           view: TerminalView,
                           modifiers: NSEvent.ModifierFlags) -> NSEvent {
        let metrics = FontMetrics.measure(font: NSFont(name: "Menlo", size: 13)!)
        let inset = TerminalLayout.contentInset
        let xCenter = inset.width + (CGFloat(col) + 0.5) * metrics.cellWidth
        let localY = (CGFloat(row) + 0.5) * metrics.cellHeight
        let pointY = view.bounds.height - inset.height - localY
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: xCenter, y: pointY),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    private func flagsChanged(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        // For modifier-only events the location/window are irrelevant — the
        // handler reads `event.modifierFlags` only.
        return NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        )!
    }

    // MARK: - Tests

    func testAlwaysModeHighlightsOnPlainHover() throws {
        let f = try makeFixture(hoverMode: .always)
        feedHyperlinkRow(f.pipeline.adapter)

        f.view.mouseMoved(with: mouseMoved(in: f.window, atCol: 1, viewportRow: 0,
                                           view: f.view))
        XCTAssertEqual(f.pipeline.renderCoordinator.currentHoverURL(),
                       "https://example.com",
                       ".always must publish the hovered URL on plain mouseMoved")
    }

    func testCommandKeyModeSkipsPlainHover() throws {
        let f = try makeFixture(hoverMode: .commandKey)
        feedHyperlinkRow(f.pipeline.adapter)

        f.view.mouseMoved(with: mouseMoved(in: f.window, atCol: 1, viewportRow: 0,
                                           view: f.view))
        XCTAssertNil(f.pipeline.renderCoordinator.currentHoverURL(),
                     ".commandKey must NOT highlight without ⌘ held")
    }

    func testCommandKeyModeHighlightsWhenCommandHeld() throws {
        let f = try makeFixture(hoverMode: .commandKey)
        feedHyperlinkRow(f.pipeline.adapter)

        f.view.mouseMoved(with: mouseMoved(in: f.window, atCol: 1, viewportRow: 0,
                                           view: f.view, modifiers: [.command]))
        XCTAssertEqual(f.pipeline.renderCoordinator.currentHoverURL(),
                       "https://example.com",
                       ".commandKey + ⌘ held must highlight on hover")
    }

    func testCommandKeyFlagPressTogglesHoverAtLastCell() throws {
        let f = try makeFixture(hoverMode: .commandKey)
        feedHyperlinkRow(f.pipeline.adapter)

        // Move pointer to the linked cell without ⌘ — no highlight.
        f.view.mouseMoved(with: mouseMoved(in: f.window, atCol: 1, viewportRow: 0,
                                           view: f.view))
        XCTAssertNil(f.pipeline.renderCoordinator.currentHoverURL())

        // ⌘ is pressed (no movement) — flagsChanged must light the underline
        // at the cached cell.
        f.view.flagsChanged(with: flagsChanged(modifiers: [.command]))
        XCTAssertEqual(f.pipeline.renderCoordinator.currentHoverURL(),
                       "https://example.com",
                       "flagsChanged ⌘-down should highlight at the last hover cell")

        // ⌘ released — underline goes away again.
        f.view.flagsChanged(with: flagsChanged(modifiers: []))
        XCTAssertNil(f.pipeline.renderCoordinator.currentHoverURL(),
                     "flagsChanged ⌘-up must clear the highlight")
    }

    func testOffModeNeverHighlights() throws {
        let f = try makeFixture(hoverMode: .off)
        feedHyperlinkRow(f.pipeline.adapter)

        // Plain hover.
        f.view.mouseMoved(with: mouseMoved(in: f.window, atCol: 1, viewportRow: 0,
                                           view: f.view))
        XCTAssertNil(f.pipeline.renderCoordinator.currentHoverURL())

        // Even with ⌘ held, .off keeps hover suppressed.
        f.view.mouseMoved(with: mouseMoved(in: f.window, atCol: 1, viewportRow: 0,
                                           view: f.view, modifiers: [.command]))
        XCTAssertNil(f.pipeline.renderCoordinator.currentHoverURL(),
                     ".off must keep hover suppressed regardless of modifiers")
    }

    func testOffModeStillAllowsCommandClickToOpen() throws {
        // Hover and click are independent: hoverMode=.off must not block
        // ⌘+click → opener, otherwise the user has no way to follow links.
        let f = try makeFixture(hoverMode: .off)
        feedHyperlinkRow(f.pipeline.adapter)

        f.view.mouseDown(with: mouseDown(in: f.window, atCol: 1, viewportRow: 0,
                                         view: f.view, modifiers: [.command]))
        XCTAssertEqual(f.opened.count, 1, "⌘+click must reach the opener even when hover is off")
    }
}
