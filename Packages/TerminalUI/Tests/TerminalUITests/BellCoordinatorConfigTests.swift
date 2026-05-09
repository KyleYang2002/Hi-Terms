import XCTest
import AppKit
import UserNotifications
import TerminalCore
import Configuration
@testable import TerminalUI

/// Wave 2-C: verifies `BellCoordinator` honors `AppConfig.bellBehavior` and
/// gates notifications on app foreground state. Uses injected dependencies
/// (clock, notification adapter, foreground provider) for hermetic runs.
@MainActor
final class BellCoordinatorConfigTests: XCTestCase {

    private final class StubConfig: AppConfig {
        let fontName = "Menlo"
        let fontSize: CGFloat = 13
        let shellPath = "/bin/sh"
        let scrollbackLines = 0
        let terminalCols = 80
        let terminalRows = 25
        let terminalType = "xterm-256color"
        var bellBehavior: BellBehavior

        init(bellBehavior: BellBehavior) {
            self.bellBehavior = bellBehavior
        }
    }

    private final class StubNotificationCenter: UNUserNotificationCenterAdapter {
        var requestCalls = 0
        var addCalls = 0
        var grant = false
        func requestAuthorization(options: UNAuthorizationOptions,
                                  completionHandler: @escaping (Bool, Error?) -> Void) {
            requestCalls += 1
            completionHandler(grant, nil)
        }
        func add(_ request: UNNotificationRequest,
                 withCompletionHandler completionHandler: @escaping (Error?) -> Void) {
            addCalls += 1
            completionHandler(nil)
        }
    }

    private func drainMain() async {
        await Task.yield()
        await MainActor.run {}
    }

    private func makeCoordinator(behavior: BellBehavior,
                                 isForeground: Bool = true,
                                 nowProvider: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds })
        -> (BellCoordinator, StubNotificationCenter, () -> Int) {
        let center = StubNotificationCenter()
        let coordinator = BellCoordinator(
            config: StubConfig(bellBehavior: behavior),
            window: nil,
            view: nil,
            nowProvider: nowProvider,
            notificationCenter: center)
        coordinator.isForegroundProvider = { isForeground }
        var attempts = 0
        coordinator.didAttemptNotification = { attempts += 1 }
        return (coordinator, center, { attempts })
    }

    func testSilentSkipsBoth() async throws {
        let (coordinator, center, attempts) = makeCoordinator(behavior: .silent,
                                                              isForeground: false)

        coordinator.bellRequested()
        await drainMain()

        XCTAssertEqual(attempts(), 0,
                       ".silent must not enter the notification path")
        XCTAssertEqual(center.requestCalls, 0)
        XCTAssertEqual(center.addCalls, 0)
    }

    func testVisualOnlySkipsNotification() async throws {
        let (coordinator, center, attempts) = makeCoordinator(behavior: .visual,
                                                              isForeground: false)

        coordinator.bellRequested()
        await drainMain()

        XCTAssertEqual(attempts(), 0,
                       ".visual must skip the notification path even when backgrounded")
        XCTAssertEqual(center.requestCalls, 0)
        XCTAssertEqual(center.addCalls, 0)
    }

    func testNotificationGatedByForeground() async throws {
        let (coordinator, _, attempts) =
            makeCoordinator(behavior: .visualAndNotification, isForeground: true)

        coordinator.bellRequested()
        await drainMain()

        XCTAssertEqual(attempts(), 0,
                       "while in the foreground, no notification should be posted")
    }

    func testNotificationFiresWhenBackgrounded() async throws {
        let (coordinator, _, attempts) =
            makeCoordinator(behavior: .visualAndNotification, isForeground: false)

        coordinator.bellRequested()
        await drainMain()

        XCTAssertEqual(attempts(), 1,
                       "when backgrounded, the bell should attempt a notification")
    }
}
