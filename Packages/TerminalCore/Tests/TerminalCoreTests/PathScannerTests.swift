import XCTest
@testable import TerminalCore

final class PathScannerTests: XCTestCase {
    // MARK: - Helpers

    private func paths(in text: String) -> [String] {
        PathScanner.scan(text).map { $0.path }
    }

    // MARK: - Absolute & relative

    func testAbsolutePathMatches() {
        let m = PathScanner.scan("see /Users/alice/foo.swift for details")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.path, "/Users/alice/foo.swift")
        XCTAssertNil(m.first?.line)
        XCTAssertNil(m.first?.column)
    }

    func testRelativePathRequiresSlash() {
        // "hello.txt" alone (no slash) must NOT match — too prone to false positives.
        XCTAssertEqual(paths(in: "open hello.txt"), [])
        // With a slash it should match.
        XCTAssertEqual(paths(in: "open dir/hello.txt"), ["dir/hello.txt"])
    }

    func testHomeRelativePathMatches() {
        XCTAssertEqual(paths(in: "log: ~/Library/Logs/foo.log"), ["~/Library/Logs/foo.log"])
    }

    func testDotRelativePathMatches() {
        XCTAssertEqual(paths(in: "edit ./Cell.swift"), ["./Cell.swift"])
        XCTAssertEqual(paths(in: "see ../shared/util.h"), ["../shared/util.h"])
    }

    // MARK: - Line / column suffixes

    func testLineSuffix() {
        let m = PathScanner.scan("crash at /a/b/c.swift:42")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.path, "/a/b/c.swift")
        XCTAssertEqual(m.first?.line, 42)
        XCTAssertNil(m.first?.column)
    }

    func testLineColumnSuffix() {
        let m = PathScanner.scan("at /a/b/c.swift:42:7")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.path, "/a/b/c.swift")
        XCTAssertEqual(m.first?.line, 42)
        XCTAssertEqual(m.first?.column, 7)
    }

    func testLineSuffixOnRelativePath() {
        let m = PathScanner.scan("Packages/TerminalCore/Cell.swift:14:5")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.path, "Packages/TerminalCore/Cell.swift")
        XCTAssertEqual(m.first?.line, 14)
        XCTAssertEqual(m.first?.column, 5)
    }

    // MARK: - file:// URIs

    func testFileURIMatches() {
        let m = PathScanner.scan("link: file:///tmp/x.log")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.path, "file:///tmp/x.log")
    }

    func testFileURIWithLineSuffix() {
        let m = PathScanner.scan("file:///tmp/x.log:99")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.path, "file:///tmp/x.log")
        XCTAssertEqual(m.first?.line, 99)
    }

    // MARK: - Punctuation trimming

    func testTrailingPunctuationStripped() {
        let m = PathScanner.scan("see /a/b/c.swift, then /d/e/f.swift.")
        XCTAssertEqual(m.map(\.path), ["/a/b/c.swift", "/d/e/f.swift"])
    }

    func testParensAreNotPartOfPath() {
        let m = PathScanner.scan("(see /a/b/c.swift)")
        XCTAssertEqual(m.map(\.path), ["/a/b/c.swift"])
    }

    func testDanglingColonNotInterpretedAsLine() {
        let m = PathScanner.scan("path /a/b/c.swift: blah")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.path, "/a/b/c.swift")
        XCTAssertNil(m.first?.line)
    }

    // MARK: - Multiple matches

    func testMultiplePathsInLine() {
        let m = PathScanner.scan("from a/b.swift:10 to c/d.swift")
        XCTAssertEqual(m.map(\.path), ["a/b.swift", "c/d.swift"])
        XCTAssertEqual(m[0].line, 10)
        XCTAssertNil(m[1].line)
    }

    // MARK: - False-positive guards

    func testNoSlashIdentifierIgnored() {
        XCTAssertEqual(paths(in: "version foo.bar 1.2.3"), [])
    }

    func testEmptyInput() {
        XCTAssertEqual(PathScanner.scan(""), [])
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(PathScanner.scan("    "), [])
    }
}
