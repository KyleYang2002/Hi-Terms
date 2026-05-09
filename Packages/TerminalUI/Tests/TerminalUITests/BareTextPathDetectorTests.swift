import XCTest
import TerminalCore
@testable import TerminalUI

final class BareTextPathDetectorTests: XCTestCase {
    private var tmpCwd: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpCwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("hi-terms-baretext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpCwd, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpCwd { try? FileManager.default.removeItem(at: tmpCwd) }
        try super.tearDownWithError()
    }

    private func touch(_ relative: String) throws -> URL {
        let url = tmpCwd.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    private func rowText(_ s: String) -> RowText {
        // Direct ASCII row — char index == cell column.
        let cols = s.count
        let charCols = (0..<cols).map { $0 }
        return RowText(text: s, cols: cols, charCols: charCols)
    }

    // MARK: - Resolution

    func testRelativePathResolvedAgainstCWDAndStatPasses() throws {
        let target = try touch("Sources/Foo.swift")
        let detector = BareTextPathDetector()
        let hits = detector.allMatches(rowText: rowText("see Sources/Foo.swift"), cwd: tmpCwd)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.absURL.standardizedFileURL.path,
                       target.standardizedFileURL.path)
    }

    func testAbsolutePathInsideCwdMatches() throws {
        let target = try touch("a.txt")
        let detector = BareTextPathDetector()
        let line = "see \(target.path)"
        let hits = detector.allMatches(rowText: rowText(line), cwd: tmpCwd)
        XCTAssertEqual(hits.first?.absURL.standardizedFileURL.path,
                       target.standardizedFileURL.path)
    }

    func testAbsolutePathOutsideCwdRejected() {
        let detector = BareTextPathDetector()
        let hits = detector.allMatches(
            rowText: rowText("see /etc/passwd"), cwd: tmpCwd)
        XCTAssertTrue(hits.isEmpty, "outside-cwd absolute paths must be dropped")
    }

    func testMissingFileRejected() {
        let detector = BareTextPathDetector()
        let hits = detector.allMatches(
            rowText: rowText("see does/not/exist.swift"), cwd: tmpCwd)
        XCTAssertTrue(hits.isEmpty, "non-existent files must be dropped")
    }

    func testNilCwdRejectsRelativePath() {
        let detector = BareTextPathDetector()
        let hits = detector.allMatches(
            rowText: rowText("see foo/bar.swift"), cwd: nil)
        XCTAssertTrue(hits.isEmpty, "without cwd, relative paths can't anchor")
    }

    func testLineColumnPropagated() throws {
        _ = try touch("src/a.swift")
        let detector = BareTextPathDetector()
        let hits = detector.allMatches(
            rowText: rowText("at src/a.swift:42:7"), cwd: tmpCwd)
        XCTAssertEqual(hits.first?.line, 42)
        XCTAssertEqual(hits.first?.column, 7)
    }

    // MARK: - Per-col lookup

    func testMatchAtColReturnsHitWhenColumnInsideRange() throws {
        _ = try touch("a/b.txt")
        let detector = BareTextPathDetector()
        let row = rowText("see a/b.txt now")  // path occupies cols 4..10
        let inside = detector.match(rowText: row, cwd: tmpCwd, atCol: 5)
        XCTAssertNotNil(inside)
        let outside = detector.match(rowText: row, cwd: tmpCwd, atCol: 12)
        XCTAssertNil(outside)
    }

    // MARK: - Cache behavior

    func testCacheReturnsSameValueWithoutRecompute() throws {
        _ = try touch("dir/a.txt")
        var calls = 0
        let detector = BareTextPathDetector { _ in
            calls += 1
            return true
        }
        let row = rowText("see dir/a.txt")
        _ = detector.allMatches(rowText: row, cwd: tmpCwd)
        let first = calls
        XCTAssertGreaterThan(first, 0, "first scan must hit fileExists")
        _ = detector.allMatches(rowText: row, cwd: tmpCwd)
        XCTAssertEqual(calls, first, "cached row text must not re-stat")
    }

    func testCacheDifferentRowTextRecomputes() throws {
        _ = try touch("dir/a.txt")
        _ = try touch("dir/b.txt")
        var calls = 0
        let detector = BareTextPathDetector { _ in
            calls += 1
            return true
        }
        _ = detector.allMatches(rowText: rowText("see dir/a.txt"), cwd: tmpCwd)
        let after1 = calls
        _ = detector.allMatches(rowText: rowText("see dir/b.txt"), cwd: tmpCwd)
        XCTAssertGreaterThan(calls, after1)
    }

    func testCacheClearForcesRecompute() throws {
        _ = try touch("dir/a.txt")
        var calls = 0
        let detector = BareTextPathDetector { _ in
            calls += 1
            return true
        }
        _ = detector.allMatches(rowText: rowText("see dir/a.txt"), cwd: tmpCwd)
        let before = calls
        detector.clearCache()
        _ = detector.allMatches(rowText: rowText("see dir/a.txt"), cwd: tmpCwd)
        XCTAssertGreaterThan(calls, before)
    }
}
