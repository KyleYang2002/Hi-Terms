import XCTest
@testable import TerminalUI

final class EditorJumpTests: XCTestCase {
    private final class Recorder {
        var openedURLs: [URL] = []
        var launchedProcs: [(exe: String, args: [String])] = []
        var processResult = true
        var urlResult = true

        func urlOpener() -> EditorJump.URLOpener {
            { [weak self] url in
                self?.openedURLs.append(url)
                return self?.urlResult ?? true
            }
        }
        func launcher() -> EditorJump.ProcessLauncher {
            { [weak self] exe, args in
                self?.launchedProcs.append((exe, args))
                return self?.processResult ?? true
            }
        }
    }

    // MARK: - Xcode dispatch

    func testSwiftFileWithLineUsesXed() {
        let rec = Recorder()
        XCTAssertTrue(EditorJump.open(
            absPath: "/proj/A.swift", line: 12, column: 4,
            urlOpener: rec.urlOpener(),
            processLauncher: rec.launcher()
        ))
        XCTAssertEqual(rec.launchedProcs.count, 1)
        XCTAssertEqual(rec.launchedProcs[0].exe, "/usr/bin/xed")
        XCTAssertEqual(rec.launchedProcs[0].args, ["-l", "12", "/proj/A.swift"])
        XCTAssertTrue(rec.openedURLs.isEmpty)
    }

    func testXcodeprojWithoutLineUsesXed() {
        let rec = Recorder()
        XCTAssertTrue(EditorJump.open(
            absPath: "/proj/App.xcodeproj", line: nil, column: nil,
            urlOpener: rec.urlOpener(),
            processLauncher: rec.launcher()
        ))
        XCTAssertEqual(rec.launchedProcs.count, 1)
        XCTAssertEqual(rec.launchedProcs[0].args, ["/proj/App.xcodeproj"])
    }

    func testXedFailureFallsBackToWorkspace() {
        let rec = Recorder()
        rec.processResult = false
        XCTAssertTrue(EditorJump.open(
            absPath: "/proj/A.swift", line: 1, column: nil,
            urlOpener: rec.urlOpener(),
            processLauncher: rec.launcher()
        ))
        XCTAssertEqual(rec.launchedProcs.count, 1)
        XCTAssertEqual(rec.openedURLs.count, 1)
        XCTAssertEqual(rec.openedURLs[0].scheme, "file")
        XCTAssertEqual(rec.openedURLs[0].path, "/proj/A.swift")
    }

    // MARK: - VS Code dispatch

    func testNonXcodeExtensionWithLineUsesVSCodeURL() {
        let rec = Recorder()
        XCTAssertTrue(EditorJump.open(
            absPath: "/proj/server.js", line: 50, column: 3,
            urlOpener: rec.urlOpener(),
            processLauncher: rec.launcher()
        ))
        XCTAssertTrue(rec.launchedProcs.isEmpty)
        XCTAssertEqual(rec.openedURLs.count, 1)
        XCTAssertEqual(rec.openedURLs[0].absoluteString,
                       "vscode://file/proj/server.js:50:3")
    }

    func testVSCodeURLWithoutColumn() {
        let rec = Recorder()
        XCTAssertTrue(EditorJump.open(
            absPath: "/proj/x.py", line: 5, column: nil,
            urlOpener: rec.urlOpener(),
            processLauncher: rec.launcher()
        ))
        XCTAssertEqual(rec.openedURLs[0].absoluteString,
                       "vscode://file/proj/x.py:5")
    }

    func testVSCodeURLPercentEncodesSpaces() {
        let rec = Recorder()
        XCTAssertTrue(EditorJump.open(
            absPath: "/My Docs/x.txt", line: 1, column: nil,
            urlOpener: rec.urlOpener(),
            processLauncher: rec.launcher()
        ))
        XCTAssertEqual(rec.openedURLs[0].absoluteString,
                       "vscode://file/My%20Docs/x.txt:1")
    }

    func testVSCodeFailureFallsBackToWorkspace() {
        let rec = Recorder()
        // urlOpener will be called once with vscode:// (returns false), then once
        // with file:// fallback.
        var calls = 0
        let opener: EditorJump.URLOpener = { url in
            calls += 1
            rec.openedURLs.append(url)
            return calls > 1   // first call (vscode://) fails, second (file://) succeeds
        }
        XCTAssertTrue(EditorJump.open(
            absPath: "/proj/x.py", line: 1, column: nil,
            urlOpener: opener,
            processLauncher: rec.launcher()
        ))
        XCTAssertEqual(rec.openedURLs.count, 2)
        XCTAssertEqual(rec.openedURLs[0].scheme, "vscode")
        XCTAssertEqual(rec.openedURLs[1].scheme, "file")
    }

    // MARK: - No-line dispatch

    func testNoLineUsesNSWorkspace() {
        let rec = Recorder()
        XCTAssertTrue(EditorJump.open(
            absPath: "/proj/img.png", line: nil, column: nil,
            urlOpener: rec.urlOpener(),
            processLauncher: rec.launcher()
        ))
        XCTAssertTrue(rec.launchedProcs.isEmpty)
        XCTAssertEqual(rec.openedURLs.count, 1)
        XCTAssertEqual(rec.openedURLs[0].scheme, "file")
    }

    // MARK: - URL builder

    func testVSCodeURLBuilderEmitsExpectedShape() {
        XCTAssertEqual(
            EditorJump.vscodeURL(absPath: "/a/b.swift", line: 9, column: 2)?.absoluteString,
            "vscode://file/a/b.swift:9:2"
        )
        XCTAssertEqual(
            EditorJump.vscodeURL(absPath: "/a/b.swift", line: 9, column: nil)?.absoluteString,
            "vscode://file/a/b.swift:9"
        )
    }
}
