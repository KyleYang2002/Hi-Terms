import Foundation
import os

/// Thread-safe dirty region tracker for terminal rendering.
///
/// Collects row indices that need redrawing. Parser thread calls `merge()`,
/// renderer thread calls `swapAndClear()` on the CADisplayLink callback.
/// Protected by `os_unfair_lock` for minimal overhead.
public final class DirtyRegion: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var dirtyRows = IndexSet()

    public init() {}

    public var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return dirtyRows.isEmpty
    }

    /// Merges additional dirty rows. Called from the PTY I/O thread.
    public func merge(_ rows: IndexSet) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        dirtyRows.formUnion(rows)
    }

    /// Merges a single row.
    public func merge(row: Int) {
        merge(IndexSet(integer: row))
    }

    /// Merges a range of rows.
    public func merge(rows range: Range<Int>) {
        merge(IndexSet(integersIn: range))
    }

    /// Atomically swaps out the dirty region and clears it.
    /// Called from the main thread (CADisplayLink callback).
    public func swapAndClear() -> IndexSet {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let result = dirtyRows
        dirtyRows = IndexSet()
        return result
    }
}
