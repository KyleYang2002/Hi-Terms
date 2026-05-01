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

    // MARK: - IME

    private var _markedText: String?

    // MARK: - Scrollback

    private var scrollbackOffset: Int = 0

    // MARK: - Resize

    /// Last grid dimensions pushed to the pipeline. Used to dedupe setFrameSize
    /// calls during live resize: only crossing an integer row/col boundary
    /// triggers a real PTY resize.
    private var lastGridSize: (cols: Int, rows: Int) = (0, 0)

    // MARK: - Tracking

    /// The tracking area that lets AppKit deliver `mouseMoved` (no button held)
    /// to this view. Required for `mouseMode == .anyEvent`. Reinstalled by
    /// `updateTrackingAreas()` whenever the view's bounds change.
    private var mouseTrackingArea: NSTrackingArea?

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
        syncBackingScale()
    }

    /// Mirrors the host window's `backingScaleFactor` onto the root layer so the
    /// renderer can derive a matching bitmap density. Called on init, when the
    /// view attaches to a window, and on `viewDidChangeBackingProperties` (e.g.
    /// after dragging the window between Retina and non-Retina displays).
    private func syncBackingScale() {
        guard let rootLayer = layer else { return }
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        if rootLayer.contentsScale != scale {
            rootLayer.contentsScale = scale
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncBackingScale()
        markAllRowsDirty()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncBackingScale()
        // Force a full redraw so the bitmap context gets rebuilt at the new
        // pixel density on the next display-link tick.
        markAllRowsDirty()
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
        let flags = event.modifierFlags

        // Cmd combinations: handle paste, ignore the rest (reserved for app shortcuts)
        if flags.contains(.command) {
            if let chars = event.charactersIgnoringModifiers, chars == "v" {
                paste(nil)
            }
            return
        }

        // Ctrl combinations bypass IME — send directly to PTY
        if flags.contains(.control) {
            if let data = inputHandler.handleKeyDown(event) {
                session?.write(data: data)
                snapToBottomIfScrolled()
            }
            return
        }

        // Special keys (arrows, function keys, etc.) bypass IME
        if let data = inputHandler.specialKeyData(for: event.keyCode) {
            session?.write(data: data)
            snapToBottomIfScrolled()
            return
        }

        // Normal character input: route through input method system
        // This calls insertText(_:replacementRange:) via NSTextInputClient
        interpretKeyEvents([event])
    }

    public override func flagsChanged(with event: NSEvent) {
        inputHandler.updateModifiers(event.modifierFlags)
    }

    // MARK: - Paste

    @objc public func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        applyPaste(string)
    }

    /// Sends the given string to the session, wrapping with bracketed-paste
    /// markers if the terminal has enabled bracketed paste mode.
    /// Internal so tests can drive paste without touching the system pasteboard.
    func applyPaste(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }

        if pipeline.adapter.terminal.bracketedPasteMode {
            let prefix = Data("\u{1B}[200~".utf8)
            let suffix = Data("\u{1B}[201~".utf8)
            session?.write(data: prefix + data + suffix)
        } else {
            session?.write(data: data)
        }

        snapToBottomIfScrolled()
    }

    @objc public override func doCommand(by selector: Selector) {
        // Safety net for keys not caught by specialKeyData (e.g., numpad Enter)
        if selector == #selector(insertNewline(_:)) || selector == #selector(insertNewlineIgnoringFieldEditor(_:)) {
            session?.write(data: Data([0x0D]))
        } else if selector == #selector(insertTab(_:)) {
            session?.write(data: Data([0x09]))
        } else if selector == #selector(deleteBackward(_:)) {
            session?.write(data: Data([0x7F]))
        } else if selector == #selector(cancelOperation(_:)) {
            session?.write(data: Data([0x1B]))
        }
    }

    // MARK: - Mouse Events
    //
    // Mouse reporting is gated by SwiftTerm's `mouseMode`:
    //   - .off  — nothing is reported (a normal shell prompt sees no input).
    //   - .x10  — press only; release/drag/move suppressed.
    //   - .vt200 — press + release.
    //   - .buttonEventTracking — press + release + drag (motion-while-pressed).
    //   - .anyEvent — press + release + drag + move (motion regardless of button).
    //
    // Without this gating, every click in a non-mouse-aware shell gets echoed
    // back as garbled SGR parameters (see refs/22.png).

    public override func mouseDown(with event: NSEvent) {
        guard shouldReportPress() else { return }
        sendMouse(event: event, type: .press)
    }

    public override func mouseUp(with event: NSEvent) {
        guard shouldReportRelease() else { return }
        sendMouse(event: event, type: .release)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard shouldReportDrag() else { return }
        sendMouse(event: event, type: .drag)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard shouldReportMove() else { return }
        sendMouse(event: event, type: .move)
    }

    private func sendMouse(event: NSEvent, type: MouseEventType) {
        let (col, row) = terminalCoordinate(for: event)
        guard let data = inputHandler.handleMouseEvent(event, type: type, col: col, row: row) else {
            return
        }
        session?.write(data: data)
    }

    private func currentMouseMode() -> MouseReportingMode {
        pipeline.adapter.mouseReportingMode
    }

    private func shouldReportPress() -> Bool {
        switch currentMouseMode() {
        case .off: return false
        case .x10, .vt200, .buttonEventTracking, .anyEvent: return true
        }
    }

    private func shouldReportRelease() -> Bool {
        switch currentMouseMode() {
        // x10 is press-only by definition; suppress release to avoid leaking
        // bytes that the host wasn't expecting.
        case .off, .x10: return false
        case .vt200, .buttonEventTracking, .anyEvent: return true
        }
    }

    private func shouldReportDrag() -> Bool {
        switch currentMouseMode() {
        case .buttonEventTracking, .anyEvent: return true
        case .off, .x10, .vt200: return false
        }
    }

    private func shouldReportMove() -> Bool {
        currentMouseMode() == .anyEvent
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
    /// Both axes subtract the content inset so the grid origin lines up with
    /// the visible text origin.
    public func terminalCoordinate(for event: NSEvent) -> (col: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let inset = TerminalLayout.contentInset
        let localX = point.x - inset.width
        let localY = (bounds.height - point.y) - inset.height
        let col = max(0, Int(localX / fontMetrics.cellWidth))
        let row = max(0, Int(localY / fontMetrics.cellHeight))
        return (col: col, row: row)
    }

    // MARK: - Resize

    /// Computes the grid dimensions (cols, rows) that fit the given view frame
    /// size. The view frame includes a `TerminalLayout.contentInset` margin on
    /// each side, which is subtracted before dividing by the cell metrics.
    public static func gridSize(for size: NSSize, fontMetrics: FontMetrics) -> (cols: Int, rows: Int) {
        let inset = TerminalLayout.contentInset
        let usableWidth = max(0, size.width - 2 * inset.width)
        let usableHeight = max(0, size.height - 2 * inset.height)
        let cols = max(1, Int(usableWidth / fontMetrics.cellWidth))
        let rows = max(1, Int(usableHeight / fontMetrics.cellHeight))
        return (cols: cols, rows: rows)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyResize(for: newSize)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseTrackingArea {
            removeTrackingArea(existing)
            mouseTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    /// Computes the new grid dimensions and forwards them to the pipeline.
    /// Called from setFrameSize on every frame change, but dedupes on
    /// (cols, rows) so PTY/SwiftTerm only see actual grid changes.
    /// Made internal to allow direct testing without an NSWindow.
    func applyResize(for size: NSSize) {
        let (cols, rows) = Self.gridSize(for: size, fontMetrics: fontMetrics)
        guard (cols, rows) != lastGridSize else { return }
        lastGridSize = (cols, rows)

        pipeline.resize(cols: cols, rows: rows)

        // After resize, the entire grid may need to repaint.
        markAllRowsDirty()
    }

    // MARK: - Private

    private func snapToBottomIfScrolled() {
        if scrollbackOffset > 0 {
            scrollbackOffset = 0
            pipeline.scrollbackOffset = 0
            markAllRowsDirty()
        }
    }

    /// Marks all rows dirty to trigger a full redraw (used for scrollback changes
    /// and after resize). Reads the actual row count from the live adapter snapshot
    /// so the value stays correct after grid resizes.
    private func markAllRowsDirty() {
        let snapshot = pipeline.adapter.createSnapshot(scrollbackOffset: scrollbackOffset)
        pipeline.dirtyRegion.merge(rows: 0..<snapshot.rows)
        pipeline.renderCoordinator.submitSnapshot(snapshot)
    }

    deinit {
        pipeline.renderCoordinator.stopDisplayLink()
    }
}

// MARK: - NSTextInputClient

extension TerminalView: NSTextInputClient {

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let s = string as? NSAttributedString {
            text = s.string
        } else {
            return
        }
        guard let data = text.data(using: .utf8) else { return }
        session?.write(data: data)
        snapToBottomIfScrolled()
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? String {
            _markedText = s
        } else if let s = string as? NSAttributedString {
            _markedText = s.string
        }
    }

    public func unmarkText() {
        _markedText = nil
    }

    public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    public func markedRange() -> NSRange {
        if let text = _markedText, !text.isEmpty {
            return NSRange(location: 0, length: text.utf16.count)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool {
        _markedText != nil && !(_markedText?.isEmpty ?? true)
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let snapshot = pipeline.adapter.createSnapshot(scrollbackOffset: scrollbackOffset)
        let cursorCol = snapshot.cursor.col
        let cursorRow = snapshot.cursor.row

        let inset = TerminalLayout.contentInset
        let x = inset.width + CGFloat(cursorCol) * fontMetrics.cellWidth
        let yInView = bounds.height - inset.height - CGFloat(cursorRow + 1) * fontMetrics.cellHeight
        let pointInView = NSPoint(x: x, y: yInView)
        let pointInWindow = convert(pointInView, to: nil)
        let pointOnScreen = window?.convertPoint(toScreen: pointInWindow) ?? .zero

        return NSRect(x: pointOnScreen.x, y: pointOnScreen.y,
                      width: fontMetrics.cellWidth, height: fontMetrics.cellHeight)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }
}
