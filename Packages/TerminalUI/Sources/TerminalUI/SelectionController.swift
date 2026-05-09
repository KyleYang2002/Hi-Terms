import AppKit
import TerminalCore

/// Owns the live selection state for a terminal view.
///
/// Wave 2-A scope: tracks anchor/head + mode in response to mouse drag events,
/// snaps to word/line via `SelectionTextExtractor`, and writes the extracted
/// text to a pasteboard on demand.
///
/// Coordinate convention: `GridPoint.row` is treated as the *current viewport
/// row* (0-based, top of the visible area = 0). Wave 2-A defers a
/// scroll-invariant absolute row mapping until `TerminalView` exposes a stable
/// way to reach SwiftTerm's `yDisp`. See TODO in `TerminalView`.
@MainActor
public final class SelectionController {
    public private(set) var current: Selection?

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    // MARK: - Drag lifecycle

    /// Begins a new drag at `point`. `clickCount` controls the initial mode:
    /// 1 = character, 2 = word (caller must call `snapToWord` next),
    /// 3 = line (caller calls `snapToLine`).
    public func beginDrag(at point: GridPoint, clickCount: Int) {
        let mode: SelectionMode
        switch clickCount {
        case 2: mode = .word
        case let n where n >= 3: mode = .line
        default: mode = .character
        }
        current = Selection(anchor: point, head: point, mode: mode)
    }

    /// Extends the current drag's `head` to `point`. Word/line snapping is the
    /// caller's responsibility (it requires a snapshot).
    public func extendDrag(to point: GridPoint) {
        guard var selection = current else { return }
        selection.head = point
        current = selection
    }

    /// Finalizes the drag at `point`. Currently equivalent to `extendDrag`;
    /// kept as its own entry point so future versions can hook drag-end logic
    /// (e.g. auto-copy on selection finish).
    public func endDrag(at point: GridPoint) {
        guard var selection = current else { return }
        selection.head = point
        current = selection
    }

    /// Discards the current selection.
    public func clear() {
        current = nil
    }

    // MARK: - Snapping

    /// Snaps the current selection's head to a word boundary using the given
    /// snapshot. No-op when the selection is missing or not in word mode.
    public func snapToWord(in snapshot: ScreenBufferSnapshot, cols: Int) {
        guard var selection = current, selection.mode == .word else { return }
        let anchorWord = SelectionTextExtractor.expandToWord(
            at: selection.anchor, in: snapshot, cols: cols)
        let headWord = SelectionTextExtractor.expandToWord(
            at: selection.head, in: snapshot, cols: cols)

        // Pick the outer endpoints so dragging across multiple words grows the
        // selection in both directions.
        let (rowStart, rowEnd) = selection.anchor.row <= selection.head.row
            ? (selection.anchor.row, selection.head.row)
            : (selection.head.row, selection.anchor.row)

        let anchor: GridPoint
        let head: GridPoint
        if rowStart == rowEnd {
            let lo = min(anchorWord.startCol, headWord.startCol)
            let hi = max(anchorWord.endCol, headWord.endCol)
            anchor = GridPoint(row: rowStart, col: lo)
            head = GridPoint(row: rowEnd, col: hi)
        } else if selection.anchor.row <= selection.head.row {
            anchor = GridPoint(row: selection.anchor.row, col: anchorWord.startCol)
            head = GridPoint(row: selection.head.row, col: headWord.endCol)
        } else {
            anchor = GridPoint(row: selection.head.row, col: headWord.startCol)
            head = GridPoint(row: selection.anchor.row, col: anchorWord.endCol)
        }

        selection.anchor = anchor
        selection.head = head
        current = selection
    }

    /// Snaps the current selection to whole rows (no snapshot needed because
    /// `SelectionGeometry.expand` already widens line-mode rows to `0...cols-1`).
    public func snapToLine(cols: Int) {
        guard var selection = current, selection.mode == .line else { return }
        // Anchor/head columns are not meaningful in line mode; clamp them so
        // downstream consumers always see in-range values.
        let lastCol = max(0, cols - 1)
        selection.anchor = GridPoint(row: selection.anchor.row, col: 0)
        selection.head = GridPoint(row: selection.head.row, col: lastCol)
        current = selection
    }

    // MARK: - Pasteboard

    /// Extracts the current selection's text from `snapshot` and writes it to
    /// the pasteboard. Returns `true` only when non-empty text was written.
    @discardableResult
    public func copyToPasteboard(snapshot: ScreenBufferSnapshot, cols: Int) -> Bool {
        guard let selection = current, !selection.isEmpty else { return false }
        let text = SelectionTextExtractor.extract(
            from: snapshot, selection: selection, cols: cols)
        // `.line` mode always appends a trailing newline. Treat a newline-only
        // string as empty for the purpose of "did we copy anything useful".
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }
}
