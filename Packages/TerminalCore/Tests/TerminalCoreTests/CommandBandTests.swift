import XCTest
@testable import TerminalCore

/// `ShellIntegrationState.bands()` projects `CommandRecord` instances into
/// render-friendly `CommandBand`s. Coverage:
///   * Standard A/B/C/D success → success status, both ranges set.
///   * Non-zero exit → `.failure(exit)`.
///   * In-flight command (no D) → `.running`, outputRows upper-bound `Int.max`.
///   * Skipped B (A → C → D) → promptRows ends at `outputStartLine - 1`.
///   * A only (no B/C/D yet) → promptRows is a single row, outputRows nil.
///   * D without prior A/B/C (synthesised) → no ranges, status from exit.
///   * Multiple records preserve insertion order.
final class CommandBandTests: XCTestCase {

    func testSuccessCommandWithFullABCDRanges() {
        let state = ShellIntegrationState()
        state.handlePromptStart(line: 100)
        state.handleCommandInputStart(line: 100)
        state.handleCommandOutputStart(line: 101)
        state.handleCommandEnd(line: 110, exitCode: 0)
        let band = state.bands().first
        XCTAssertEqual(band?.status, .success)
        XCTAssertEqual(band?.promptRows, 100...100)
        XCTAssertEqual(band?.outputRows, 101...109,
                       "outputRows must end one row above endLine (D row owns next prompt)")
    }

    func testFailureCommand() {
        let state = ShellIntegrationState()
        state.handlePromptStart(line: 50)
        state.handleCommandInputStart(line: 50)
        state.handleCommandOutputStart(line: 51)
        state.handleCommandEnd(line: 53, exitCode: 127)
        XCTAssertEqual(state.bands().first?.status, .failure(exitCode: 127))
    }

    func testRunningCommandOpenEndedOutput() {
        let state = ShellIntegrationState()
        state.handlePromptStart(line: 200)
        state.handleCommandInputStart(line: 200)
        state.handleCommandOutputStart(line: 201)
        // No D yet — band represents the still-running current command.
        let band = state.bands().first
        XCTAssertEqual(band?.status, .running)
        XCTAssertEqual(band?.promptRows, 200...200)
        XCTAssertEqual(band?.outputRows?.lowerBound, 201)
        XCTAssertEqual(band?.outputRows?.upperBound, Int.max,
                       "running command's outputRows must use Int.max sentinel for open-ended")
    }

    func testSkippedBSubcommand() {
        // Some shells emit only A and C (no B). promptRows must end at
        // outputStartLine - 1 in that case, not collapse to A's line only.
        let state = ShellIntegrationState()
        state.handlePromptStart(line: 10)
        state.handleCommandOutputStart(line: 12) // skipped B
        state.handleCommandEnd(line: 15, exitCode: 0)
        let band = state.bands().first
        XCTAssertEqual(band?.promptRows, 10...11,
                       "without B, prompt ends at outputStartLine - 1")
        XCTAssertEqual(band?.outputRows, 12...14)
    }

    func testPromptOnlyRecordHasNoOutputRows() {
        let state = ShellIntegrationState()
        state.handlePromptStart(line: 5)
        // No B/C/D at all.
        let band = state.bands().first
        XCTAssertEqual(band?.status, .running)
        XCTAssertEqual(band?.promptRows, 5...5)
        XCTAssertNil(band?.outputRows,
                     "without C, there is no output range to project")
    }

    func testSynthesisedRecordFromBareEnd() {
        // OSC 133;D arrives with no prior A/B/C — handleCommandEnd
        // synthesises a minimal record. Both ranges must be nil.
        let state = ShellIntegrationState()
        state.handleCommandEnd(line: 42, exitCode: 1)
        let band = state.bands().first
        XCTAssertEqual(band?.status, .failure(exitCode: 1))
        XCTAssertNil(band?.promptRows)
        XCTAssertNil(band?.outputRows)
    }

    func testNoOutputCommandHasNilOutputRows() {
        // Command finishes on the same line as it started outputting (e.g.
        // `:` in zsh): outputStartLine == endLine, so endLine - 1 < start →
        // outputRows must collapse to nil.
        let state = ShellIntegrationState()
        state.handlePromptStart(line: 0)
        state.handleCommandInputStart(line: 0)
        state.handleCommandOutputStart(line: 1)
        state.handleCommandEnd(line: 1, exitCode: 0)
        let band = state.bands().first
        XCTAssertEqual(band?.promptRows, 0...0)
        XCTAssertNil(band?.outputRows)
    }

    func testMultipleHistoryRecordsKeepOrderPlusRunningTail() {
        let state = ShellIntegrationState()
        // Record 1 — completed success
        state.handlePromptStart(line: 0)
        state.handleCommandInputStart(line: 0)
        state.handleCommandOutputStart(line: 1)
        state.handleCommandEnd(line: 5, exitCode: 0)
        // Record 2 — completed failure
        state.handlePromptStart(line: 5)
        state.handleCommandInputStart(line: 5)
        state.handleCommandOutputStart(line: 6)
        state.handleCommandEnd(line: 8, exitCode: 2)
        // Record 3 — still running
        state.handlePromptStart(line: 8)
        state.handleCommandInputStart(line: 8)
        state.handleCommandOutputStart(line: 9)

        let bands = state.bands()
        XCTAssertEqual(bands.count, 3)
        XCTAssertEqual(bands[0].status, .success)
        XCTAssertEqual(bands[1].status, .failure(exitCode: 2))
        XCTAssertEqual(bands[2].status, .running)
        // History order preserved, current appended last.
        XCTAssertEqual(bands[0].promptRows?.lowerBound, 0)
        XCTAssertEqual(bands[1].promptRows?.lowerBound, 5)
        XCTAssertEqual(bands[2].promptRows?.lowerBound, 8)
    }
}
