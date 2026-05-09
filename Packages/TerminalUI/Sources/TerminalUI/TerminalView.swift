import AppKit
import TerminalCore
import TerminalRenderer

/// Terminal content view: renders terminal output and handles user input.
///
/// Uses CALayer-backed rendering with CoreTextRenderer. Does not directly hold
/// PTYProcess — all PTY access goes through the Session/Pipeline.
public final class TerminalView: NSView, NSUserInterfaceValidations {
    // MARK: - Rendering

    private let renderer: CoreTextRenderer
    private let fontMetrics: FontMetrics

    // MARK: - Input

    private let inputHandler = InputHandler()

    // MARK: - Selection

    /// Owns the live mouse-drag selection. Public so WindowController/menus
    /// can drive copy without touching internals.
    public let selectionController = SelectionController()

    // MARK: - Bell overlay

    /// Top-most CALayer used by `flashBell()` for the visual BEL effect.
    /// Created lazily in `setupLayers`; sized to match `bounds` on resize.
    private var bellOverlayLayer: CALayer?

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

        // Top-level overlay used by flashBell. Transparent at rest; the flash
        // animates `opacity` between 0 and a small positive value. zPosition
        // keeps it above the text + selection layers regardless of insertion
        // order.
        let bell = CALayer()
        bell.name = "hi-terms-bell"
        bell.backgroundColor = NSColor.white.cgColor
        bell.opacity = 0
        bell.frame = bounds
        bell.zPosition = 100
        rootLayer.addSublayer(bell)
        bellOverlayLayer = bell
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

        // Wave 2-C: keep the on-screen selection overlay anchored to the
        // buffer rows the user picked, even when bytes from the PTY push
        // `yDisp` forward or a TUI flips into the alt buffer. The pipeline
        // dispatches both hooks to main, so they are safe to touch
        // SelectionController state directly.
        pipeline.onYDispChanged = { [weak self] _ in
            self?.publishSelectionOverlay()
        }
        pipeline.onAlternateBufferChanged = { [weak self] _ in
            // Either edge invalidates the selection — primary-buffer rows
            // and alt-buffer rows live in disjoint id spaces. Drop the
            // selection rather than try to remap.
            guard let self else { return }
            self.selectionController.clear()
            self.publishSelectionOverlay()
        }
    }

    // MARK: - First Responder

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Keyboard Events

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags

        // Cmd combinations: forward to the responder chain so the menu
        // (Edit > Copy / Paste / Select All) handles them. The menu items
        // installed by AppDelegate fire `paste:`, `copy:`, `selectAll:`
        // selectors back on us.
        if flags.contains(.command) {
            super.keyDown(with: event)
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

    // MARK: - Copy + Select All (menu first responders)

    /// Standard `copy:` selector. Pulls the latest snapshot and asks the
    /// `SelectionController` to write the extracted text to the general
    /// pasteboard. Returns silently if nothing is selected.
    ///
    /// Uses `createSnapshotWithAnchor` so the snapshot and the absolute row
    /// id used to project the selection are read atomically — otherwise a
    /// PTY write that bumps `yDisp` between the two reads could leave the
    /// extractor reading the wrong rows.
    @objc public func copy(_ sender: Any?) {
        let (snapshot, topAbs, _) = pipeline.adapter.createSnapshotWithAnchor(
            scrollbackOffset: scrollbackOffset)
        _ = selectionController.copyToPasteboard(
            snapshot: snapshot,
            cols: snapshot.cols,
            topScrollInvariantRow: topAbs)
    }

    /// Validates Edit menu items so Copy is greyed out when there's no
    /// selection, matching macOS conventions. Conforms to
    /// `NSUserInterfaceValidations` (NSView itself does not implement it).
    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectionController.current?.isEmpty == false
        }
        return true
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
    // Two routing paths share these handlers:
    //
    //   1. SGR mouse reporting — when SwiftTerm's `mouseMode != .off` and the
    //      user is NOT holding Option. The legacy press/drag/release/move
    //      gating from V0.1 still applies; this is the path TUI apps depend
    //      on (vim, htop, codex selection menus, …).
    //
    //   2. Local selection — when `mouseMode == .off`, OR the user holds
    //      Option to override SGR. Builds a `Selection` via the
    //      `SelectionController`; rendered via the renderer's overlay.
    //
    // The two paths are mutually exclusive: a single mouseDown either
    // contributes bytes to the PTY (path 1) or builds a local selection
    // (path 2), never both.

    public override func mouseDown(with event: NSEvent) {
        if shouldUseSelection(for: event) {
            handleSelectionMouseDown(event)
            return
        }
        guard shouldReportPress() else { return }
        sendMouse(event: event, type: .press)
    }

    public override func mouseUp(with event: NSEvent) {
        if shouldUseSelection(for: event) {
            handleSelectionMouseUp(event)
            return
        }
        guard shouldReportRelease() else { return }
        sendMouse(event: event, type: .release)
    }

    public override func mouseDragged(with event: NSEvent) {
        if shouldUseSelection(for: event) {
            handleSelectionMouseDragged(event)
            return
        }
        guard shouldReportDrag() else { return }
        sendMouse(event: event, type: .drag)
    }

    public override func mouseMoved(with event: NSEvent) {
        // Move events never participate in selection (no button held).
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

    /// Selection takes the mouse when SwiftTerm is not asking for SGR, or
    /// when the user holds Option to override SGR (matches iTerm/macOS
    /// Terminal convention).
    private func shouldUseSelection(for event: NSEvent) -> Bool {
        if currentMouseMode() == .off { return true }
        return event.modifierFlags.contains(.option)
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

    // MARK: - Selection routing
    //
    // Wave 2-C: selection coordinates are *scroll-invariant absolute* row
    // ids. The conversion mirrors `SwiftTermAdapter.createSnapshotWithAnchor`
    // so the row id that ends up on the selection always matches what
    // `publishSelectionOverlay` will subtract back out:
    //
    //     clamped       = min(max(scrollbackOffset, 0), topScrollInvariantRow)
    //     anchorAbsRow  = topScrollInvariantRow - clamped + viewportRow
    //
    // Reading `topScrollInvariantRow` once per gesture step keeps the anchor
    // stable even if the PTY thread shifts `yDisp` between the down and the
    // first drag.

    /// Mirrors `createSnapshotWithAnchor`'s clamp: scrollback can never go
    /// past the bottom of recorded history.
    private func absoluteRow(forViewportRow viewportRow: Int) -> Int {
        let top = pipeline.adapter.topScrollInvariantRow
        let clamped = max(0, min(scrollbackOffset, top))
        return top - clamped + viewportRow
    }

    private func handleSelectionMouseDown(_ event: NSEvent) {
        let (col, row) = terminalCoordinate(for: event)
        let absRow = absoluteRow(forViewportRow: row)
        let point = GridPoint(row: absRow, col: col)
        selectionController.beginDrag(at: point, clickCount: event.clickCount)

        switch event.clickCount {
        case 2:
            let (snapshot, topAbs, _) = pipeline.adapter.createSnapshotWithAnchor(
                scrollbackOffset: scrollbackOffset)
            selectionController.snapToWord(
                in: snapshot, cols: snapshot.cols, topScrollInvariantRow: topAbs)
        case let n where n >= 3:
            // Line mode does not need the snapshot, but we read cols off it
            // for parity with the previous behaviour.
            let (snapshot, topAbs, _) = pipeline.adapter.createSnapshotWithAnchor(
                scrollbackOffset: scrollbackOffset)
            selectionController.snapToLine(
                cols: snapshot.cols, topScrollInvariantRow: topAbs)
        default: break
        }
        publishSelectionOverlay()
    }

    private func handleSelectionMouseDragged(_ event: NSEvent) {
        let (col, row) = terminalCoordinate(for: event)
        let absRow = absoluteRow(forViewportRow: row)
        let point = GridPoint(row: absRow, col: col)
        selectionController.extendDrag(to: point)
        if selectionController.current?.mode == .word {
            let (snapshot, topAbs, _) = pipeline.adapter.createSnapshotWithAnchor(
                scrollbackOffset: scrollbackOffset)
            selectionController.snapToWord(
                in: snapshot, cols: snapshot.cols, topScrollInvariantRow: topAbs)
        } else if selectionController.current?.mode == .line {
            let (snapshot, topAbs, _) = pipeline.adapter.createSnapshotWithAnchor(
                scrollbackOffset: scrollbackOffset)
            selectionController.snapToLine(
                cols: snapshot.cols, topScrollInvariantRow: topAbs)
        }
        publishSelectionOverlay()
    }

    private func handleSelectionMouseUp(_ event: NSEvent) {
        let (col, row) = terminalCoordinate(for: event)
        let absRow = absoluteRow(forViewportRow: row)
        let point = GridPoint(row: absRow, col: col)
        selectionController.endDrag(at: point)
        publishSelectionOverlay()
    }

    /// Projects the controller's current selection onto the renderer overlay.
    ///
    /// The selection lives in absolute (scroll-invariant) row ids; the overlay
    /// expects viewport-relative segments. We pull a fresh snapshot anchor
    /// (atomically, via `createSnapshotWithAnchor`) and ask
    /// `SelectionController.projectToViewport` to translate + clip.
    ///
    /// Called from:
    ///   * mouse down/dragged/up while a drag is live,
    ///   * scrollWheel / snapToBottomIfScrolled when `scrollbackOffset` shifts,
    ///   * the pipeline's `onYDispChanged` hook when the PTY pushes new lines,
    ///   * the pipeline's `onAlternateBufferChanged` hook (after clearing).
    private func publishSelectionOverlay() {
        let isLive = selectionController.current?.isEmpty == false
        guard isLive else {
            pipeline.renderCoordinator.updateSelection(nil)
            return
        }
        let (snapshot, topAbs, _) = pipeline.adapter.createSnapshotWithAnchor(
            scrollbackOffset: scrollbackOffset)
        let projected = selectionController.projectToViewport(
            topScrollInvariantRow: topAbs,
            viewportRows: snapshot.rows,
            cols: snapshot.cols)
        let segments = projected.map {
            SelectionOverlay.Segment(viewportRow: $0.viewportRow, cols: $0.cols)
        }
        pipeline.renderCoordinator.updateSelection(SelectionOverlay(segments: segments))
    }

    // MARK: - Bell overlay

    /// Plays a brief opacity pulse on `bellOverlayLayer`. Honors macOS
    /// Reduce Motion by switching to a single, gentler hold-fade.
    public func flashBell() {
        guard let bellLayer = bellOverlayLayer else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = reduceMotion ? 0.12 : 0.0
        animation.toValue = 0.0
        animation.isRemovedOnCompletion = true

        if reduceMotion {
            animation.duration = 0.08
            bellLayer.add(animation, forKey: "bell-flash")
            return
        }

        // Two-stage curve: 0 → 0.18 (peak) → 0 across 120 ms.
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.0, 0.18, 0.0]
        pulse.keyTimes = [0.0, 0.5, 1.0]
        pulse.duration = 0.12
        pulse.isRemovedOnCompletion = true
        bellLayer.add(pulse, forKey: "bell-flash")
    }

    // MARK: - Scroll

    public override func scrollWheel(with event: NSEvent) {
        let delta = Int(event.scrollingDeltaY)
        let oldOffset = scrollbackOffset
        scrollbackOffset = max(0, scrollbackOffset + delta)
        pipeline.scrollbackOffset = scrollbackOffset
        markAllRowsDirty()
        if scrollbackOffset != oldOffset {
            // Selection rows are scroll-invariant so the data does not change,
            // but the viewport projection that the renderer paints absolutely
            // does — republish so the overlay tracks the new viewport top.
            publishSelectionOverlay()
        }
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
        bellOverlayLayer?.frame = bounds
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

        // Resizing invalidates any in-flight selection (the underlying grid
        // shifts row/col indices) — drop it instead of trying to remap.
        selectionController.clear()
        pipeline.renderCoordinator.updateSelection(nil)

        // After resize, the entire grid may need to repaint.
        markAllRowsDirty()
    }

    // MARK: - Private

    private func snapToBottomIfScrolled() {
        if scrollbackOffset > 0 {
            scrollbackOffset = 0
            pipeline.scrollbackOffset = 0
            markAllRowsDirty()
            // Same reason as scrollWheel: the projection moved.
            publishSelectionOverlay()
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
