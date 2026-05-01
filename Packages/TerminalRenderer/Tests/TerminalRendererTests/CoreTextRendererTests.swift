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

    // MARK: - Cursor Inset

    /// The cursor block must land at the content-inset origin, not at (0, 0),
    /// so it lines up with the inset text layer.
    func testCursorBlockOriginIncludesContentInset() {
        let cursor = CursorState(row: 0, col: 0, style: .block, visible: true)
        let layer = CALayer()
        let metrics = renderer.fontMetrics
        let totalRows = 25

        renderer.updateCursor(cursor: cursor, fontMetrics: metrics,
                              cursorLayer: layer, totalRows: totalRows)

        let inset = TerminalLayout.contentInset
        let expectedY = inset.height + CGFloat(totalRows - 1) * metrics.cellHeight
        XCTAssertEqual(layer.frame.origin.x, inset.width, accuracy: 0.01)
        XCTAssertEqual(layer.frame.origin.y, expectedY, accuracy: 0.01)
    }

    func testCursorAtNonOriginAccountsForInset() {
        let cursor = CursorState(row: 5, col: 7, style: .block, visible: true)
        let layer = CALayer()
        let metrics = renderer.fontMetrics
        let totalRows = 25

        renderer.updateCursor(cursor: cursor, fontMetrics: metrics,
                              cursorLayer: layer, totalRows: totalRows)

        let inset = TerminalLayout.contentInset
        let expectedX = inset.width + CGFloat(7) * metrics.cellWidth
        let expectedY = inset.height + CGFloat(totalRows - 1 - 5) * metrics.cellHeight
        XCTAssertEqual(layer.frame.origin.x, expectedX, accuracy: 0.01)
        XCTAssertEqual(layer.frame.origin.y, expectedY, accuracy: 0.01)
    }

    // MARK: - Retina-aware bitmap

    /// Render once into a layer with `contentsScale = 2` and verify the text
    /// sublayer's image was produced at 2x physical pixels — guarding against
    /// regressions where the bitmap is built at @1x and then stretched, which
    /// is what makes glyphs look blurry on Retina screens.
    func testTextLayerReceivesBackingScaleAlignedImage() throws {
        let cols = 4
        let rows = 2
        let buffer = ScreenBuffer(rows: rows, cols: cols)
        // Mark all cells dirty so the renderer rebuilds the bitmap.
        let dirty = DirtyRegion()
        dirty.merge(rows: 0..<rows)

        let host = CALayer()
        host.contentsScale = 2.0
        host.frame = CGRect(x: 0, y: 0,
                            width: renderer.fontMetrics.cellWidth * CGFloat(cols),
                            height: renderer.fontMetrics.cellHeight * CGFloat(rows))

        renderer.render(buffer: buffer.snapshot(), dirtyRegion: dirty,
                        cursor: CursorState(visible: false), into: host)

        let textLayer = host.sublayers?.first(where: { $0.name == "hi-terms-text" })
        XCTAssertNotNil(textLayer, "renderer must add a text sublayer")
        XCTAssertEqual(textLayer?.contentsScale, 2.0,
                       "text layer must adopt the host layer's backing scale")

        let image = textLayer?.contents as! CGImage?
        XCTAssertNotNil(image, "render must produce a CGImage")

        // Bitmap must be at @2x physical pixels.
        let expectedPxW = Int(ceil(renderer.fontMetrics.cellWidth * CGFloat(cols) * 2.0))
        let expectedPxH = Int(ceil(renderer.fontMetrics.cellHeight * CGFloat(rows) * 2.0))
        XCTAssertEqual(image?.width, expectedPxW,
                       "bitmap width must equal logical-width × backingScale")
        XCTAssertEqual(image?.height, expectedPxH,
                       "bitmap height must equal logical-height × backingScale")

        let inset = TerminalLayout.contentInset
        let unwrapped = try XCTUnwrap(textLayer)
        XCTAssertEqual(unwrapped.frame.origin.x, inset.width, accuracy: 0.01,
                       "text layer must be offset by the content inset")
        XCTAssertEqual(unwrapped.frame.origin.y, inset.height, accuracy: 0.01)
    }

    // MARK: - Wide-character (CJK) rendering

    /// A wide char with non-default bg must paint its full 2-column span. The
    /// continuation cell (width==0, default attrs) must NOT punch a default-bg
    /// hole next to the primary cell — that's the "white block beside Chinese
    /// chars in codex inverse input" regression.
    func testWideCharBackgroundMergesAcrossContinuation() throws {
        let cols = 4
        let rows = 1
        let buffer = ScreenBuffer(rows: rows, cols: cols)
        let bgAttrs = TextAttributes(backgroundColor: .trueColor(r: 60, g: 180, b: 75))
        buffer[0, 0] = Cell(character: "中", attributes: bgAttrs, width: 2)
        buffer[0, 1] = Cell(character: " ", attributes: .default, width: 0)
        buffer[0, 2] = Cell(character: "x", attributes: .default, width: 1)
        buffer[0, 3] = Cell(character: " ", attributes: .default, width: 1)

        let host = renderHost(buffer: buffer)
        // Sample near the bottom edge of each cell to dodge the glyph body.
        let pixels = try samplePixels(in: host, atColumns: [0, 1, 2],
                                       row: 0, xFraction: 0.5, yFraction: 0.97)

        // Cells 0 and 1 must carry the green bg; cell 2 must clearly differ
        // (it's the default bg — resolved value depends on appearance, so
        // assert distance from the green rather than an absolute value).
        let expected = NSColor(srgbRed: 60.0/255.0, green: 180.0/255.0,
                                blue: 75.0/255.0, alpha: 1.0)
        assertSampledColor(pixels[0], matches: expected, "primary wide-char cell bg")
        assertSampledColor(pixels[1], matches: expected,
                           "continuation cell must inherit primary bg (white-block regression)")
        assertSampledColorsDiffer(pixels[2], from: expected,
                                  "default cell must not pick up the wide char's bg")
    }

    /// Two adjacent wide chars with the same explicit bg should produce one
    /// continuous bg run across all 4 columns — no default-bg gap at the
    /// continuation cells.
    func testWideCharRunWithSameInverseAttrFillsContinuously() throws {
        let cols = 4
        let rows = 1
        let buffer = ScreenBuffer(rows: rows, cols: cols)
        let bgAttrs = TextAttributes(backgroundColor: .trueColor(r: 220, g: 50, b: 50))
        buffer[0, 0] = Cell(character: "中", attributes: bgAttrs, width: 2)
        buffer[0, 1] = Cell(character: " ", attributes: .default, width: 0)
        buffer[0, 2] = Cell(character: "文", attributes: bgAttrs, width: 2)
        buffer[0, 3] = Cell(character: " ", attributes: .default, width: 0)

        let host = renderHost(buffer: buffer)
        let pixels = try samplePixels(in: host, atColumns: [0, 1, 2, 3],
                                       row: 0, xFraction: 0.5, yFraction: 0.97)

        let expected = NSColor(srgbRed: 220.0/255.0, green: 50.0/255.0,
                                blue: 50.0/255.0, alpha: 1.0)
        for (i, color) in pixels.enumerated() {
            assertSampledColor(color, matches: expected,
                               "column \(i) must carry the bg without continuation gap")
        }
    }

    /// Cursor placed on a wide char's primary cell must span both columns so
    /// the glyph isn't half-occluded.
    func testCursorBlockOnWideCharSpansTwoCells() {
        let cols = 4
        let rows = 1
        let buffer = ScreenBuffer(rows: rows, cols: cols)
        buffer[0, 0] = Cell(character: "中", attributes: .default, width: 2)
        buffer[0, 1] = Cell(character: " ", attributes: .default, width: 0)
        buffer.cursor = CursorState(row: 0, col: 0, style: .block, visible: true)

        let host = renderHost(buffer: buffer)
        let cursorLayer = host.sublayers?.first(where: { $0.name == "hi-terms-cursor" })
        XCTAssertNotNil(cursorLayer)
        XCTAssertEqual(cursorLayer!.frame.width,
                       2 * renderer.fontMetrics.cellWidth, accuracy: 0.01,
                       "cursor on wide char should be 2 cells wide")
        XCTAssertEqual(cursorLayer!.frame.height,
                       renderer.fontMetrics.cellHeight, accuracy: 0.01)
    }

    /// Sanity: cursor on a normal-width cell stays 1 cell wide.
    func testCursorBlockOnNormalCharIsOneCell() {
        let cols = 4
        let rows = 1
        let buffer = ScreenBuffer(rows: rows, cols: cols)
        buffer[0, 0] = Cell(character: "a", attributes: .default, width: 1)
        buffer.cursor = CursorState(row: 0, col: 0, style: .block, visible: true)

        let host = renderHost(buffer: buffer)
        let cursorLayer = host.sublayers?.first(where: { $0.name == "hi-terms-cursor" })
        XCTAssertNotNil(cursorLayer)
        XCTAssertEqual(cursorLayer!.frame.width,
                       renderer.fontMetrics.cellWidth, accuracy: 0.01,
                       "cursor on normal char stays 1 cell wide")
    }

    // MARK: - Pixel-sampling helpers

    /// Renders the buffer (all rows dirty) into a host CALayer at @1x and
    /// returns the host so tests can inspect the text/cursor sublayers.
    private func renderHost(buffer: ScreenBuffer) -> CALayer {
        let host = CALayer()
        host.contentsScale = 1.0
        host.frame = CGRect(x: 0, y: 0,
                            width: renderer.fontMetrics.cellWidth * CGFloat(buffer.cols),
                            height: renderer.fontMetrics.cellHeight * CGFloat(buffer.rows))
        let dirty = DirtyRegion()
        dirty.merge(rows: 0..<buffer.rows)
        renderer.render(buffer: buffer.snapshot(), dirtyRegion: dirty,
                        cursor: buffer.cursor, into: host)
        return host
    }

    /// Samples the text-layer bitmap at a given fractional position within
    /// each column on the given row. `xFraction`/`yFraction` are 0..1 within
    /// the cell — yFraction near 1.0 lands near the cell bottom, dodging the
    /// glyph body.
    private func samplePixels(in host: CALayer, atColumns columns: [Int],
                              row: Int,
                              xFraction: CGFloat = 0.5,
                              yFraction: CGFloat = 0.5) throws -> [NSColor] {
        let textLayer = try XCTUnwrap(
            host.sublayers?.first(where: { $0.name == "hi-terms-text" }))
        let cgImage = try XCTUnwrap(textLayer.contents as! CGImage?)

        // Re-draw the CGImage into a known-format sRGB context so we can read
        // bytes at deterministic offsets.
        let pxW = cgImage.width
        let pxH = cgImage.height
        let bytesPerRow = pxW * 4
        var bytes = [UInt8](repeating: 0, count: pxH * bytesPerRow)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = bytes.withUnsafeMutableBytes { ptr -> CGContext? in
            CGContext(data: ptr.baseAddress,
                      width: pxW, height: pxH,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let context = try XCTUnwrap(ctx)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // CGContext y-axis is bottom-up; row 0 lives near the top of the image.
        let cellH = renderer.fontMetrics.cellHeight
        let cellW = renderer.fontMetrics.cellWidth
        let logicalY = (CGFloat(row) + yFraction) * cellH
        let pixelY = max(0, min(pxH - 1, pxH - 1 - Int(logicalY)))
        return try columns.map { col in
            let logicalX = (CGFloat(col) + xFraction) * cellW
            let pixelX = Int(logicalX)
            guard pixelX >= 0, pixelX < pxW, pixelY >= 0, pixelY < pxH else {
                XCTFail("sample pixel out of bounds: (\(pixelX),\(pixelY))")
                throw NSError(domain: "test", code: 0)
            }
            let offset = pixelY * bytesPerRow + pixelX * 4
            // premultipliedLast: R, G, B, A
            let r = CGFloat(bytes[offset]) / 255.0
            let g = CGFloat(bytes[offset + 1]) / 255.0
            let b = CGFloat(bytes[offset + 2]) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        }
    }

    /// Asserts a sampled sRGB pixel matches an expected NSColor (also in sRGB)
    /// within a small tolerance to absorb rounding from CG draw + readback.
    private func assertSampledColor(_ sampled: NSColor, matches expected: NSColor,
                                    _ message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let s = sampled.usingColorSpace(.sRGB),
              let e = expected.usingColorSpace(.sRGB) else {
            XCTFail("color has no sRGB rep: \(sampled) vs \(expected) — \(message)",
                    file: file, line: line)
            return
        }
        let tol: CGFloat = 0.04
        XCTAssertEqual(s.redComponent, e.redComponent, accuracy: tol,
                       "red — \(message)", file: file, line: line)
        XCTAssertEqual(s.greenComponent, e.greenComponent, accuracy: tol,
                       "green — \(message)", file: file, line: line)
        XCTAssertEqual(s.blueComponent, e.blueComponent, accuracy: tol,
                       "blue — \(message)", file: file, line: line)
    }

    /// Asserts a sampled sRGB pixel is meaningfully different from the
    /// expected color (Manhattan distance > 0.2 in normalized RGB).
    private func assertSampledColorsDiffer(_ sampled: NSColor, from other: NSColor,
                                           _ message: String = "",
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        guard let s = sampled.usingColorSpace(.sRGB),
              let o = other.usingColorSpace(.sRGB) else {
            XCTFail("color has no sRGB rep — \(message)", file: file, line: line)
            return
        }
        let dr = abs(s.redComponent - o.redComponent)
        let dg = abs(s.greenComponent - o.greenComponent)
        let db = abs(s.blueComponent - o.blueComponent)
        XCTAssertGreaterThan(dr + dg + db, 0.2,
                             "expected colors to differ — \(message)",
                             file: file, line: line)
    }

    /// Switching the host layer's `contentsScale` (e.g. dragging the window
    /// from a Retina to a non-Retina screen) must rebuild the bitmap at the
    /// new density on the next render call.
    func testBitmapRebuildsWhenBackingScaleChanges() {
        let cols = 3
        let rows = 1
        let buffer = ScreenBuffer(rows: rows, cols: cols)

        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0,
                            width: renderer.fontMetrics.cellWidth * CGFloat(cols),
                            height: renderer.fontMetrics.cellHeight * CGFloat(rows))

        // First pass at @2x.
        host.contentsScale = 2.0
        let dirty1 = DirtyRegion(); dirty1.merge(rows: 0..<rows)
        renderer.render(buffer: buffer.snapshot(), dirtyRegion: dirty1,
                        cursor: CursorState(visible: false), into: host)
        let imageAt2x = (host.sublayers?.first(where: { $0.name == "hi-terms-text" })?.contents as! CGImage?)
        XCTAssertNotNil(imageAt2x)

        // Second pass at @1x — the cached bitmap must be discarded.
        host.contentsScale = 1.0
        let dirty2 = DirtyRegion(); dirty2.merge(rows: 0..<rows)
        renderer.render(buffer: buffer.snapshot(), dirtyRegion: dirty2,
                        cursor: CursorState(visible: false), into: host)
        let imageAt1x = (host.sublayers?.first(where: { $0.name == "hi-terms-text" })?.contents as! CGImage?)
        XCTAssertNotNil(imageAt1x)

        XCTAssertEqual(imageAt1x!.width, imageAt2x!.width / 2,
                       "switching to @1x must halve the bitmap width")
    }
}
