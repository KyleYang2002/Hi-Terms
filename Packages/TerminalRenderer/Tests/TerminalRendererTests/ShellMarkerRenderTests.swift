import XCTest
import AppKit
import QuartzCore
import TerminalCore
@testable import TerminalRenderer

/// `CoreTextRenderer.updateShellMarkerOverlay` paints OSC 133 command-boundary
/// decoration into a dedicated CALayer (`hi-terms-shell-markers`). These tests
/// invoke the marker pass via `_testRenderShellMarkers(_:in:buffer:)` and
/// assert sublayer count / geometry / colours instead of pixel-grabbing the
/// bitmap, which would be brittle.
final class ShellMarkerRenderTests: XCTestCase {

    private var renderer: CoreTextRenderer!
    private let snapshot = ScreenBuffer(rows: 5, cols: 10).snapshot()
    private let host = CALayer()

    override func setUp() {
        super.setUp()
        let font = NSFont(name: "Menlo", size: 13)!
        renderer = CoreTextRenderer(font: font)
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
    }

    private func markerSublayers() -> [CALayer] {
        guard let host = host.sublayers?.first(where: { $0.name == "hi-terms-shell-markers" })
        else { return [] }
        return host.sublayers ?? []
    }

    // MARK: - Empty overlay

    func testNilOverlayCreatesNoSublayers() {
        renderer._testRenderShellMarkers(nil, in: host, buffer: snapshot)
        XCTAssertTrue(markerSublayers().isEmpty,
                      "nil overlay must not contribute marker sublayers")
    }

    func testEmptyOverlayCreatesNoSublayers() {
        renderer._testRenderShellMarkers(ShellMarkerOverlay(rows: []),
                                         in: host, buffer: snapshot)
        XCTAssertTrue(markerSublayers().isEmpty,
                      "empty overlay must not contribute marker sublayers")
    }

    // MARK: - Single mark

    func testSuccessGutterAddsOneSublayer() {
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .success)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        XCTAssertEqual(markerSublayers().count, 1,
                       "success row contributes exactly one gutter sublayer")
    }

    func testRunningStatusGutterColorIsBlue() {
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .running)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let gutter = markerSublayers().first!
        let bg = NSColor(cgColor: gutter.backgroundColor!)
        // systemBlue maps to high blue, low red. The exact RGB drifts with
        // dark mode, so just probe the dominant component.
        XCTAssertNotNil(bg)
        XCTAssertGreaterThan(bg!.blueComponent, bg!.redComponent,
                             "running gutter should lean blue")
    }

    // MARK: - Prompt-top separator

    func testPromptTopAddsSeparatorAboveGutter() {
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 1, status: .success, isPromptTop: true)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let subs = markerSublayers()
        XCTAssertEqual(subs.count, 2, "prompt-top adds gutter + 1px separator")
        // The 1-pixel-tall layer is the separator.
        let separator = subs.first { $0.frame.height == 1.0 }
        XCTAssertNotNil(separator, "exactly one separator with height==1px")
    }

    func testPromptTopFalseDoesNotAddSeparator() {
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 1, status: .success, isPromptTop: false)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        XCTAssertEqual(markerSublayers().count, 1,
                       "non-prompt-top row must only add a gutter")
    }

    // MARK: - Failure badge

    func testFailureBadgeAddsTextLayer() {
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 2, status: .failure(exitCode: 127),
                  failureBadgeExitCode: 127)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let subs = markerSublayers()
        XCTAssertEqual(subs.count, 2, "failure row adds gutter + badge")
        let textLayers = subs.compactMap { $0 as? CATextLayer }
        XCTAssertEqual(textLayers.count, 1, "exactly one CATextLayer for the badge")
        let label = textLayers[0]
        if let attr = label.string as? NSAttributedString {
            XCTAssertTrue(attr.string.contains("exit=127"),
                          "badge must include exit code in label")
        } else {
            XCTFail("badge text layer should hold an NSAttributedString")
        }
    }

    func testFailureGutterColorIsRed() {
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .failure(exitCode: 1))
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let subs = markerSublayers()
        let gutter = subs.first { !($0 is CATextLayer) }!
        let bg = NSColor(cgColor: gutter.backgroundColor!)!
        XCTAssertGreaterThan(bg.redComponent, bg.greenComponent,
                             "failure gutter should lean red")
    }

    // MARK: - Multi-row band

    func testMultipleRowsContributeIndependently() {
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .success, isPromptTop: true),
            .init(viewportRow: 1, status: .success),
            .init(viewportRow: 2, status: .success)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        XCTAssertEqual(markerSublayers().count, 4,
                       "1 separator + 3 gutters for a 3-row prompt-led band")
    }

    // MARK: - Idempotence

    func testRepeatedRebuildReplacesSublayersInPlace() {
        let first = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .success)
        ])
        let second = ShellMarkerOverlay(rows: [
            .init(viewportRow: 1, status: .running),
            .init(viewportRow: 2, status: .running)
        ])
        renderer._testRenderShellMarkers(first, in: host, buffer: snapshot)
        XCTAssertEqual(markerSublayers().count, 1)
        renderer._testRenderShellMarkers(second, in: host, buffer: snapshot)
        XCTAssertEqual(markerSublayers().count, 2,
                       "rebuilds must REPLACE sublayers, not accumulate")
    }
}
