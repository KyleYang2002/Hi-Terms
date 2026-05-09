import XCTest
import TerminalCore
@testable import TerminalUI

/// Microbenchmark for `BareTextPathDetector.match` — the function called from
/// `mouseMoved` on every pixel-level cursor move. The cache-hit path runs O(1)
/// after a hash compare; the cache-miss path runs the regex + cwd check + a
/// real `stat(2)` syscall, so the gap can be 100×.
///
/// What we publish: p50 / p99 / max for four scenarios on a typical 200-col
/// row, computed over 1000 samples (first 50 discarded as warmup). Numbers
/// are recorded in `Next2Do/risks-and-decisions.md`. The XCTAssertGreater check
/// is permissive — it exists to make sure the benchmark body actually runs;
/// we don't gate CI on a specific microsecond budget because Debug-build
/// numbers are noisy and CI runners vary.
///
/// Build mode caveat: `swift test` defaults to Debug. Release-mode numbers are
/// 3-8× faster on this kind of code. The numbers stamped into the risks doc
/// are Debug-build figures so they're directly reproducible from `swift test`
/// without configuration tweaks.
final class BareTextPathDetectorPerfTests: XCTestCase {
    private var tmpCwd: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpCwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("hi-terms-baretext-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpCwd, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpCwd { try? FileManager.default.removeItem(at: tmpCwd) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Builds a 200-cell row with `text` placed starting at `startCol`, padded
    /// out with spaces. char-to-col mapping is identity (ASCII-only).
    private func makeRow(_ text: String, startCol: Int = 24, cols: Int = 200) -> RowText {
        let prefix = String(repeating: "x", count: startCol)
        let visible = prefix + text
        let padded: String
        if visible.count >= cols {
            padded = String(visible.prefix(cols))
        } else {
            padded = visible + String(repeating: " ", count: cols - visible.count)
        }
        let charCols = Array(0..<cols)
        return RowText(text: padded, cols: cols, charCols: charCols)
    }

    private func touch(_ relative: String) throws -> URL {
        let url = tmpCwd.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    private func percentile(_ samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let idx = min(samples.count - 1, max(0, Int(Double(samples.count) * p)))
        return samples[idx]
    }

    private func report(name: String, samples: [Double]) {
        var sorted = samples
        sorted.sort()
        let p50 = String(format: "%.2f", percentile(sorted, 0.5))
        let p99 = String(format: "%.2f", percentile(sorted, 0.99))
        let mx = String(format: "%.2f", sorted.last ?? 0)
        let line = "[bench] \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) n=\(sorted.count)  p50=\(p50)µs  p99=\(p99)µs  max=\(mx)µs"
        // stderr survives XCTest's stdout buffering more reliably than print().
        fputs(line + "\n", stderr)
    }

    // MARK: - Tests

    func testCacheHitOnPathRow() throws {
        _ = try touch("src/Greeter.swift")
        let detector = BareTextPathDetector()
        let row = makeRow("src/Greeter.swift:42:7")
        // Warm cache.
        _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)

        var samples: [Double] = []
        samples.reserveCapacity(1000)
        for _ in 0..<50 {
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
        }
        for _ in 0..<1000 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(Double(elapsed) / 1_000.0)
        }
        report(name: "cache-hit-on-path", samples: samples)
        XCTAssertGreaterThan(samples.count, 0)
    }

    func testCacheMissOnPathRow() throws {
        _ = try touch("src/Greeter.swift")
        let detector = BareTextPathDetector()
        let row = makeRow("src/Greeter.swift:42:7")

        var samples: [Double] = []
        samples.reserveCapacity(1000)
        for _ in 0..<50 {
            detector.clearCache()
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
        }
        for _ in 0..<1000 {
            detector.clearCache()
            let start = DispatchTime.now().uptimeNanoseconds
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(Double(elapsed) / 1_000.0)
        }
        report(name: "cache-miss-on-path", samples: samples)
        XCTAssertGreaterThan(samples.count, 0)
    }

    func testCacheHitOnNoPathRow() throws {
        let detector = BareTextPathDetector()
        let row = makeRow("the quick brown fox jumps over the lazy dog repeatedly")
        _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)

        var samples: [Double] = []
        samples.reserveCapacity(1000)
        for _ in 0..<50 {
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
        }
        for _ in 0..<1000 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(Double(elapsed) / 1_000.0)
        }
        report(name: "cache-hit-no-path", samples: samples)
        XCTAssertGreaterThan(samples.count, 0)
    }

    func testCacheMissOnNoPathRow() throws {
        let detector = BareTextPathDetector()
        let row = makeRow("the quick brown fox jumps over the lazy dog repeatedly")

        var samples: [Double] = []
        samples.reserveCapacity(1000)
        for _ in 0..<50 {
            detector.clearCache()
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
        }
        for _ in 0..<1000 {
            detector.clearCache()
            let start = DispatchTime.now().uptimeNanoseconds
            _ = detector.match(rowText: row, cwd: tmpCwd, atCol: 30)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(Double(elapsed) / 1_000.0)
        }
        report(name: "cache-miss-no-path", samples: samples)
        XCTAssertGreaterThan(samples.count, 0)
    }
}
