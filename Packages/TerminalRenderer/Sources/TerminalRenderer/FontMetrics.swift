import AppKit

/// Computed metrics for a monospace terminal font.
public struct FontMetrics: Sendable {
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let baseline: CGFloat
    public let fontName: String
    public let fontSize: CGFloat

    public init(cellWidth: CGFloat, cellHeight: CGFloat, baseline: CGFloat,
                fontName: String, fontSize: CGFloat) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.baseline = baseline
        self.fontName = fontName
        self.fontSize = fontSize
    }

    /// Computes metrics for a given monospace font.
    /// `cellWidth` is rounded up to the nearest integer point so that successive
    /// columns land on integer pixel positions on a @1x display, avoiding
    /// cumulative subpixel drift across long rows.
    public static func measure(font: NSFont) -> FontMetrics {
        let rawAdvance = font.advancement(forGlyph: NSGlyph(font.glyph(withName: "M"))).width
        let cellWidth = ceil(rawAdvance)
        let cellHeight = ceil(font.ascender - font.descender + font.leading)
        let baseline = ceil(-font.descender)
        return FontMetrics(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            baseline: baseline,
            fontName: font.fontName,
            fontSize: font.pointSize
        )
    }
}

/// Visual padding between the terminal grid and the surrounding view edges.
/// Matches iTerm's default look-and-feel and prevents glyphs from touching the
/// window border.
public enum TerminalLayout {
    public static let contentInset = CGSize(width: 2, height: 2)
}
