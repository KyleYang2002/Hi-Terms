import XCTest
@testable import TerminalCore

/// Coverage for V0.0.3 T1 — Shell Integration:
///   * OSC 7 (cwd) round-trips through SwiftTerm into ShellIntegrationState.
///   * OSC 133 ;A/B/C/D drive the CommandRecord lifecycle correctly.
///   * Other OSC codes (title, etc.) keep working alongside our 133 handler.
///   * `parseFileURI` is exercised directly so URL decoding bugs surface fast.
final class ShellIntegrationTests: XCTestCase {

    // MARK: - OSC 7 (current working directory)

    func testOSC7_localPath() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: data("\u{1B}]7;file://localhost/Users/amma/proj\u{1B}\\"))

        XCTAssertEqual(adapter.shellIntegration.currentWorkingDirectoryHost, "localhost")
        XCTAssertEqual(adapter.shellIntegration.currentWorkingDirectoryURL?.path, "/Users/amma/proj")
        XCTAssertNotNil(adapter.shellIntegration.currentWorkingDirectoryRaw)
    }

    func testOSC7_urlEncodedCJK() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // %E4%B8%AD%E6%96%87 == "中文"
        adapter.parse(data: data("\u{1B}]7;file://localhost/Users/amma/%E4%B8%AD%E6%96%87\u{1B}\\"))

        XCTAssertEqual(
            adapter.shellIntegration.currentWorkingDirectoryURL?.path,
            "/Users/amma/中文",
            "URL-encoded CJK octets must decode back to the original characters."
        )
    }

    func testOSC7_remoteHost() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: data("\u{1B}]7;file://devbox.example.com/srv/app\u{1B}\\"))

        XCTAssertEqual(adapter.shellIntegration.currentWorkingDirectoryHost, "devbox.example.com")
        XCTAssertEqual(adapter.shellIntegration.currentWorkingDirectoryURL?.path, "/srv/app")
    }

    func testCwdChangeFiresCallback() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        let exp = expectation(description: "cwd change callback")
        var observedHost: String?
        adapter.shellIntegration.onChange = { change in
            if case .cwdChanged(_, let host, _) = change {
                observedHost = host
                exp.fulfill()
            }
        }
        adapter.parse(data: data("\u{1B}]7;file://myhost/tmp\u{1B}\\"))
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(observedHost, "myhost")
    }

    // MARK: - OSC 133 (FinalTerm semantic prompt markers)

    func testOSC133_A_capturesPromptLine() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        // Drive the cursor down a few rows so promptStartLine isn't 0 by chance.
        adapter.parse(data: data("line1\r\nline2\r\nline3\r\n"))
        let expectedLine = adapter.scrollInvariantRow(forViewportRow: adapter.terminal.buffer.y)
        adapter.parse(data: data("\u{1B}]133;A\u{1B}\\"))

        XCTAssertNotNil(adapter.shellIntegration.current)
        XCTAssertEqual(adapter.shellIntegration.current?.promptStartLine, expectedLine)
    }

    func testOSC133_FullCycle_A_B_C_D() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        var observed: [String] = []
        adapter.shellIntegration.onChange = { change in
            switch change {
            case .promptStarted:        observed.append("A")
            case .commandInputStarted:  observed.append("B")
            case .commandOutputStarted: observed.append("C")
            case .commandFinished:      observed.append("D")
            case .cwdChanged:           observed.append("cwd")
            }
        }

        adapter.parse(data: data("\u{1B}]133;A\u{1B}\\"))
        adapter.parse(data: data("\u{1B}]133;B\u{1B}\\"))
        adapter.parse(data: data("\u{1B}]133;C\u{1B}\\"))
        adapter.parse(data: data("\u{1B}]133;D;0\u{1B}\\"))

        XCTAssertEqual(observed, ["A", "B", "C", "D"])
        XCTAssertNil(adapter.shellIntegration.current, "current must be cleared after D")
        XCTAssertEqual(adapter.shellIntegration.lastExitCode, 0)
        XCTAssertEqual(adapter.shellIntegration.commandHistory.count, 1)
        let rec = adapter.shellIntegration.commandHistory[0]
        XCTAssertNotNil(rec.promptStartLine)
        XCTAssertNotNil(rec.commandStartLine)
        XCTAssertNotNil(rec.outputStartLine)
        XCTAssertNotNil(rec.endLine)
        XCTAssertEqual(rec.exitCode, 0)
    }

    func testOSC133_D_nonZeroExit() {
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: data("\u{1B}]133;A\u{1B}\\"))
        adapter.parse(data: data("\u{1B}]133;C\u{1B}\\"))
        adapter.parse(data: data("\u{1B}]133;D;127\u{1B}\\"))

        XCTAssertEqual(adapter.shellIntegration.lastExitCode, 127)
        XCTAssertEqual(adapter.shellIntegration.commandHistory.last?.exitCode, 127)
    }

    func testOSC133_handlerDoesNotConsumeOtherOSC() {
        // Sanity-check that registering an OSC 133 handler doesn't disturb
        // SwiftTerm's other OSC parsers. We use OSC 7 as the canary because
        // (a) it's also a SwiftTerm-provided handler and (b) the result is
        // observable via hostCurrentDirectory — `terminalTitle` is internal
        // to SwiftTerm so OSC 0 isn't externally observable from here.
        let adapter = SwiftTermAdapter(cols: 80, rows: 25)
        adapter.parse(data: data("\u{1B}]7;file://localhost/etc\u{1B}\\"))
        XCTAssertEqual(adapter.terminal.hostCurrentDirectory, "file://localhost/etc",
                       "Registering OSC 133 must not block SwiftTerm's OSC 7 handler.")

        // And OSC 133 still works after.
        adapter.parse(data: data("\u{1B}]133;A\u{1B}\\"))
        XCTAssertNotNil(adapter.shellIntegration.current)
    }

    // MARK: - parseFileURI direct unit coverage

    func testParseFileURI_simple() {
        let (url, host) = ShellIntegrationState.parseFileURI("file://localhost/var/log")
        XCTAssertEqual(host, "localhost")
        XCTAssertEqual(url?.path, "/var/log")
    }

    func testParseFileURI_cjkEncoded() {
        let (url, _) = ShellIntegrationState.parseFileURI("file://localhost/%E4%B8%AD%E6%96%87")
        XCTAssertEqual(url?.path, "/中文")
    }

    func testParseFileURI_invalidScheme() {
        let (url, host) = ShellIntegrationState.parseFileURI("http://example.com/x")
        XCTAssertNil(url)
        XCTAssertNil(host)
    }

    // MARK: - Helpers

    private func data(_ s: String) -> Data {
        Data(s.utf8)
    }
}
