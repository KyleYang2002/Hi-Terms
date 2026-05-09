import XCTest
import AppKit
import QuartzCore
import TerminalCore
@testable import TerminalRenderer

/// Verifies that `GutterAppearance` knobs flow into the rendered shell-marker
/// overlay: alpha values reach the gutter CALayer's background color, custom
/// width affects the gutter CALayer's frame, and `separatorEnabled = false`
/// suppresses the prompt-top hairline.
final class GutterAppearanceTests: XCTestCase {

    private let snapshot = ScreenBuffer(rows: 5, cols: 10).snapshot()
    private let host = CALayer()

    override func setUp() {
        super.setUp()
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
    }

    private func makeRenderer(_ appearance: GutterAppearance) -> CoreTextRenderer {
        let font = NSFont(name: "Menlo", size: 13)!
        return CoreTextRenderer(font: font, gutterAppearance: appearance)
    }

    private func markerSublayers() -> [CALayer] {
        guard let host = host.sublayers?.first(where: { $0.name == "hi-terms-shell-markers" })
        else { return [] }
        return host.sublayers ?? []
    }

    // MARK: - Alpha plumbed into gutter color

    func testCustomRunningAlphaReachesGutterColor() {
        let appearance = GutterAppearance(
            runningAlpha: 0.95,
            successAlpha: 0.55,
            failureAlpha: 0.65,
            widthPx: 3.0,
            separatorEnabled: true
        )
        let renderer = makeRenderer(appearance)
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .running)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let gutter = markerSublayers().first!
        let bg = NSColor(cgColor: gutter.backgroundColor!)!
        XCTAssertEqual(bg.alphaComponent, 0.95, accuracy: 0.01,
                       "running alpha must propagate to the gutter CALayer")
    }

    func testCustomFailureAlphaReachesGutterColor() {
        let appearance = GutterAppearance(
            runningAlpha: 0.45,
            successAlpha: 0.55,
            failureAlpha: 0.20,
            widthPx: 3.0,
            separatorEnabled: true
        )
        let renderer = makeRenderer(appearance)
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .failure(exitCode: 1))
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let gutter = markerSublayers().first { !($0 is CATextLayer) }!
        let bg = NSColor(cgColor: gutter.backgroundColor!)!
        XCTAssertEqual(bg.alphaComponent, 0.20, accuracy: 0.01)
    }

    // MARK: - Width

    func testCustomGutterWidthReachesLayerFrame() {
        let appearance = GutterAppearance(
            runningAlpha: 0.45,
            successAlpha: 0.55,
            failureAlpha: 0.65,
            widthPx: 12.0,
            separatorEnabled: true
        )
        let renderer = makeRenderer(appearance)
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .success)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let gutter = markerSublayers().first!
        // Width is `inset.width + appearance.widthPx`. inset is small but
        // non-zero; assert the gutter is wider with widthPx=12 than the
        // default 3 by checking absolute size.
        XCTAssertGreaterThan(gutter.frame.width, 12.0,
                             "12px gutter widthPx must produce a layer wider than 12pt")
    }

    // MARK: - Separator toggle

    func testSeparatorDisabledSuppressesHairline() {
        let appearance = GutterAppearance(
            runningAlpha: 0.45,
            successAlpha: 0.55,
            failureAlpha: 0.65,
            widthPx: 3.0,
            separatorEnabled: false
        )
        let renderer = makeRenderer(appearance)
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 1, status: .success, isPromptTop: true)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        XCTAssertEqual(markerSublayers().count, 1,
                       "with separator disabled, prompt-top must only add the gutter")
    }

    func testSeparatorEnabledAddsHairline() {
        let appearance = GutterAppearance(
            runningAlpha: 0.45,
            successAlpha: 0.55,
            failureAlpha: 0.65,
            widthPx: 3.0,
            separatorEnabled: true
        )
        let renderer = makeRenderer(appearance)
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 1, status: .success, isPromptTop: true)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        XCTAssertEqual(markerSublayers().count, 2,
                       "with separator enabled, prompt-top must add gutter + hairline")
    }

    // MARK: - Default appearance unchanged

    func testDefaultAppearancePreservesV004Behavior() {
        // No explicit gutterAppearance → defaults must reproduce v0.0.4's
        // hardcoded values. Probe success status.
        let font = NSFont(name: "Menlo", size: 13)!
        let renderer = CoreTextRenderer(font: font)
        let overlay = ShellMarkerOverlay(rows: [
            .init(viewportRow: 0, status: .success)
        ])
        renderer._testRenderShellMarkers(overlay, in: host, buffer: snapshot)
        let gutter = markerSublayers().first!
        let bg = NSColor(cgColor: gutter.backgroundColor!)!
        XCTAssertEqual(bg.alphaComponent, 0.55, accuracy: 0.01,
                       "default success alpha must remain 0.55")
    }
}
