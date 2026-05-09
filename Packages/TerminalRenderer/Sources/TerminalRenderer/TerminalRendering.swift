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

/// Visual decoration for OSC 133 command boundaries.
///
/// One `RowMark` per viewport row that is part of a `CommandBand`. The renderer
/// draws:
///   * a 3-pixel gutter bar at `x=0` coloured by `status` (success green,
///     failure red, running blue/grey);
///   * a 1-pixel hairline at the top of the row when `isPromptTop` is true,
///     visually splitting consecutive commands;
///   * a `✗ exit=N` badge at the end of the row when `failureBadgeExitCode`
///     is non-nil (typically the failed command's last output row).
///
/// The overlay lives in its own CALayer (parallel to `SelectionOverlay`), so
/// it is independent of the text bitmap's dirty-region pipeline. The publisher
/// rebuilds it whenever `ShellIntegrationState` fires, the viewport scrolls,
/// or the alt screen flips.
public struct ShellMarkerOverlay: Equatable, Sendable {
    public enum BandStatus: Equatable, Sendable {
        case running
        case success
        case failure(exitCode: Int32)
    }

    public struct RowMark: Equatable, Sendable {
        public let viewportRow: Int
        public let status: BandStatus
        public let isPromptTop: Bool
        public let failureBadgeExitCode: Int32?

        public init(
            viewportRow: Int,
            status: BandStatus,
            isPromptTop: Bool = false,
            failureBadgeExitCode: Int32? = nil
        ) {
            self.viewportRow = viewportRow
            self.status = status
            self.isPromptTop = isPromptTop
            self.failureBadgeExitCode = failureBadgeExitCode
        }
    }

    public let rows: [RowMark]

    public init(rows: [RowMark]) { self.rows = rows }

    public var isEmpty: Bool { rows.isEmpty }
}

/// Hover decoration for a bare-text path range — a contiguous span of cells in
/// a single viewport row that the UI layer has identified as a clickable file
/// path via regex + cwd validation. Unlike OSC 8 hover (which is keyed off a
/// per-cell `hyperlinkURL` field), bare-text hover is purely a `(row, cols)`
/// rectangle so the renderer can paint the underline without scanning cell
/// metadata.
public struct BareTextHoverSpan: Equatable, Sendable {
    public let viewportRow: Int
    public let cols: ClosedRange<Int>

    public init(viewportRow: Int, cols: ClosedRange<Int>) {
        self.viewportRow = viewportRow
        self.cols = cols
    }
}

/// Protocol for terminal rendering backends.
///
/// V0.0 provides only the protocol definition. V0.1 added CoreTextRenderer.
/// V0.2 added selection overlay support (defaulted nil for back-compat),
/// then OSC 8 hover (`hoveredHyperlinkURL`) for ⌘+click hyperlinks, then
/// OSC 133 command-boundary decoration (`shellMarkers`), and finally a
/// `bareTextHover` channel for the regex-based path detector.
/// Future versions may add a Metal-based renderer.
public protocol TerminalRendering: AnyObject {
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        selection: SelectionOverlay?,
        shellMarkers: ShellMarkerOverlay?,
        hoveredHyperlinkURL: String?,
        bareTextHover: BareTextHoverSpan?,
        into layer: CALayer
    )

    func measure(font: NSFont) -> FontMetrics
}

public extension TerminalRendering {
    /// Back-compat shim for callers that don't pass any overlays.
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        into layer: CALayer
    ) {
        render(buffer: buffer, dirtyRegion: dirtyRegion, cursor: cursor,
               selection: nil, shellMarkers: nil, hoveredHyperlinkURL: nil,
               bareTextHover: nil, into: layer)
    }

    /// Back-compat shim for callers that pass a selection but no other overlay.
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        selection: SelectionOverlay?,
        into layer: CALayer
    ) {
        render(buffer: buffer, dirtyRegion: dirtyRegion, cursor: cursor,
               selection: selection, shellMarkers: nil, hoveredHyperlinkURL: nil,
               bareTextHover: nil, into: layer)
    }

    /// Back-compat shim for the v0.2-pre-OSC133 5-arg form.
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        selection: SelectionOverlay?,
        hoveredHyperlinkURL: String?,
        into layer: CALayer
    ) {
        render(buffer: buffer, dirtyRegion: dirtyRegion, cursor: cursor,
               selection: selection, shellMarkers: nil,
               hoveredHyperlinkURL: hoveredHyperlinkURL,
               bareTextHover: nil, into: layer)
    }

    /// Back-compat shim for the v0.2-pre-bareText 7-arg form.
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        selection: SelectionOverlay?,
        shellMarkers: ShellMarkerOverlay?,
        hoveredHyperlinkURL: String?,
        into layer: CALayer
    ) {
        render(buffer: buffer, dirtyRegion: dirtyRegion, cursor: cursor,
               selection: selection, shellMarkers: shellMarkers,
               hoveredHyperlinkURL: hoveredHyperlinkURL,
               bareTextHover: nil, into: layer)
    }
}
