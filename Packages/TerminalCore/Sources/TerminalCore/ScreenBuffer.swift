import Foundation

/// An immutable snapshot of the screen buffer, safe to read from any thread.
public struct ScreenBufferSnapshot: Sendable {
    public let cells: [[Cell]]
    public let cursor: CursorState
    public let rows: Int
    public let cols: Int

    public subscript(row: Int, col: Int) -> Cell {
        cells[row][col]
    }
}

/// Terminal character grid with dirty region tracking.
///
/// Mutable buffer used by the parser thread. Use `snapshot()` to create a
/// copy-on-write snapshot for the renderer thread.
public final class ScreenBuffer {
    public let rows: Int
    public let cols: Int
    private var cells: [[Cell]]
    public var cursor: CursorState

    public init(rows: Int = 25, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        self.cells = Array(
            repeating: Array(repeating: Cell.empty, count: cols),
            count: rows
        )
        self.cursor = CursorState()
    }

    public subscript(row: Int, col: Int) -> Cell {
        get {
            guard row >= 0, row < rows, col >= 0, col < cols else { return .empty }
            return cells[row][col]
        }
        set {
            guard row >= 0, row < rows, col >= 0, col < cols else { return }
            cells[row][col] = newValue
        }
    }

    /// Creates a copy-on-write snapshot of the current buffer state.
    ///
    /// The returned snapshot is `Sendable` and safe to pass to the main thread
    /// for rendering. Because `cells` is a Swift `Array` of `Array`s, the assignment
    /// is O(1) (reference copy); actual data copying is deferred until mutation.
    public func snapshot() -> ScreenBufferSnapshot {
        ScreenBufferSnapshot(
            cells: cells,
            cursor: cursor,
            rows: rows,
            cols: cols
        )
    }
}
