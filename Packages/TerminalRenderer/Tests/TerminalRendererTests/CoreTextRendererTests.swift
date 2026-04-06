import XCTest
import AppKit
import QuartzCore
import CoreText
import TerminalCore
@testable import TerminalRenderer

final class CoreTextRendererTests: XCTestCase {
    private var renderer: CoreTextRenderer!

    override func setUp() {
        super.setUp()
        let font = NSFont(name: "Menlo", size: 13)!
        renderer = CoreTextRenderer(font: font)
    }

    // MARK: - Color Mapping

    func testColorMappingDefault() {
        let fg = renderer.nsColor(from: .default, isForeground: true)
        let bg = renderer.nsColor(from: .default, isForeground: false)
        XCTAssertEqual(fg, .textColor)
        XCTAssertEqual(bg, .textBackgroundColor)
    }

    func testColorMappingDefaultInverted() {
        let fg = renderer.nsColor(from: .defaultInverted, isForeground: true)
        let bg = renderer.nsColor(from: .defaultInverted, isForeground: false)
        XCTAssertEqual(fg, .textBackgroundColor)
        XCTAssertEqual(bg, .textColor)
    }

    func testColorMappingAnsi8() {
        // Verify all 8 base ANSI colors map correctly
        for code in UInt8(0)..<8 {
            let color = renderer.nsColor(from: .ansi256(code: code), isForeground: true)
            XCTAssertEqual(color, CoreTextRenderer.ansi8Colors[Int(code)],
                           "ANSI color code \(code) mismatch")
        }
    }

    func testColorMappingBrightFallsBackToBase() {
        // Codes 8-15 (bright) fall back to 0-7 in V0.1
        for code in UInt8(8)..<16 {
            let bright = renderer.nsColor(from: .ansi256(code: code), isForeground: true)
            let base = renderer.nsColor(from: .ansi256(code: code - 8), isForeground: true)
            XCTAssertEqual(bright, base,
                           "Bright code \(code) should fall back to base \(code - 8)")
        }
    }

    func testColorMappingAnsi256FallsBackToDefault() {
        let color = renderer.nsColor(from: .ansi256(code: 128), isForeground: true)
        XCTAssertEqual(color, .textColor)
        let bg = renderer.nsColor(from: .ansi256(code: 200), isForeground: false)
        XCTAssertEqual(bg, .textBackgroundColor)
    }

    func testColorMappingTrueColorFallsBackToDefault() {
        let color = renderer.nsColor(from: .trueColor(r: 255, g: 128, b: 0), isForeground: true)
        XCTAssertEqual(color, .textColor)
    }

    // MARK: - Attribute Mapping

    func testAttributeMappingBold() {
        let attrs = TextAttributes(bold: true)
        let dict = renderer.ctAttributes(from: attrs)
        let ctFont = dict[.font] as! CTFont
        let traits = CTFontGetSymbolicTraits(ctFont)
        XCTAssertTrue(traits.contains(.boldTrait))
    }

    func testAttributeMappingItalic() {
        let attrs = TextAttributes(italic: true)
        let dict = renderer.ctAttributes(from: attrs)
        let ctFont = dict[.font] as! CTFont
        let traits = CTFontGetSymbolicTraits(ctFont)
        XCTAssertTrue(traits.contains(.italicTrait))
    }

    func testAttributeMappingUnderline() {
        let attrs = TextAttributes(underline: true)
        let dict = renderer.ctAttributes(from: attrs)
        let value = dict[.underlineStyle] as? Int
        XCTAssertEqual(value, NSUnderlineStyle.single.rawValue)
    }

    func testAttributeMappingStrikethrough() {
        let attrs = TextAttributes(strikethrough: true)
        let dict = renderer.ctAttributes(from: attrs)
        let value = dict[.strikethroughStyle] as? Int
        XCTAssertEqual(value, NSUnderlineStyle.single.rawValue)
    }

    func testAttributeMappingInverse() {
        // With inverse + red foreground, the effective foreground should become
        // the background color (default → defaultInverted)
        let attrs = TextAttributes(inverse: true, foregroundColor: .ansi256(code: 1))
        let dict = renderer.ctAttributes(from: attrs)
        // When inverse is set, foreground becomes background color (which is .default → .defaultInverted)
        let fg = dict[.foregroundColor] as? NSColor
        // defaultInverted for foreground returns textBackgroundColor
        XCTAssertEqual(fg, NSColor.textBackgroundColor)
    }

    // MARK: - Cursor

    func testCursorBlock() {
        let cursor = CursorState(row: 2, col: 3, style: .block, visible: true)
        let layer = CALayer()
        renderer.updateCursor(cursor: cursor, fontMetrics: renderer.fontMetrics,
                              cursorLayer: layer, totalRows: 25)
        XCTAssertFalse(layer.isHidden)
        XCTAssertEqual(layer.frame.width, renderer.fontMetrics.cellWidth, accuracy: 0.01)
        XCTAssertEqual(layer.frame.height, renderer.fontMetrics.cellHeight, accuracy: 0.01)
    }

    func testCursorUnderline() {
        let cursor = CursorState(row: 0, col: 0, style: .underline, visible: true)
        let layer = CALayer()
        renderer.updateCursor(cursor: cursor, fontMetrics: renderer.fontMetrics,
                              cursorLayer: layer, totalRows: 25)
        XCTAssertEqual(layer.frame.height, 2.0, accuracy: 0.01)
        XCTAssertEqual(layer.frame.width, renderer.fontMetrics.cellWidth, accuracy: 0.01)
    }

    func testCursorBar() {
        let cursor = CursorState(row: 0, col: 0, style: .bar, visible: true)
        let layer = CALayer()
        renderer.updateCursor(cursor: cursor, fontMetrics: renderer.fontMetrics,
                              cursorLayer: layer, totalRows: 25)
        XCTAssertEqual(layer.frame.width, 2.0, accuracy: 0.01)
        XCTAssertEqual(layer.frame.height, renderer.fontMetrics.cellHeight, accuracy: 0.01)
    }

    func testCursorHiddenWhenNotVisible() {
        let cursor = CursorState(row: 0, col: 0, style: .block, visible: false)
        let layer = CALayer()
        renderer.updateCursor(cursor: cursor, fontMetrics: renderer.fontMetrics,
                              cursorLayer: layer, totalRows: 25)
        XCTAssertTrue(layer.isHidden)
    }

    func testCursorBlinkAnimation() {
        let blinking = CursorState(row: 0, col: 0, style: .blinkingBlock, visible: true)
        let layer = CALayer()
        renderer.updateCursor(cursor: blinking, fontMetrics: renderer.fontMetrics,
                              cursorLayer: layer, totalRows: 25)
        XCTAssertNotNil(layer.animation(forKey: "blink"))

        // Non-blinking should remove animation
        let solid = CursorState(row: 0, col: 0, style: .block, visible: true)
        renderer.updateCursor(cursor: solid, fontMetrics: renderer.fontMetrics,
                              cursorLayer: layer, totalRows: 25)
        XCTAssertNil(layer.animation(forKey: "blink"))
    }

    // MARK: - Measure

    func testMeasureReturnsValidMetrics() {
        let font = NSFont(name: "Menlo", size: 13)!
        let metrics = renderer.measure(font: font)
        XCTAssertGreaterThan(metrics.cellWidth, 0)
        XCTAssertGreaterThan(metrics.cellHeight, 0)
        XCTAssertGreaterThan(metrics.baseline, 0)
    }
}
