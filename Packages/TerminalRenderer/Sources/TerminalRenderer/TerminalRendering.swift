import AppKit
import QuartzCore
import TerminalCore

/// Protocol for terminal rendering backends.
///
/// V0.0 provides only the protocol definition. V0.1 will add CoreTextRenderer.
/// Future versions may add a Metal-based renderer.
public protocol TerminalRendering {
    func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        into layer: CALayer
    )

    func measure(font: NSFont) -> FontMetrics
}
