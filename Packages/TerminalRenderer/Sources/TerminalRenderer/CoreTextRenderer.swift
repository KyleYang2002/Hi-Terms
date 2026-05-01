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

    /// Persistent bitmap context, recreated on size change.
    private var bitmapContext: CGContext?
    private var lastSize: CGSize = .zero

    public init(font: NSFont) {
        self.font = font as CTFont
        self.fontMetrics = FontMetrics.measure(font: font)
    }

    // MARK: - TerminalRendering

    public func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        into layer: CALayer
    ) {
        let dirtyRows = dirtyRegion.swapAndClear()
        guard !dirtyRows.isEmpty else { return }

        let width = fontMetrics.cellWidth * CGFloat(buffer.cols)
        let height = fontMetrics.cellHeight * CGFloat(buffer.rows)
        let size = CGSize(width: width, height: height)

        let context = obtainContext(size: size)
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

        // Update text layer contents
        let textLayer = findOrCreateTextLayer(in: layer, size: size)
        textLayer.contents = context.makeImage()

        // Update cursor
        let cursorLayer = findOrCreateCursorLayer(in: layer)
        updateCursor(cursor: cursor, fontMetrics: fontMetrics, cursorLayer: cursorLayer,
                     totalRows: buffer.rows)
    }

    public func measure(font: NSFont) -> FontMetrics {
        FontMetrics.measure(font: font)
    }

    // MARK: - Bitmap Context

    private func obtainContext(size: CGSize) -> CGContext? {
        if let bitmapContext, lastSize == size {
            return bitmapContext
        }
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.setAllowsFontSmoothing(true)
        ctx?.setShouldSmoothFonts(true)
        ctx?.setAllowsAntialiasing(true)
        ctx?.setShouldAntialias(true)

        // Fill with background color
        if let ctx {
            ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        self.bitmapContext = ctx
        self.lastSize = size
        return ctx
    }

    // MARK: - Layer Management

    private func findOrCreateTextLayer(in parent: CALayer, size: CGSize) -> CALayer {
        let name = "hi-terms-text"
        if let existing = parent.sublayers?.first(where: { $0.name == name }) {
            existing.frame = CGRect(origin: .zero, size: size)
            return existing
        }
        let layer = CALayer()
        layer.name = name
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
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

    // MARK: - Row Drawing

    private func drawRowBackground(buffer: ScreenBufferSnapshot, row: Int, y: CGFloat,
                                   context: CGContext) {
        var col = 0
        while col < buffer.cols {
            let cell = buffer[row, col]
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

            // Merge consecutive cells with the same background
            let startCol = col
            while col < buffer.cols {
                let nextCell = buffer[row, col]
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
    func updateCursor(cursor: CursorState, fontMetrics: FontMetrics,
                      cursorLayer: CALayer, totalRows: Int) {
        guard cursor.visible else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false

        // CoreGraphics Y is flipped (0 at bottom)
        let x = CGFloat(cursor.col) * fontMetrics.cellWidth
        let y = CGFloat(totalRows - 1 - cursor.row) * fontMetrics.cellHeight

        switch cursor.style {
        case .block, .blinkingBlock:
            cursorLayer.frame = CGRect(x: x, y: y,
                                       width: fontMetrics.cellWidth, height: fontMetrics.cellHeight)
        case .underline, .blinkingUnderline:
            cursorLayer.frame = CGRect(x: x, y: y,
                                       width: fontMetrics.cellWidth, height: 2)
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
