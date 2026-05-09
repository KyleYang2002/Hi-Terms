import Foundation

/// A point on the scroll-invariant terminal grid.
///
/// `row` is an absolute row index that does not change as the screen scrolls;
/// callers are responsible for mapping to a snapshot row when extracting text.
public struct GridPoint: Equatable, Hashable, Sendable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

/// Selection granularity.
///
/// - `character`: free-form character-by-character selection.
/// - `word`: callers are expected to snap endpoints to word boundaries before
///   constructing the `Selection`; geometry expansion does not re-snap.
/// - `line`: every covered row is treated as a full line.
public enum SelectionMode: Sendable {
    case character
    case word
    case line
}

/// A directed selection on the grid.
public struct Selection: Equatable, Sendable {
    public var anchor: GridPoint
    public var head: GridPoint
    public var mode: SelectionMode

    public init(anchor: GridPoint, head: GridPoint, mode: SelectionMode) {
        self.anchor = anchor
        self.head = head
        self.mode = mode
    }

    /// True only for an empty character-mode selection (anchor == head).
    /// Word and line modes are never empty because they cover at least one cell/line.
    public var isEmpty: Bool {
        mode == .character && anchor == head
    }

    /// Returns the endpoints in row-major ascending order.
    public func normalized() -> (start: GridPoint, end: GridPoint) {
        if anchor.row < head.row || (anchor.row == head.row && anchor.col <= head.col) {
            return (anchor, head)
        } else {
            return (head, anchor)
        }
    }
}

/// Pure geometry helpers for turning a `Selection` into per-row column ranges.
public enum SelectionGeometry {
    /// Expand a selection into one entry per covered row.
    ///
    /// - Single row: `[(row, startCol...endCol)]`.
    /// - Multi-row character/word mode:
    ///   first row `[startCol...cols-1]`,
    ///   middle rows `[0...cols-1]`,
    ///   last row `[0...endCol]`.
    /// - Line mode: every covered row is `[0...cols-1]`.
    ///
    /// `cols` must be `>= 1`. Out-of-range columns in the input selection are
    /// clamped into `[0, cols-1]`.
    public static func expand(_ selection: Selection, cols: Int) -> [(row: Int, cols: ClosedRange<Int>)] {
        guard cols >= 1 else { return [] }
        let (rawStart, rawEnd) = selection.normalized()
        let lastCol = cols - 1

        func clamp(_ value: Int) -> Int {
            min(max(value, 0), lastCol)
        }

        let startRow = rawStart.row
        let endRow = rawEnd.row
        let startCol = clamp(rawStart.col)
        let endCol = clamp(rawEnd.col)

        // Line mode: every covered row is a full line.
        if selection.mode == .line {
            guard startRow <= endRow else { return [] }
            return (startRow...endRow).map { row in
                (row: row, cols: 0...lastCol)
            }
        }

        // Single row.
        if startRow == endRow {
            let lo = min(startCol, endCol)
            let hi = max(startCol, endCol)
            return [(row: startRow, cols: lo...hi)]
        }

        // Multi-row character / word mode.
        var result: [(row: Int, cols: ClosedRange<Int>)] = []
        result.reserveCapacity(endRow - startRow + 1)
        result.append((row: startRow, cols: startCol...lastCol))
        if endRow - startRow > 1 {
            for row in (startRow + 1)..<endRow {
                result.append((row: row, cols: 0...lastCol))
            }
        }
        result.append((row: endRow, cols: 0...endCol))
        return result
    }
}
