import XCTest
import Foundation
@testable import TerminalUI

/// V0.2 OSC 8 safety policy:
/// - http/https: opened directly
/// - file://: only when inside cwd subtree
/// - everything else: rejected
final class HyperlinkOpenerPolicyTests: XCTestCase {

    // MARK: - Helpers

    /// Recording opener that captures whatever URLs the policy passes through.
    /// Returning `true` simulates a successful NSWorkspace.open.
    private final class Recorder {
        var opened: [URL] = []
        func opener(_ result: Bool = true) -> HyperlinkOpener.Opener {
            { [weak self] url in
                self?.opened.append(url)
                return result
            }
        }
    }

    // MARK: - http/https

    func testHTTPSOpensDirectly() {
        let rec = Recorder()
        XCTAssertTrue(HyperlinkOpener.open(
            "https://anthropic.com",
            cwd: nil,
            opener: rec.opener()))
        XCTAssertEqual(rec.opened.map { $0.absoluteString }, ["https://anthropic.com"])
    }

    func testHTTPOpensDirectly() {
        let rec = Recorder()
        XCTAssertTrue(HyperlinkOpener.open(
            "http://example.com/path?q=1",
            cwd: nil,
            opener: rec.opener()))
        XCTAssertEqual(rec.opened.first?.scheme, "http")
    }

    func testHTTPOpenerFailureReturnsFalse() {
        // A scheme that passes the policy but the workspace can't open
        // returns false — used by the click handler to fall through to
        // selection / SGR if the open ultimately failed.
        let rec = Recorder()
        XCTAssertFalse(HyperlinkOpener.open(
            "https://example.com",
            cwd: nil,
            opener: rec.opener(false)))
    }

    // MARK: - file:// cwd containment

    func testFileURLInsideCWDOpens() throws {
        let tmp = try makeTempCWD()
        let inside = tmp.appendingPathComponent("hello.txt")
        try "hi".write(to: inside, atomically: true, encoding: .utf8)
        let rec = Recorder()
        XCTAssertTrue(HyperlinkOpener.open(
            inside.absoluteString,
            cwd: tmp,
            opener: rec.opener()))
        XCTAssertEqual(rec.opened.first?.path, inside.standardizedFileURL.path)
    }

    func testFileURLEqualToCWDOpens() throws {
        // Opening the cwd itself (a directory) is allowed — the policy treats
        // an exact match as inside the subtree.
        let tmp = try makeTempCWD()
        let rec = Recorder()
        XCTAssertTrue(HyperlinkOpener.open(
            tmp.absoluteString,
            cwd: tmp,
            opener: rec.opener()))
        XCTAssertEqual(rec.opened.count, 1)
    }

    func testFileURLOutsideCWDRejected() throws {
        let tmp = try makeTempCWD()
        let rec = Recorder()
        XCTAssertFalse(HyperlinkOpener.open(
            "file:///etc/passwd",
            cwd: tmp,
            opener: rec.opener()))
        XCTAssertTrue(rec.opened.isEmpty,
                      "policy must drop file:// outside cwd before reaching opener")
    }

    func testFileURLSiblingPrefixDoesNotMatch() throws {
        // /tmp/abc must NOT count as inside /tmp/ab — guards against the bug
        // where a naive hasPrefix without a trailing "/" lets sibling dirs
        // through.
        let tmp = try makeTempCWD()
        // Build a sibling that shares a path prefix string.
        let parent = tmp.deletingLastPathComponent()
        let basename = tmp.lastPathComponent
        let sibling = parent.appendingPathComponent(basename + "-sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let target = sibling.appendingPathComponent("file.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)

        let rec = Recorder()
        XCTAssertFalse(HyperlinkOpener.open(
            target.absoluteString,
            cwd: tmp,
            opener: rec.opener()))
        XCTAssertTrue(rec.opened.isEmpty)
    }

    func testFileURLWithNilCWDRejected() {
        let rec = Recorder()
        XCTAssertFalse(HyperlinkOpener.open(
            "file:///tmp/anything",
            cwd: nil,
            opener: rec.opener()))
        XCTAssertTrue(rec.opened.isEmpty)
    }

    // MARK: - Other schemes

    func testJavaScriptSchemeRejected() {
        let rec = Recorder()
        XCTAssertFalse(HyperlinkOpener.open(
            "javascript:alert(1)",
            cwd: nil,
            opener: rec.opener()))
        XCTAssertTrue(rec.opened.isEmpty)
    }

    func testMailtoRejected() {
        let rec = Recorder()
        XCTAssertFalse(HyperlinkOpener.open(
            "mailto:test@example.com",
            cwd: nil,
            opener: rec.opener()))
    }

    func testMalformedURLRejected() {
        let rec = Recorder()
        XCTAssertFalse(HyperlinkOpener.open(
            "",
            cwd: nil,
            opener: rec.opener()))
    }

    // MARK: - Helpers

    private func makeTempCWD() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hi-terms-hyperlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
