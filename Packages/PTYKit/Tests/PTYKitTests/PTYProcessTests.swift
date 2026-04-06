import XCTest
@testable import PTYKit

final class PTYProcessTests: XCTestCase {
    func testEchoHello() async throws {
        let config = PTYConfiguration(
            shellPath: "/bin/echo",
            arguments: ["hello"],
            environment: [:],
            initialWindowSize: (cols: 80, rows: 25)
        )
        let process = try PTYProcess(configuration: config)
        var output = Data()

        let stream = process.read()
        let deadline = Date().addingTimeInterval(5)

        for await chunk in stream {
            output.append(chunk)
            // echo outputs quickly and exits
            if Date() > deadline { break }
            let text = String(data: output, encoding: .utf8) ?? ""
            if text.contains("hello") { break }
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("hello"), "Output should contain 'hello', got: '\(text)'")
    }

    func testPTYConfiguration() {
        let config = PTYConfiguration.default
        XCTAssertFalse(config.shellPath.isEmpty)
        XCTAssertEqual(config.initialWindowSize.cols, 80)
        XCTAssertEqual(config.initialWindowSize.rows, 25)
        XCTAssertEqual(config.terminalType, "xterm-256color")
    }

    func testExitHandler() async throws {
        let config = PTYConfiguration(
            shellPath: "/bin/sh",
            arguments: ["-c", "exit 42"],
            environment: [:]
        )
        let process = try PTYProcess(configuration: config)

        let expectation = expectation(description: "exitHandler called")
        var receivedCode: Int32?
        process.exitHandler = { code in
            receivedCode = code
            expectation.fulfill()
        }

        // Drain the stream to trigger EOF detection
        let stream = process.read()
        for await _ in stream { break }

        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(receivedCode, 42, "Exit code should be 42, got: \(String(describing: receivedCode))")
    }

    func testTermEnvironmentVariable() async throws {
        let config = PTYConfiguration(
            shellPath: "/bin/sh",
            arguments: ["-c", "echo $TERM"],
            environment: [:]
        )
        let process = try PTYProcess(configuration: config)
        var output = Data()

        let stream = process.read()
        let deadline = Date().addingTimeInterval(5)

        for await chunk in stream {
            output.append(chunk)
            if Date() > deadline { break }
            let text = String(data: output, encoding: .utf8) ?? ""
            if text.contains("xterm-256color") { break }
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("xterm-256color"),
                      "TERM should be xterm-256color, got: '\(text)'")
    }

    func testPTYErrorDescriptions() {
        let errors: [(PTYError, String)] = [
            (.forkFailed(errno: ENOMEM), "forkpty"),
            (.execFailed(path: "/bin/zsh", errno: ENOENT), "exec"),
            (.readFailed(errno: EIO), "read"),
            (.writeFailed(errno: EPIPE), "write"),
            (.processNotRunning, "not running"),
        ]
        for (error, keyword) in errors {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "errorDescription should not be nil for \(error)")
            XCTAssertTrue(desc!.localizedCaseInsensitiveContains(keyword),
                          "'\(desc!)' should contain '\(keyword)'")
        }
    }
}
