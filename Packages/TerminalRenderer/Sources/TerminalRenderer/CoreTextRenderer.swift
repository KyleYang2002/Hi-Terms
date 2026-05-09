import AppKit
import CoreText
import QuartzCore
import TerminalCore

/// CoreText-based terminal renderer.
///
/// Renders ScreenBufferSnapshot content into a CALayer using CoreText for text
/// drawing. Supports the full xterm-256color palette (16 system colors + 6×6×6
/// RGB cube + 24-level grayscale), 24-bit True Color, text attributes (bold/
/// italic/underline/strikethrough/inverse/dim/invisible), and cursor rendering
/// with blink animation.
public final class CoreTextRenderer: TerminalRendering {
    private let font: CTFont
    public let fontMetrics: FontMetrics

    /// Persistent bitmap context, recreated on size or backing-scale change.
    private var bitmapContext: CGContext?
    private var lastSize: CGSize = .zero
    private var lastScale: CGFloat = 0

    public init(font: NSFont) {
        self.font = font as CTFont
        self.fontMetrics = FontMetrics.measure(font: font)
    }

    // MARK: - TerminalRendering

    public func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        selection: SelectionOverlay?,
        into layer: CALayer
    ) {
        let dirtyRows = dirtyRegion.swapAndClear()

        // The selection overlay is independent of the bitmap pipeline. Update
        // it before any early-return so changes to (or clears of) the selection
        // take effect even when the text bitmap has nothing dirty.
        updateSelectionOverlay(selection, in: layer, buffer: buffer)

        guard !dirtyRows.isEmpty else { return }

        let width = fontMetrics.cellWidth * CGFloat(buffer.cols)
        let height = fontMetrics.cellHeight * CGFloat(buffer.rows)
        let size = CGSize(width: width, height: height)

        // Match the bitmap's pixel density to the host layer's `contentsScale`,
        // which TerminalView keeps in sync with the window's `backingScaleFactor`.
        // A non-positive scale here would produce a degenerate context, so clamp
        // to 1.0 as a safety net for layers that have not been configured yet.
        let scale = layer.contentsScale > 0 ? layer.contentsScale : 1.0

        let context = obtainContext(size: size, scale: scale)
        guard let context else { return }

        for row in dirtyRows {
            guard row >= 0, row < buffer.rows else { continue }
            let y = CGFloat(buffer.rows - 1 - row) * fontMetrics.cellHeight
            // Clear the row region
            context.saveGState()
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: y, width: width, height: fontMetrics.cellHeight))
            context.restoreGState()

            drawRowBackground(buffer: buffer, row: row, y: y, context: context)
            drawRowText(buffer: buffer, row: row, y: y, context: context)
        }

        let inset = TerminalLayout.contentInset

        // Update text layer contents
        let textLayer = findOrCreateTextLayer(in: layer, size: size, scale: scale, inset: inset)
        textLayer.contents = context.makeImage()

        // Update cursor. Wide-char cells get a 2-cell-wide cursor block so the
        // glyph isn't half-occluded; bar/vertical cursors stay narrow.
        let cursorLayer = findOrCreateCursorLayer(in: layer)
        let cursorCell: Cell = {
            guard cursor.row >= 0, cursor.row < buffer.rows,
                  cursor.col >= 0, cursor.col < buffer.cols else {
                return .empty
            }
            return buffer[cursor.row, cursor.col]
        }()
        let cursorMultiplier = cursorCell.width == 2 ? 2 : 1
        updateCursor(cursor: cursor, fontMetrics: fontMetrics, cursorLayer: cursorLayer,
                     totalRows: buffer.rows, inset: inset,
                     cellWidthMultiplier: cursorMultiplier)
    }

    public func measure(font: NSFont) -> FontMetrics {
        FontMetrics.measure(font: font)
    }

    // MARK: - Bitmap Context

    private func obtainContext(size: CGSize, scale: CGFloat) -> CGContext? {
        if let bitmapContext, lastSize == size, lastScale == scale {
            return bitmapContext
        }
        let pxW = Int(ceil(size.width * scale))
        let pxH = Int(ceil(size.height * scale))
        guard pxW > 0, pxH > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        // Map the logical (point) coordinate system onto the physical bitmap so
        // callers can keep drawing in points and get @scale rendering for free.
        ctx?.scaleBy(x: scale, y: scale)

        ctx?.setAllowsFontSmoothing(true)
        ctx?.setShouldSmoothFonts(true)
        ctx?.setAllowsAntialiasing(true)
        ctx?.setShouldAntialias(true)
        // Subpixel positioning makes glyph kerning land on fractional points,
        // which is what macOS Terminal/iTerm do on Retina; sharper than
        // forcing integer pixel snapping.
        ctx?.setAllowsFontSubpixelPositioning(true)
        ctx?.setShouldSubpixelPositionFonts(true)
        ctx?.setAllowsFontSubpixelQuantization(true)
        ctx?.setShouldSubpixelQuantizeFonts(true)

        // Fill with background color (in logical coordinates, scaleCTM is active)
        if let ctx {
            ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }

        self.bitmapContext = ctx
        self.lastSize = size
        self.lastScale = scale
        return ctx
    }

    // MARK: - Layer Management

    private func findOrCreateTextLayer(in parent: CALayer, size: CGSize,
                                       scale: CGFloat, inset: CGSize) -> CALayer {
        let name = "hi-terms-text"
        let frame = CGRect(origin: CGPoint(x: inset.width, y: inset.height), size: size)
        if let existing = parent.sublayers?.first(where: { $0.name == name }) {
            existing.frame = frame
            existing.contentsScale = scale
            return existing
        }
        let layer = CALayer()
        layer.name = name
        layer.frame = frame
        layer.contentsScale = scale
        parent.addSublayer(layer)
        return layer
    }

    private func findOrCreateCursorLayer(in parent: CALayer) -> CALayer {
        let name = "hi-terms-cursor"
        if let existing = parent.sublayers?.first(where: { $0.name == name }) {
            return existing
        }
        let layer = CALayer()
        layer.name = name
        layer.backgroundColor = NSColor.textColor.cgColor
        parent.addSublayer(layer)
        return layer
    }

    /// Selection overlay: a transparent host layer that contains one filled
    /// child rectangle per highlighted row segment. Updates run on every render
    /// pass so a cleared selection drops back to zero children immediately.
    private func findOrCreateSelectionLayer(in parent: CALayer) -> CALayer {
        let name = "hi-terms-selection"
        if let existing = parent.sublayers?.first(where: { $0.name == name }) {
            return existing
        }
        let layer = CALayer()
        layer.name = name
        layer.backgroundColor = NSColor.clear.cgColor
        // Sit above the text/cursor layers; backed by NSView's root layer in
        // production, by a plain CALayer in tests.
        layer.zPosition = 10
        parent.addSublayer(layer)
        return layer
    }

    /// Mutates the selection-overlay layer to match `selection`. Disables
    /// implicit CALayer animations so highlight rectangles snap into place
    /// without fading.
    private func updateSelectionOverlay(
        _ selection: SelectionOverlay?,
        in parent: CALayer,
        buffer: ScreenBufferSnapshot
    ) {
        let host = findOrCreateSelectionLayer(in: parent)
        let inset = TerminalLayout.contentInset

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Mirror the parent's frame so child geometry uses the same coordinate
        // space the text/cursor layers share.
        host.frame = parent.bounds
        host.sublayers?.removeAll()

        guard let selection, !selection.isEmpty else { return }

        let highlightColor = NSColor.selectedTextBackgroundColor
            .withAlphaComponent(0.45).cgColor

        for segment in selection.segments {
            let row = segment.viewportRow
            guard row >= 0, row < buffer.rows else { continue }
            let lower = max(0, segment.cols.lowerBound)
            let upper = min(buffer.cols - 1, segment.cols.upperBound)
            guard lower <= upper else { continue }

            let x = inset.width + CGFloat(lower) * fontMetrics.cellWidth
            // Match the cursor's coordinate system: row 0 at the top, CG y up.
            let y = inset.height
                + CGFloat(buffer.rows - 1 - row) * fontMetrics.cellHeight
            let width = CGFloat(upper - lower + 1) * fontMetrics.cellWidth
            let rect = CGRect(x: x, y: y, width: width, height: fontMetrics.cellHeight)

            let segmentLayer = CALayer()
            segmentLayer.frame = rect
            segmentLayer.backgroundColor = highlightColor
            host.addSublayer(segmentLayer)
        }
    }

    // MARK: - Row Drawing

    private func drawRowBackground(buffer: ScreenBufferSnapshot, row: Int, y: CGFloat,
                                   context: CGContext) {
        var col = 0
        while col < buffer.cols {
            let cell = buffer[row, col]

            // Skip orphan continuation cells (defensive — primary cell's fill
            // covers the wide-char span, so a leading width==0 shouldn't start a run).
            if cell.width == 0 {
                col += 1
                continue
            }

            let attrs = cell.attributes
            let bgColor: TerminalColor
            if attrs.inverse {
                bgColor = attrs.foregroundColor == .default ? .defaultInverted : attrs.foregroundColor
            } else {
                bgColor = attrs.backgroundColor
            }

            guard bgColor != .default else {
                col += 1
                continue
            }

            // Merge consecutive cells with the same background. Continuation
            // cells (width==0) are folded into the current run so a wide char
            // with bg gets its full 2-column span painted.
            let startCol = col
            while col < buffer.cols {
                let nextCell = buffer[row, col]
                if nextCell.width == 0 {
                    col += 1
                    continue
                }
                let nextAttrs = nextCell.attributes
                let nextBg: TerminalColor
                if nextAttrs.inverse {
                    nextBg = nextAttrs.foregroundColor == .default ? .defaultInverted : nextAttrs.foregroundColor
                } else {
                    nextBg = nextAttrs.backgroundColor
                }
                guard nextBg == bgColor else { break }
                col += 1
            }

            let x = CGFloat(startCol) * fontMetrics.cellWidth
            let w = CGFloat(col - startCol) * fontMetrics.cellWidth
            context.setFillColor(nsColor(from: bgColor, isForeground: false).cgColor)
            context.fill(CGRect(x: x, y: y, width: w, height: fontMetrics.cellHeight))
        }
    }

    private func drawRowText(buffer: ScreenBufferSnapshot, row: Int, y: CGFloat,
                             context: CGContext) {
        var col = 0
        while col < buffer.cols {
            let cell = buffer[row, col]

            // Skip continuation cells (second cell of a wide character)
            if cell.width == 0 {
                col += 1
                continue
            }

            // Skip empty/space cells with default attributes
            if cell.character == " " && cell.attributes == .default {
                col += 1
                continue
            }

            // Find run of consecutive non-continuation cells with the same attributes
            let startCol = col
            let runAttrs = cell.attributes
            var charEntries: [(character: Character, col: Int)] = []

            while col < buffer.cols {
                let c = buffer[row, col]
                // Skip continuation cells within the run
                if c.width == 0 {
                    col += 1
                    continue
                }
                guard c.attributes == runAttrs else { break }
                charEntries.append((character: c.character, col: col))
                col += 1
            }

            // Skip runs that are all spaces with default fg and no decorations
            if charEntries.allSatisfy({ $0.character == " " }) && runAttrs.foregroundColor == .default && !runAttrs.underline && !runAttrs.strikethrough {
                continue
            }

            guard !runAttrs.invisible else { continue }

            // Draw each character at its grid-aligned position to avoid glyph advance drift
            let ctAttrs = ctAttributes(from: runAttrs)
            context.saveGState()

            for entry in charEntries {
                let charStr = String(entry.character)
                let attrString = NSAttributedString(string: charStr, attributes: ctAttrs)
                let line = CTLineCreateWithAttributedString(attrString)
                let x = CGFloat(entry.col) * fontMetrics.cellWidth
                context.textPosition = CGPoint(x: x, y: y + fontMetrics.baseline)
                CTLineDraw(line, context)
            }

            // Draw underline across the full run span
            if runAttrs.underline {
                let fgColor = effectiveForegroundColor(from: runAttrs)
                context.setStrokeColor(nsColor(from: fgColor, isForeground: true).cgColor)
                context.setLineWidth(1.0)
                let underlineY = y + 1.0
                let runStartX = CGFloat(startCol) * fontMetrics.cellWidth
                let runEndX = CGFloat(col) * fontMetrics.cellWidth
                context.move(to: CGPoint(x: runStartX, y: underlineY))
                context.addLine(to: CGPoint(x: runEndX, y: underlineY))
                context.strokePath()
            }

            // Draw strikethrough across the full run span
            if runAttrs.strikethrough {
                let fgColor = effectiveForegroundColor(from: runAttrs)
                context.setStrokeColor(nsColor(from: fgColor, isForeground: true).cgColor)
                context.setLineWidth(1.0)
                let strikeY = y + fontMetrics.cellHeight / 2.0
                let runStartX = CGFloat(startCol) * fontMetrics.cellWidth
                let runEndX = CGFloat(col) * fontMetrics.cellWidth
                context.move(to: CGPoint(x: runStartX, y: strikeY))
                context.addLine(to: CGPoint(x: runEndX, y: strikeY))
                context.strokePath()
            }

            context.restoreGState()
        }
    }

    // MARK: - Color Mapping

    /// ANSI 16-color table (xterm defaults: 0-7 base + 8-15 bright).
    static let ansi16Colors: [NSColor] = [
        // Base (0-7)
        .black,                                                        // 0: Black
        NSColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 1.0),         // 1: Red
        NSColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 1.0),         // 2: Green
        NSColor(red: 0.8, green: 0.8, blue: 0.0, alpha: 1.0),         // 3: Yellow
        NSColor(red: 0.0, green: 0.0, blue: 0.8, alpha: 1.0),         // 4: Blue
        NSColor(red: 0.8, green: 0.0, blue: 0.8, alpha: 1.0),         // 5: Magenta
        NSColor(red: 0.0, green: 0.8, blue: 0.8, alpha: 1.0),         // 6: Cyan
        NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0),      // 7: White
        // Bright (8-15)
        NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0),         // 8:  Bright black
        NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0),         // 9:  Bright red
        NSColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0),         // 10: Bright green
        NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0),         // 11: Bright yellow
        NSColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0),         // 12: Bright blue
        NSColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0),         // 13: Bright magenta
        NSColor(red: 0.0, green: 1.0, blue: 1.0, alpha: 1.0),         // 14: Bright cyan
        NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),         // 15: Bright white
    ]

    /// xterm 256-color cube component values (used for indices 16-231).
    static let cubeLevels: [CGFloat] = [0, 95, 135, 175, 215, 255]

    /// Maps TerminalColor to NSColor.
    /// Supports the full xterm-256color palette (16 system + 6×6×6 cube + 24
    /// grayscale) and 24-bit True Color.
    func nsColor(from color: TerminalColor, isForeground: Bool) -> NSColor {
        switch color {
        case .default:
            return isForeground ? .textColor : .textBackgroundColor
        case .defaultInverted:
            return isForeground ? .textBackgroundColor : .textColor
        case .ansi256(let code):
            return Self.ansi256Color(code: code)
        case .trueColor(let r, let g, let b):
            return NSColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        }
    }

    /// Resolves an xterm 256-color index to NSColor.
    static func ansi256Color(code: UInt8) -> NSColor {
        let i = Int(code)
        if i < 16 {
            return ansi16Colors[i]
        } else if i < 232 {
            // 6×6×6 RGB cube. index = 16 + 36*r + 6*g + b, components ∈ [0,5]
            let v = i - 16
            let r = v / 36
            let g = (v / 6) % 6
            let b = v % 6
            return NSColor(
                red: cubeLevels[r] / 255.0,
                green: cubeLevels[g] / 255.0,
                blue: cubeLevels[b] / 255.0,
                alpha: 1.0
            )
        } else {
            // 24-level grayscale: value = 8 + (i - 232) * 10
            let gray = CGFloat(8 + (i - 232) * 10) / 255.0
            return NSColor(red: gray, green: gray, blue: gray, alpha: 1.0)
        }
    }

    // MARK: - Attribute Mapping

    /// Converts TextAttributes to a CoreText attribute dictionary.
    func ctAttributes(from attrs: TextAttributes) -> [NSAttributedString.Key: Any] {
        var dict: [NSAttributedString.Key: Any] = [:]

        // Font with bold/italic traits
        var traitMask: CTFontSymbolicTraits = []
        if attrs.bold { traitMask.insert(.boldTrait) }
        if attrs.italic { traitMask.insert(.italicTrait) }

        if !traitMask.isEmpty,
           let modified = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traitMask, traitMask) {
            dict[.font] = modified
        } else {
            dict[.font] = font
        }

        // Foreground color
        let fgColor = effectiveForegroundColor(from: attrs)
        var fg = nsColor(from: fgColor, isForeground: true)
        if attrs.dim {
            fg = fg.withAlphaComponent(0.5)
        }
        dict[.foregroundColor] = fg

        // Underline
        if attrs.underline {
            dict[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        // Strikethrough
        if attrs.strikethrough {
            dict[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        return dict
    }

    /// Resolves effective foreground color considering inverse attribute.
    private func effectiveForegroundColor(from attrs: TextAttributes) -> TerminalColor {
        if attrs.inverse {
            return attrs.backgroundColor == .default ? .defaultInverted : attrs.backgroundColor
        }
        return attrs.foregroundColor
    }

    // MARK: - Cursor Rendering

    /// Updates cursor layer position, size, and blink animation.
    ///
    /// `cellWidthMultiplier` widens block/underline cursors over wide
    /// (2-column) glyphs. Bar cursors stay narrow.
    func updateCursor(cursor: CursorState, fontMetrics: FontMetrics,
                      cursorLayer: CALayer, totalRows: Int,
                      inset: CGSize = TerminalLayout.contentInset,
                      cellWidthMultiplier: Int = 1) {
        guard cursor.visible else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false

        // CoreGraphics Y is flipped (0 at bottom). Both axes are offset by the
        // content inset so the cursor lines up with the text layer's origin.
        let x = inset.width + CGFloat(cursor.col) * fontMetrics.cellWidth
        let y = inset.height + CGFloat(totalRows - 1 - cursor.row) * fontMetrics.cellHeight
        let blockWidth = fontMetrics.cellWidth * CGFloat(cellWidthMultiplier)

        switch cursor.style {
        case .block, .blinkingBlock:
            cursorLayer.frame = CGRect(x: x, y: y,
                                       width: blockWidth, height: fontMetrics.cellHeight)
        case .underline, .blinkingUnderline:
            cursorLayer.frame = CGRect(x: x, y: y,
                                       width: blockWidth, height: 2)
        case .bar, .blinkingBar:
            cursorLayer.frame = CGRect(x: x, y: y,
                                       width: 2, height: fontMetrics.cellHeight)
        }

        let shouldBlink = [CursorStyle.blinkingBlock, .blinkingUnderline, .blinkingBar]
            .contains(cursor.style)
        if shouldBlink && cursorLayer.animation(forKey: "blink") == nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1.0
            animation.toValue = 0.0
            animation.duration = 0.5
            animation.autoreverses = true
            animation.repeatCount = .infinity
            cursorLayer.add(animation, forKey: "blink")
        } else if !shouldBlink {
            cursorLayer.removeAnimation(forKey: "blink")
        }
    }
}
