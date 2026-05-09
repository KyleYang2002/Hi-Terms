import AppKit
import QuartzCore
import TerminalCore

/// Visual selection overlay for the renderer.
///
/// Wave 2-A: the overlay is already projected to the *current viewport*. Each
/// segment gives a 0-based viewport row and a closed range of columns to paint.
/// Multi-line selections are pre-expanded by the UI layer
/// (`SelectionGeometry.expand`); the renderer only needs to draw rectangles.
///
/// The overlay is rendered as a translucent CALayer above the text bitmap and
/// does NOT contribute to `DirtyRegion` — it lives outside the bitmap pipeline
/// so a stale text image plus a fresh selection paints correctly.
public struct SelectionOverlay: Equatable, Sendable {
    /// Per-row column ranges, already projected to the current viewport.
    /// `viewportRow` is 0-based with row 0 at the top of the visible area.
    public let segments: [Segment]

    public struct Segment: Equatable, Sendable {
        public let viewportRow: Int
        public let cols: ClosedRange<Int>

        public init(viewportRow: Int, cols: ClosedRange<Int>) {
            self.viewportRow = viewportRow
            self.cols = cols
        }
    }

    public init(segments: [Segment]) {
        self.segments = segments
    }

    public var isEmpty: Bool { segments.isEmpty }
}

/// Protocol for terminal rendering backends.
///
/// V0.0 provides only the protocol definition. V0.1 added CoreTextRenderer.
/// V0.2 added selection overlay support (defaulted nil for back-compat).
/// Future versions may add a Metal-based renderer.
public protocol TerminalRendering: AnyObject {
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        selection: SelectionOverlay?,
        into layer: CALayer
    )

    func measure(font: NSFont) -> FontMetrics
}

public extension TerminalRendering {
    /// Back-compat shim for callers that don't pass a selection overlay.
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        into layer: CALayer
    ) {
        render(buffer: buffer, dirtyRegion: dirtyRegion, cursor: cursor, selection: nil, into: layer)
    }
}
