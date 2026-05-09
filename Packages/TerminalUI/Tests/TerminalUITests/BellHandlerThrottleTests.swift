import XCTest
import AppKit
import UserNotifications
import TerminalCore
import Configuration
@testable import TerminalUI

/// Wave 2-C: BEL throttling — multiple bells inside a 200 ms window must
/// collapse to one observable visual flash. Uses an injected `nowProvider`
/// closure instead of `sleep()` so the throttle behavior is deterministic.
@MainActor
final class BellHandlerThrottleTests: XCTestCase {

    private final class StubConfig: AppConfig {
        let fontName = "Menlo"
        let fontSize: CGFloat = 13
        let shellPath = "/bin/sh"
        let scrollbackLines = 0
        let terminalCols = 80
        let terminalRows = 25
        let terminalType = "xterm-256color"
        var bellBehavior: BellBehavior = .visual
        let gutterRunningAlpha: Double = 0.45
        let gutterSuccessAlpha: Double = 0.55
        let gutterFailureAlpha: Double = 0.65
        let gutterWidthPx: CGFloat = 3.0
        let gutterSeparatorEnabled = true
        let hyperlinkSchemeAllowlist: Set<String> = ["http", "https", "file"]
        let hoverMode: HoverMode = .always
    }

    private final class StubNotificationCenter: UNUserNotificationCenterAdapter {
        var requestCalls = 0
        var addCalls = 0
        func requestAuthorization(options: UNAuthorizationOptions,
                                  completionHandler: @escaping (Bool, Error?) -> Void) {
            requestCalls += 1
            completionHandler(false, nil)
        }
        func add(_ request: UNNotificationRequest,
                 withCompletionHandler completionHandler: @escaping (Error?) -> Void) {
            addCalls += 1
            completionHandler(nil)
        }
    }

    /// Manually-stepped clock; pumped from the test body so we don't depend
    /// on wall-clock pacing.
    private final class FakeClock {
        var now: UInt64 = 1_000_000_000
        func advance(byNanos delta: UInt64) { now &+= delta }
        func provider() -> () -> UInt64 {
            { [weak self] in self?.now ?? 0 }
        }
    }

    private func makeCoordinator(clock: FakeClock,
                                 config: StubConfig = StubConfig()) -> (BellCoordinator, () -> Int) {
        var fired = 0
        let coordinator = BellCoordinator(
            config: config,
            window: nil,
            view: nil,
            nowProvider: clock.provider(),
            notificationCenter: StubNotificationCenter())
        coordinator.didAttemptNotification = { fired += 1 }
        // We cannot observe `view.flashBell()` without a view, but the
        // throttle gate runs *before* any side effect, so observing the
        // notification path (or wrapping flashBell elsewhere) is unnecessary
        // for these tests — instead, we instrument fire count via a closure.
        // For visual-only behavior, swap to .visualAndNotification so each
        // accepted bell increments `fired`.
        config.bellBehavior = .visualAndNotification
        return (coordinator, { fired })
    }

    /// Forces the (`nonisolated`) `bellRequested` Task to drain. Adds a
    /// no-op MainActor hop to the back of the runloop so any in-flight
    /// `Task { @MainActor }` from the previous call lands first.
    private func drainMain() async {
        await Task.yield()
        await MainActor.run {}
    }

    func testFiresImmediatelyOnFirstBell() async throws {
        let clock = FakeClock()
        let (coordinator, firedCount) = makeCoordinator(clock: clock)

        coordinator.bellRequested()
        await drainMain()

        XCTAssertEqual(firedCount(), 1, "first bell must fire without delay")
    }

    func testSuppressesWithin200ms() async throws {
        let clock = FakeClock()
        let (coordinator, firedCount) = makeCoordinator(clock: clock)

        for _ in 0..<5 {
            coordinator.bellRequested()
            await drainMain()
            // 40 ms apart — five bells fit inside the 200 ms throttle window
            // (final call lands at t=160 ms after the first, well under 200).
            clock.advance(byNanos: 40_000_000)
        }

        XCTAssertEqual(firedCount(), 1,
                       "five bells inside the 200 ms window must collapse to one")
    }

    func testRefiresAfterWindow() async throws {
        let clock = FakeClock()
        let (coordinator, firedCount) = makeCoordinator(clock: clock)

        coordinator.bellRequested()
        await drainMain()
        XCTAssertEqual(firedCount(), 1)

        // 210 ms later — past the 200 ms throttle, second bell should land.
        clock.advance(byNanos: 210_000_000)
        coordinator.bellRequested()
        await drainMain()

        XCTAssertEqual(firedCount(), 2,
                       "second bell after the throttle window expires must fire")
    }
}
