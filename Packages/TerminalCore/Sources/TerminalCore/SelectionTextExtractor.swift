import Foundation

/// Pure text extraction from a `ScreenBufferSnapshot` for a given `Selection`.
///
/// Callers are responsible for mapping any absolute (scroll-invariant) row
/// numbers in the `Selection` to snapshot-relative rows before invoking these
/// helpers.
public enum SelectionTextExtractor {
    /// Word-character set used for double-click word expansion. Matches the
    /// common terminal convention of treating identifier-ish and path-ish
    /// characters as part of the same "word".
    private static let wordExtraCharacters: Set<Character> = ["_", "-", ".", "/", "~", "$"]

    /// Extracts the text covered by `selection` from `snapshot`.
    ///
    /// Behavior:
    /// - Cells with `width == 0` are CJK continuation cells and are skipped.
    /// - A NUL character (`\0`) or empty character is rendered as a single space.
    /// - When a row range reaches the right edge of the screen
    ///   (`upperBound >= cols - 1`), trailing spaces are trimmed from that row.
    /// - Rows are joined with `"\n"`. The result has no trailing newline unless
    ///   the selection mode is `.line`.
    /// - Rows that fall outside the snapshot are emitted as empty strings so the
    ///   resulting newline structure still matches the visual selection.
    public static func extract(
        from snapshot: ScreenBufferSnapshot,
        selection: Selection,
        cols: Int
    ) -> String {
        guard cols >= 1 else { return "" }
        let segments = SelectionGeometry.expand(selection, cols: cols)
        guard !segments.isEmpty else { return "" }

        let lastCol = cols - 1
        var lines: [String] = []
        lines.reserveCapacity(segments.count)

        for segment in segments {
            let row = segment.row
            let range = segment.cols
            var line = ""

            if row >= 0 && row < snapshot.rows {
                let upperEffective = min(range.upperBound, snapshot.cols - 1)
                if range.lowerBound <= upperEffective {
                    var col = range.lowerBound
                    while col <= upperEffective {
                        let cell = snapshot[row, col]
                        if cell.width == 0 {
                            // CJK continuation; do not emit a separate character.
                            col += 1
                            continue
                        }
                        let ch = cell.character
                        if ch == "\0" || ch.unicodeScalars.isEmpty {
                            line.append(" ")
                        } else {
                            line.append(ch)
                        }
                        col += 1
                    }
                }
            }

            // Trim trailing spaces when the segment reaches the row's right edge.
            if range.upperBound >= lastCol {
                while line.last == " " {
                    line.removeLast()
                }
            }

            lines.append(line)
        }

        var result = lines.joined(separator: "\n")
        if selection.mode == .line {
            result.append("\n")
        }
        return result
    }

    /// Double-click word expansion: starting at `point`, scan left and right
    /// until a non-word character is reached.
    ///
    /// Word characters are alphanumerics plus `_`, `-`, `.`, `/`, `~`, `$`.
    /// CJK continuation cells (`width == 0`) are treated as belonging to the
    /// preceding wide character, so a double-click on a wide character returns
    /// a range that spans both the lead and continuation cells.
    ///
    /// Returns the original column for both endpoints when `point` is out of
    /// bounds or lands on a non-word character.
    public static func expandToWord(
        at point: GridPoint,
        in snapshot: ScreenBufferSnapshot,
        cols: Int
    ) -> (startCol: Int, endCol: Int) {
        let row = point.row
        let col = point.col
        guard cols >= 1,
              row >= 0, row < snapshot.rows,
              col >= 0, col < min(cols, snapshot.cols) else {
            return (col, col)
        }

        let lastCol = min(cols, snapshot.cols) - 1

        // Resolve continuation cells to their lead cell for the seed character.
        func leadCol(of c: Int) -> Int {
            var i = c
            while i > 0 && snapshot[row, i].width == 0 {
                i -= 1
            }
            return i
        }

        let seedLead = leadCol(of: col)
        let seedCell = snapshot[row, seedLead]
        guard isWordCharacter(seedCell.character) else {
            return (col, col)
        }

        // Scan left.
        var start = seedLead
        while start > 0 {
            let prev = start - 1
            let prevCell = snapshot[row, prev]
            if prevCell.width == 0 {
                // Continuation cell; keep walking left to find its lead.
                start = prev
                continue
            }
            if isWordCharacter(prevCell.character) {
                start = prev
            } else {
                break
            }
        }

        // Scan right; for wide characters (width == 2) include the trailing
        // continuation cell in the returned range.
        var end = seedLead
        let seedWidth = Int(seedCell.width)
        if seedWidth >= 2 {
            end = min(seedLead + seedWidth - 1, lastCol)
        }
        while end < lastCol {
            let next = end + 1
            let nextCell = snapshot[row, next]
            if nextCell.width == 0 {
                // Trailing continuation cell of the current character; absorb it.
                end = next
                continue
            }
            if isWordCharacter(nextCell.character) {
                let nextWidth = max(Int(nextCell.width), 1)
                end = min(next + nextWidth - 1, lastCol)
            } else {
                break
            }
        }

        return (start, end)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        if wordExtraCharacters.contains(character) {
            return true
        }
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            // Multi-scalar grapheme (e.g. CJK with combining marks): treat as a word char.
            return !character.isWhitespace && !character.isNewline
        }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
