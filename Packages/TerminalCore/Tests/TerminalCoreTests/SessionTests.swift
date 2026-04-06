import XCTest
@testable import TerminalCore

// MARK: - Mocks

/// Mock pipeline for testing TerminalSession without TerminalUI dependency.
private final class MockPipeline: TerminalPipeline {
    var parser: any TerminalParser
    var screenBuffer: ScreenBuffer

    var startCalled = false
    var stopCalled = false
    var writtenData: [Data] = []
    var lastResizeCols: Int?
    var lastResizeRows: Int?

    init() {
        self.parser = MockParser()
        self.screenBuffer = ScreenBuffer(rows: 25, cols: 80)
    }

    func start() { startCalled = true }
    func stop() { stopCalled = true }
    func write(data: Data) { writtenData.append(data) }
    func resize(cols: Int, rows: Int) {
        lastResizeCols = cols
        lastResizeRows = rows
    }
}

private final class MockParser: TerminalParser {
    var delegate: TerminalParserDelegate?
    func parse(data: Data) {}
}

// MARK: - Session Tests (B10, B11)

final class SessionTests: XCTestCase {

    // MARK: - B10: Session ID

    /// B10: Each session has a unique UUID.
    func testSessionHasUniqueID() {
        let pipeline1 = MockPipeline()
        let pipeline2 = MockPipeline()
        let session1 = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline1)
        let session2 = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline2)
        XCTAssertNotEqual(session1.id, session2.id, "Each session must have a unique ID")
    }

    /// B10: SessionID is UUID type.
    func testSessionIDIsUUID() {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)
        // SessionID is typealias for UUID; this compiles only if true
        let _: UUID = session.id
        XCTAssertFalse(session.id.uuidString.isEmpty)
    }

    // MARK: - B11: PTY Ownership

    /// B11: After start(), the pipeline is activated.
    func testSessionOwnsPTY() throws {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        try session.start()

        XCTAssertTrue(pipeline.startCalled, "Pipeline.start() should be called after session.start()")
        XCTAssertNotNil(session.pipeline, "Session must own a pipeline")
    }

    /// B11: After stop(), the pipeline is terminated and state is exited.
    func testSessionStopTerminatesPTY() throws {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        try session.start()
        session.stop()

        XCTAssertTrue(pipeline.stopCalled, "Pipeline.stop() should be called after session.stop()")
        if case .exited(let code) = session.state {
            XCTAssertEqual(code, 0, "Explicit stop should exit with code 0")
        } else {
            XCTFail("Session state should be .exited after stop()")
        }
    }

    /// B11: Session deallocation terminates the pipeline.
    func testSessionDeallocTerminatesPTY() {
        let pipeline = MockPipeline()

        autoreleasepool {
            var session: TerminalSession? = TerminalSession(
                launchCommand: "/bin/zsh",
                pipeline: pipeline
            )
            try? session?.start()
            XCTAssertTrue(pipeline.startCalled)

            session = nil  // Triggers deinit → pipeline.stop()
        }

        XCTAssertTrue(pipeline.stopCalled,
                       "Pipeline should be stopped when session is deallocated while running")
    }

    // MARK: - State Transitions

    /// Verifies handleProcessExit transitions state and fires callback.
    func testHandleProcessExitTransitionsState() throws {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        var receivedState: SessionState?
        session.onStateChanged = { state in
            receivedState = state
        }

        try session.start()
        session.handleProcessExit(code: 42)

        if case .exited(let code) = session.state {
            XCTAssertEqual(code, 42)
        } else {
            XCTFail("State should be .exited(code: 42)")
        }

        if case .exited(let code) = receivedState {
            XCTAssertEqual(code, 42, "onStateChanged should receive the exit code")
        } else {
            XCTFail("onStateChanged should fire with .exited state")
        }
    }

    /// Double start should be idempotent.
    func testDoubleStartIsIdempotent() throws {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        try session.start()
        try session.start()  // Should not throw or call start() again

        XCTAssertTrue(pipeline.startCalled)
    }

    /// Stop after already exited should be a no-op.
    func testStopAfterExitIsNoop() throws {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        try session.start()
        session.handleProcessExit(code: 0)
        pipeline.stopCalled = false  // Reset

        session.stop()  // Should be a no-op since already exited

        XCTAssertFalse(pipeline.stopCalled, "stop() should be a no-op when already exited")
    }

    /// Write forwards to pipeline.
    func testWriteForwardsToPipeline() throws {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        let testData = "hello".data(using: .utf8)!
        session.write(data: testData)

        XCTAssertEqual(pipeline.writtenData.count, 1)
        XCTAssertEqual(pipeline.writtenData.first, testData)
    }

    /// Resize forwards to pipeline.
    func testResizeForwardsToPipeline() throws {
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        session.resize(cols: 120, rows: 40)

        XCTAssertEqual(pipeline.lastResizeCols, 120)
        XCTAssertEqual(pipeline.lastResizeRows, 40)
    }
}

// MARK: - Registry Tests (B12)

final class SessionRegistryTests: XCTestCase {

    /// B12: Registered session appears in allSessions.
    func testRegistryRegisterAndQuery() {
        let registry = SessionRegistry()
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        registry.register(session)

        let all = registry.allSessions()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, session.id)
    }

    /// B12: Query by ID returns the correct session.
    func testRegistryQueryByID() {
        let registry = SessionRegistry()
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        registry.register(session)

        let found = registry.session(for: session.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, session.id)
    }

    /// B12: Unregistered session returns nil on query.
    func testRegistryUnregister() {
        let registry = SessionRegistry()
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        registry.register(session)
        registry.unregister(session.id)

        XCTAssertNil(registry.session(for: session.id))
        XCTAssertEqual(registry.count, 0)
    }

    /// B12: Session state is queryable through registry.
    func testRegistrySessionState() throws {
        let registry = SessionRegistry()
        let pipeline = MockPipeline()
        let session = TerminalSession(launchCommand: "/bin/zsh", pipeline: pipeline)

        registry.register(session)

        // Running state
        if case .running = registry.session(for: session.id)?.state {
            // OK
        } else {
            XCTFail("Registered session should be in .running state")
        }

        // Transition to exited
        session.handleProcessExit(code: 1)

        if case .exited(let code) = registry.session(for: session.id)?.state {
            XCTAssertEqual(code, 1)
        } else {
            XCTFail("Session should be in .exited state after process exit")
        }
    }

    /// B12: Concurrent register/query/unregister from multiple queues without crash.
    func testRegistryThreadSafety() {
        let registry = SessionRegistry()
        let group = DispatchGroup()
        let iterations = 100

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let pipeline = MockPipeline()
                let session = TerminalSession(launchCommand: "/bin/sh", pipeline: pipeline)

                registry.register(session)
                _ = registry.allSessions()
                _ = registry.session(for: session.id)
                _ = registry.count
                registry.unregister(session.id)

                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "All concurrent operations should complete without deadlock")
        XCTAssertEqual(registry.count, 0, "All sessions should be unregistered")
    }
}
