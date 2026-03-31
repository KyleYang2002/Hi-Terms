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
    public static func measure(font: NSFont) -> FontMetrics {
        let cellWidth = font.advancement(forGlyph: NSGlyph(font.glyph(withName: "M"))).width
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
