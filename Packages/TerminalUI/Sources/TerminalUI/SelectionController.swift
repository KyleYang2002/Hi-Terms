import AppKit
import TerminalCore

/// Owns the live selection state for a terminal view.
///
/// Wave 2-C scope: tracks anchor/head + mode in response to mouse drag
/// events, snaps to word/line via `SelectionTextExtractor`, and writes the
/// extracted text to a pasteboard on demand.
///
/// **Coordinate convention.** `current.anchor.row` and `current.head.row` are
/// *scroll-invariant absolute* buffer row ids (matching SwiftTerm's
/// `yDisp + viewportRow`). They do not move when the user scrolls or when the
/// PTY pushes new lines into scrollback, so a selection made before a scroll
/// keeps pointing at the same logical content.
///
/// `SelectionTextExtractor` and `SelectionGeometry`, however, work purely in
/// snapshot-relative coordinates. The snap/copy helpers here therefore take a
/// `topScrollInvariantRow` parameter that names the absolute row id sitting
/// at the snapshot's first line; they translate the controller's absolute
/// rows to snapshot rows before calling into the extractor and (for
/// `snapToWord` / `snapToLine`) translate the result back. The parameter
/// defaults to `0` so older callers that already operated in viewport
/// coordinates (notably `SelectionGatingTests.testCopyToPasteboardWritesExtractedText`)
/// keep working unchanged: with a viewport-aligned snapshot whose top
/// happens to be 0, abs == viewport.
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

    /// Snaps the current selection's anchor/head to word boundaries using the
    /// given snapshot. No-op when the selection is missing or not in word mode.
    ///
    /// - Parameter topScrollInvariantRow: The absolute row id sitting at
    ///   `snapshot[0]`. The selection is temporarily shifted into the
    ///   snapshot's coordinate space, snapped, then shifted back to absolute
    ///   coordinates so the controller's stored rows stay scroll-invariant.
    ///   Defaults to `0` for callers that already operate in viewport space.
    public func snapToWord(
        in snapshot: ScreenBufferSnapshot,
        cols: Int,
        topScrollInvariantRow: Int = 0
    ) {
        guard var selection = current, selection.mode == .word else { return }
        let top = topScrollInvariantRow
        let anchorViewport = GridPoint(row: selection.anchor.row - top, col: selection.anchor.col)
        let headViewport = GridPoint(row: selection.head.row - top, col: selection.head.col)
        let anchorWord = SelectionTextExtractor.expandToWord(
            at: anchorViewport, in: snapshot, cols: cols)
        let headWord = SelectionTextExtractor.expandToWord(
            at: headViewport, in: snapshot, cols: cols)

        // Pick the outer endpoints so dragging across multiple words grows the
        // selection in both directions. Compare absolute rows directly — the
        // ordering is preserved by the linear shift.
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
    ///
    /// - Parameter topScrollInvariantRow: Unused for the snap itself (line
    ///   mode is row-only) but accepted for symmetry with `snapToWord` /
    ///   `copyToPasteboard`. Defaults to `0`.
    public func snapToLine(cols: Int, topScrollInvariantRow: Int = 0) {
        _ = topScrollInvariantRow  // accepted for API symmetry; line mode ignores it.
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
    ///
    /// - Parameter topScrollInvariantRow: The absolute row id sitting at
    ///   `snapshot[0]`. The selection is temporarily projected into snapshot
    ///   coordinates so `SelectionTextExtractor` can read the right cells.
    ///   Defaults to `0` for tests that build a viewport-aligned snapshot
    ///   directly.
    @discardableResult
    public func copyToPasteboard(
        snapshot: ScreenBufferSnapshot,
        cols: Int,
        topScrollInvariantRow: Int = 0
    ) -> Bool {
        guard let selection = current, !selection.isEmpty else { return false }
        let top = topScrollInvariantRow
        let snapshotSelection = Selection(
            anchor: GridPoint(row: selection.anchor.row - top, col: selection.anchor.col),
            head: GridPoint(row: selection.head.row - top, col: selection.head.col),
            mode: selection.mode
        )
        let text = SelectionTextExtractor.extract(
            from: snapshot, selection: snapshotSelection, cols: cols)
        // `.line` mode always appends a trailing newline. Treat a newline-only
        // string as empty for the purpose of "did we copy anything useful".
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    // MARK: - Viewport projection

    /// Projects the current selection from absolute (scroll-invariant) row ids
    /// into viewport-relative segments suitable for the renderer overlay.
    ///
    /// - Parameters:
    ///   - topScrollInvariantRow: Absolute row id at `viewportRow == 0`
    ///     (i.e. the top of the visible area), already adjusted for any
    ///     user-initiated scrollback offset. Get this from
    ///     `SwiftTermAdapter.createSnapshotWithAnchor(scrollbackOffset:)` so
    ///     the snapshot the renderer paints against and the projection share
    ///     the same anchor.
    ///   - viewportRows: Number of visible rows.
    ///   - cols: Number of visible columns.
    /// - Returns: Per-row segments clipped to `[0, viewportRows)`. Returns an
    ///   empty array when there is no live selection or when the selection
    ///   lies entirely outside the viewport.
    public func projectToViewport(
        topScrollInvariantRow: Int,
        viewportRows: Int,
        cols: Int
    ) -> [(viewportRow: Int, cols: ClosedRange<Int>)] {
        guard let selection = current, !selection.isEmpty, viewportRows > 0 else { return [] }
        let top = topScrollInvariantRow
        let viewportSelection = Selection(
            anchor: GridPoint(row: selection.anchor.row - top, col: selection.anchor.col),
            head: GridPoint(row: selection.head.row - top, col: selection.head.col),
            mode: selection.mode
        )
        let segments = SelectionGeometry.expand(viewportSelection, cols: cols)
        return segments.compactMap { seg in
            guard seg.row >= 0, seg.row < viewportRows else { return nil }
            return (viewportRow: seg.row, cols: seg.cols)
        }
    }
}
