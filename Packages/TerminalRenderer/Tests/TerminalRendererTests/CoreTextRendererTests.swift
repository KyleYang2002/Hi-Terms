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

    func testColorMappingAnsi16Base() {
        // Codes 0-7: base ANSI palette
        for code in UInt8(0)..<8 {
            let color = renderer.nsColor(from: .ansi256(code: code), isForeground: true)
            XCTAssertEqual(color, CoreTextRenderer.ansi16Colors[Int(code)],
                           "ANSI base color code \(code) mismatch")
        }
    }

    func testColorMappingAnsi16Bright() {
        // Codes 8-15: bright ANSI palette — distinct from base, full saturation
        for code in UInt8(8)..<16 {
            let bright = renderer.nsColor(from: .ansi256(code: code), isForeground: true)
            let base = renderer.nsColor(from: .ansi256(code: code - 8), isForeground: true)
            XCTAssertEqual(bright, CoreTextRenderer.ansi16Colors[Int(code)],
                           "Bright code \(code) mismatch")
            XCTAssertNotEqual(bright, base,
                              "Bright code \(code) must differ from base \(code - 8)")
        }
    }

    func testColorMappingAnsi256CubeOrigin() {
        // Index 16 = (0, 0, 0) cube origin = pure black
        let color = renderer.nsColor(from: .ansi256(code: 16), isForeground: true)
        assertColor(color, red: 0, green: 0, blue: 0)
    }

    func testColorMappingAnsi256CubeMax() {
        // Index 231 = (5, 5, 5) cube max = pure white (255,255,255)
        let color = renderer.nsColor(from: .ansi256(code: 231), isForeground: true)
        assertColor(color, red: 255, green: 255, blue: 255)
    }

    func testColorMappingAnsi256CubeMid() {
        // Index 124 = 16 + 36*3 + 6*0 + 0 = (3, 0, 0) → (175, 0, 0)
        let color = renderer.nsColor(from: .ansi256(code: 124), isForeground: true)
        assertColor(color, red: 175, green: 0, blue: 0)

        // Index 46 = 16 + 36*0 + 6*5 + 0 = (0, 5, 0) → (0, 255, 0)
        let green = renderer.nsColor(from: .ansi256(code: 46), isForeground: true)
        assertColor(green, red: 0, green: 255, blue: 0)
    }

    func testColorMappingAnsi256GrayscaleEnds() {
        // Index 232 = darkest gray (value 8)
        let darkest = renderer.nsColor(from: .ansi256(code: 232), isForeground: true)
        assertColor(darkest, red: 8, green: 8, blue: 8)

        // Index 255 = lightest gray (value 8 + 23*10 = 238)
        let lightest = renderer.nsColor(from: .ansi256(code: 255), isForeground: true)
        assertColor(lightest, red: 238, green: 238, blue: 238)
    }

    func testColorMappingAnsi256GrayscaleMid() {
        // Index 244 = value 8 + 12*10 = 128 (mid gray)
        let mid = renderer.nsColor(from: .ansi256(code: 244), isForeground: true)
        assertColor(mid, red: 128, green: 128, blue: 128)
    }

    func testColorMappingTrueColor() {
        // Orange RGB = (255, 128, 0)
        let orange = renderer.nsColor(from: .trueColor(r: 255, g: 128, b: 0), isForeground: true)
        assertColor(orange, red: 255, green: 128, blue: 0)

        // Pure black + pure white round-trip
        assertColor(renderer.nsColor(from: .trueColor(r: 0, g: 0, b: 0), isForeground: true),
                    red: 0, green: 0, blue: 0)
        assertColor(renderer.nsColor(from: .trueColor(r: 255, g: 255, b: 255), isForeground: true),
                    red: 255, green: 255, blue: 255)
    }

    func testColorMappingTrueColorBackground() {
        // Background path returns the same color (isForeground only matters for .default/.defaultInverted)
        let bg = renderer.nsColor(from: .trueColor(r: 12, g: 34, b: 200), isForeground: false)
        assertColor(bg, red: 12, green: 34, blue: 200)
    }

    /// Compares an NSColor to expected 8-bit RGB components (after sRGB conversion).
    private func assertColor(_ color: NSColor, red: UInt8, green: UInt8, blue: UInt8,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Color has no sRGB representation: \(color)", file: file, line: line)
            return
        }
        let r = UInt8((rgb.redComponent * 255.0).rounded())
        let g = UInt8((rgb.greenComponent * 255.0).rounded())
        let b = UInt8((rgb.blueComponent * 255.0).rounded())
        XCTAssertEqual(r, red, "red mismatch", file: file, line: line)
        XCTAssertEqual(g, green, "green mismatch", file: file, line: line)
        XCTAssertEqual(b, blue, "blue mismatch", file: file, line: line)
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
