import AppKit
import QuartzCore
import os
import TerminalCore

/// Coordinates background buffer updates with main-thread rendering via CADisplayLink.
///
/// The PTY I/O thread calls `submitSnapshot(_:)` to provide new buffer state.
/// A CADisplayLink callback on the main thread picks up the latest snapshot and
/// triggers the renderer. This ensures rendering is capped at display refresh rate
/// and multiple buffer updates between frames are coalesced automatically.
///
/// V0.2 also tracks an optional `SelectionOverlay`. The UI layer pushes new
/// overlays via `updateSelection(_:)`; the next display-link tick forwards the
/// latest value to the renderer alongside the buffer snapshot. The overlay is
/// independent of the dirty-region pipeline, so changes to the selection alone
/// (without buffer mutation) are still applied, because every tick re-supplies
/// the current overlay to the renderer.
public final class RenderCoordinator: NSObject, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var latestSnapshot: ScreenBufferSnapshot?
    private var pendingSelection: SelectionOverlay?
    private var pendingShellMarkers: ShellMarkerOverlay?
    private var pendingHoverURL: String?
    private var pendingBareTextHover: BareTextHoverSpan?
    private var displayLink: CADisplayLink?
    private let dirtyRegion: DirtyRegion

    public weak var renderer: (any TerminalRendering)?
    public weak var targetLayer: CALayer?

    public init(dirtyRegion: DirtyRegion) {
        self.dirtyRegion = dirtyRegion
        super.init()
    }

    /// Submits a new buffer snapshot from the PTY I/O thread.
    public func submitSnapshot(_ snapshot: ScreenBufferSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        latestSnapshot = snapshot
    }

    /// Replaces the current selection overlay. Pass `nil` to clear.
    /// Safe to call from any thread; rendering happens on the next display tick.
    public func updateSelection(_ overlay: SelectionOverlay?) {
        lock.lock()
        defer { lock.unlock() }
        pendingSelection = overlay
    }

    /// Replaces the current shell-marker overlay. Pass `nil` (or an empty
    /// overlay) to clear all command-boundary decoration. Safe to call from
    /// any thread; the overlay lives in its own CALayer so changes apply on
    /// the next display tick without going through `DirtyRegion`.
    public func updateShellMarkers(_ overlay: ShellMarkerOverlay?) {
        lock.lock()
        defer { lock.unlock() }
        pendingShellMarkers = overlay
    }

    /// Updates the hovered OSC 8 hyperlink URL. Called from the main thread on
    /// `mouseMoved` / `mouseExited`. Only marks rows dirty when the URL actually
    /// changes — bouncing the cursor across cells with the same URL is a no-op.
    /// All rows that contain the *old* or *new* URL are scheduled for repaint
    /// so the underline appears or disappears in the next frame.
    public func updateHover(_ url: String?) {
        lock.lock()
        let previous = pendingHoverURL
        guard previous != url else {
            lock.unlock()
            return
        }
        pendingHoverURL = url
        let snapshot = latestSnapshot
        lock.unlock()
        guard let snapshot else { return }
        markRowsDirty(in: snapshot, matchingURLs: [previous, url])
    }

    /// Returns the current pending hover URL. Public so tests in downstream
    /// packages (TerminalUI) can verify hover propagation without
    /// `@testable import` (cross-package testable is brittle in SPM).
    public func currentHoverURL() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pendingHoverURL
    }

    /// Updates the bare-text hover span. Mirrors `updateHover(_:)` but for the
    /// regex-based path detector — span carries `(row, cols)` directly so the
    /// renderer doesn't need per-cell metadata. Marks the affected row(s) dirty
    /// so the underline appears or disappears on the next frame.
    public func updateBareTextHover(_ span: BareTextHoverSpan?) {
        lock.lock()
        let previous = pendingBareTextHover
        guard previous != span else {
            lock.unlock()
            return
        }
        pendingBareTextHover = span
        lock.unlock()
        var dirty = IndexSet()
        if let previous { dirty.insert(previous.viewportRow) }
        if let span { dirty.insert(span.viewportRow) }
        if !dirty.isEmpty {
            dirtyRegion.merge(dirty)
        }
    }

    /// Cross-package test visibility companion to `currentHoverURL`.
    public func currentBareTextHover() -> BareTextHoverSpan? {
        lock.lock()
        defer { lock.unlock() }
        return pendingBareTextHover
    }

    /// Returns the current pending shell-marker overlay. Public for the same
    /// cross-package test-visibility reason as `currentHoverURL()`.
    public func currentShellMarkers() -> ShellMarkerOverlay? {
        lock.lock()
        defer { lock.unlock() }
        return pendingShellMarkers
    }

    /// Scans the snapshot once and marks every row that holds at least one cell
    /// whose `hyperlinkURL` is in `urls` (nil entries are ignored). O(rows×cols)
    /// over a typical 25×200 grid — sub-100µs on hover transitions.
    private func markRowsDirty(in snapshot: ScreenBufferSnapshot, matchingURLs urls: [String?]) {
        let targets = Set(urls.compactMap { $0 })
        guard !targets.isEmpty else { return }
        var dirty = IndexSet()
        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols {
                if let u = snapshot[row, col].hyperlinkURL, targets.contains(u) {
                    dirty.insert(row)
                    break
                }
            }
        }
        if !dirty.isEmpty {
            dirtyRegion.merge(dirty)
        }
    }

    /// Starts the CADisplayLink render loop on the main RunLoop.
    public func startDisplayLink() {
        guard displayLink == nil else { return }
        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    /// Stops the CADisplayLink render loop.
    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// CADisplayLink callback — runs on main thread at display refresh rate.
    @objc private func onDisplayLink(_ displayLink: CADisplayLink) {
        lock.lock()
        let snapshot = latestSnapshot
        let selection = pendingSelection
        let markers = pendingShellMarkers
        let hover = pendingHoverURL
        let bareHover = pendingBareTextHover
        lock.unlock()

        guard let snapshot, let renderer, let targetLayer else { return }

        renderer.render(
            buffer: snapshot,
            dirtyRegion: dirtyRegion,
            cursor: snapshot.cursor,
            selection: selection,
            shellMarkers: markers,
            hoveredHyperlinkURL: hover,
            bareTextHover: bareHover,
            into: targetLayer
        )
    }
}
