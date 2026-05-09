import Foundation

/// Logical text for a single screen row, with bidirectional mappings between
/// character positions and terminal cell columns.
///
/// Built from a `ScreenBufferSnapshot` row using the same cell-to-character rules
/// `SelectionTextExtractor` follows: CJK continuation cells (`width == 0`) are
/// dropped, NUL or empty characters become a single space. The mapping is needed
/// because regex matches operate on `String.Index`es, but mouse events arrive in
/// terminal columns — and CJK + emoji turn that into a non-trivial conversion.
public struct RowText: Sendable {
    public let text: String
    public let cols: Int
    /// For each character produced into `text`, the terminal cell column it began at.
    /// Length matches `text`'s logical character count (not UTF-16).
    public let charCols: [Int]

    public init(text: String, cols: Int, charCols: [Int]) {
        self.text = text
        self.cols = cols
        self.charCols = charCols
    }

    /// Returns the `String.Index` that lies at terminal column `col`, or nil
    /// when `col` falls inside a CJK continuation / past the last produced char.
    public func charIndex(forCol col: Int) -> String.Index? {
        guard col >= 0, col < cols else { return nil }
        var charIdx = 0
        for produced in charCols {
            if produced == col {
                return text.index(text.startIndex, offsetBy: charIdx)
            }
            if produced > col {
                // Hit a column beyond `col` — the requested column is a CJK
                // continuation slot for the previous lead char.
                if charIdx == 0 { return nil }
                return text.index(text.startIndex, offsetBy: charIdx - 1)
            }
            charIdx += 1
        }
        return nil
    }

    /// Returns the closed cell-column range covered by characters in `[lower, upper)`.
    /// `range` is in character offsets relative to `text.startIndex`.
    public func cellRange(forCharRange range: Range<String.Index>) -> ClosedRange<Int>? {
        let lowerOffset = text.distance(from: text.startIndex, to: range.lowerBound)
        let upperOffset = text.distance(from: text.startIndex, to: range.upperBound)
        guard lowerOffset >= 0, upperOffset > lowerOffset, upperOffset <= charCols.count else {
            return nil
        }
        let startCol = charCols[lowerOffset]
        let lastChar = upperOffset - 1
        // Include continuation slots after the last character — e.g. a wide CJK
        // at the end occupies its lead column plus the slot after it.
        let endCol: Int
        if lastChar + 1 < charCols.count {
            endCol = charCols[lastChar + 1] - 1
        } else {
            endCol = cols - 1
        }
        guard startCol <= endCol else { return nil }
        return startCol...endCol
    }
}

public enum RowTextBuilder {
    /// Builds a `RowText` for the given `row` of `snapshot`. Out-of-range rows
    /// produce an empty result. Trailing spaces are kept (callers that want to
    /// trim should do so themselves; the column mapping must remain dense).
    public static func build(snapshot: ScreenBufferSnapshot, row: Int) -> RowText {
        let cols = snapshot.cols
        guard row >= 0, row < snapshot.rows, cols > 0 else {
            return RowText(text: "", cols: max(cols, 0), charCols: [])
        }

        var text = ""
        var charCols: [Int] = []
        text.reserveCapacity(cols)
        charCols.reserveCapacity(cols)

        var col = 0
        while col < cols {
            let cell = snapshot[row, col]
            if cell.width == 0 {
                col += 1
                continue
            }
            let ch = cell.character
            if ch == "\0" || ch.unicodeScalars.isEmpty {
                text.append(" ")
            } else {
                text.append(ch)
            }
            charCols.append(col)
            col += 1
        }

        return RowText(text: text, cols: cols, charCols: charCols)
    }
}
