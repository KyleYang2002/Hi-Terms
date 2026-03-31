import XCTest
import os.log
import OSLog

/// Verifies OSLog subsystem configuration and queryability via OSLogStore.
final class OSLogVerificationTests: XCTestCase {

    func testOSLogWriteAndQuery() throws {
        let marker = "OSLOG_TEST_\(UUID().uuidString)"
        let logger = Logger(subsystem: "com.hiterms.app", category: "general")
        logger.info("\(marker)")

        // Allow log propagation
        Thread.sleep(forTimeInterval: 1.0)

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-10))
        let entries = try store.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.hiterms.app" && $0.composedMessage.contains(marker) }

        XCTAssertFalse(entries.isEmpty, "Should find OSLog entry with marker: \(marker)")
    }

    func testAllSubsystemsConfigured() throws {
        let subsystems = [
            ("com.hiterms.pty", "lifecycle"),
            ("com.hiterms.terminal", "parser"),
            ("com.hiterms.renderer", "frame"),
            ("com.hiterms.app", "general"),
        ]

        for (subsystem, category) in subsystems {
            let marker = "SUBSYSTEM_TEST_\(UUID().uuidString)"
            let logger = Logger(subsystem: subsystem, category: category)
            logger.info("\(marker)")
        }

        // Allow log propagation
        Thread.sleep(forTimeInterval: 1.5)

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-10))
        let allEntries = try Array(store.getEntries(at: position))
            .compactMap { $0 as? OSLogEntryLog }

        for (subsystem, _) in subsystems {
            let found = allEntries.contains { $0.subsystem == subsystem }
            XCTAssertTrue(found, "Should find entries for subsystem: \(subsystem)")
        }
    }
}
