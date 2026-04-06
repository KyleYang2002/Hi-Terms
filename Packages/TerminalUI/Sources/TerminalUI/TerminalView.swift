import AppKit
import TerminalCore
import TerminalRenderer

/// Terminal content view: renders terminal output and handles user input.
///
/// Uses CALayer-backed rendering with CoreTextRenderer. Does not directly hold
/// PTYProcess — all PTY access goes through the Session/Pipeline.
public final class TerminalView: NSView {
    // MARK: - Rendering

    private let renderer: CoreTextRenderer
    private let fontMetrics: FontMetrics

    // MARK: - Input

    private let inputHandler = InputHandler()

    // MARK: - Data source

    /// Weak reference to session — WindowController owns the Session.
    private weak var session: (any Session)?

    /// Concrete pipeline for accessing renderCoordinator/dirtyRegion/adapter.
    private let pipeline: DefaultTerminalPipeline

    // MARK: - Scrollback

    private var scrollbackOffset: Int = 0

    // MARK: - Init

    /// Creates a terminal view wired to the given session and pipeline.
    ///
    /// - Parameters:
    ///   - session: The terminal session (weak reference).
    ///   - pipeline: The concrete pipeline (for renderer/coordinator access).
    ///   - frame: The initial frame rect.
    public init(session: any Session, pipeline: DefaultTerminalPipeline, frame: NSRect) {
        self.session = session
        self.pipeline = pipeline

        // Create renderer with configured font
        let font = NSFont(name: "Menlo", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.renderer = CoreTextRenderer(font: font)
        self.fontMetrics = renderer.fontMetrics

        super.init(frame: frame)

        setupLayers()
        setupRenderCoordinator()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layer Setup

    private func setupLayers() {
        wantsLayer = true
        guard let rootLayer = layer else { return }
        rootLayer.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    /// Connects the RenderCoordinator to this view's layer and starts the display link.
    private func setupRenderCoordinator() {
        let coordinator = pipeline.renderCoordinator
        coordinator.renderer = renderer
        coordinator.targetLayer = layer
        coordinator.startDisplayLink()
    }

    // MARK: - First Responder

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Keyboard Events

    public override func keyDown(with event: NSEvent) {
        guard let data = inputHandler.handleKeyDown(event) else { return }
        session?.write(data: data)

        // If user types while scrolled back, snap to bottom
        if scrollbackOffset > 0 {
            scrollbackOffset = 0
            pipeline.scrollbackOffset = 0
            markAllRowsDirty()
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        inputHandler.updateModifiers(event.modifierFlags)
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        let (col, row) = terminalCoordinate(for: event)
        guard let data = inputHandler.handleMouseEvent(event, type: .press, col: col, row: row) else {
            return
        }
        session?.write(data: data)
    }

    public override func mouseUp(with event: NSEvent) {
        let (col, row) = terminalCoordinate(for: event)
        guard let data = inputHandler.handleMouseEvent(event, type: .release, col: col, row: row) else {
            return
        }
        session?.write(data: data)
    }

    public override func mouseMoved(with event: NSEvent) {
        let (col, row) = terminalCoordinate(for: event)
        guard let data = inputHandler.handleMouseEvent(event, type: .move, col: col, row: row) else {
            return
        }
        session?.write(data: data)
    }

    // MARK: - Scroll

    public override func scrollWheel(with event: NSEvent) {
        let delta = Int(event.scrollingDeltaY)
        scrollbackOffset = max(0, scrollbackOffset + delta)
        pipeline.scrollbackOffset = scrollbackOffset
        markAllRowsDirty()
    }

    // MARK: - Coordinate Conversion

    /// Converts mouse pixel coordinates to terminal grid coordinates.
    /// NSView Y=0 is at bottom; terminal row 0 is at top — must invert Y.
    public func terminalCoordinate(for event: NSEvent) -> (col: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let col = max(0, Int(point.x / fontMetrics.cellWidth))
        // Invert Y: NSView bottom → terminal top
        let row = max(0, Int((bounds.height - point.y) / fontMetrics.cellHeight))
        return (col: col, row: row)
    }

    // MARK: - Private

    /// Marks all rows dirty to trigger a full redraw (used for scrollback changes).
    private func markAllRowsDirty() {
        let rows = pipeline.screenBuffer.rows
        pipeline.dirtyRegion.merge(rows: 0..<rows)
        // Submit a new snapshot with the current scrollback offset
        let snapshot = pipeline.adapter.createSnapshot(scrollbackOffset: scrollbackOffset)
        pipeline.renderCoordinator.submitSnapshot(snapshot)
    }

    deinit {
        pipeline.renderCoordinator.stopDisplayLink()
    }
}
