import AppKit
import UserNotifications
import TerminalCore
import Configuration

/// Owns the visual + notification side of terminal BEL handling for a single
/// window.
///
/// Wired in via `DefaultTerminalPipeline.bellHandler`. The pipeline forwards
/// `ParserAction.bell` events here on the main thread; this class then
/// consults `AppConfig.bellBehavior` and decides whether to flash the view,
/// post a system notification, or do nothing.
///
/// Throttling: BEL bursts (e.g. tab-completion noise) are coalesced inside a
/// 200 ms window. The default `nowProvider` reads `DispatchTime`; tests inject
/// a fake clock to exercise the throttle deterministically.
@MainActor
public final class BellCoordinator: BellHandler {
    public weak var window: NSWindow?
    public weak var view: TerminalView?

    private let config: AppConfig
    private let notificationCenter: UNUserNotificationCenterAdapter?
    private let nowProvider: () -> UInt64

    private var lastFiredAt: UInt64 = 0
    private static let throttleNanoseconds: UInt64 = 200_000_000

    private var notificationDenied = false
    private var notificationAuthRequested = false

    /// Test seam used by `BellCoordinatorConfigTests` to record whether the
    /// notification path was actually entered. Production builds keep it nil.
    var didAttemptNotification: (() -> Void)?

    /// Test seam: returns whether the host window/app counts as "in the
    /// foreground" for notification gating. Exposed so tests can flip it
    /// without juggling NSApp activation.
    var isForegroundProvider: (() -> Bool)?

    public init(
        config: AppConfig,
        window: NSWindow?,
        view: TerminalView?,
        nowProvider: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        notificationCenter: UNUserNotificationCenterAdapter? = LiveUserNotificationCenter()
    ) {
        self.config = config
        self.window = window
        self.view = view
        self.nowProvider = nowProvider
        self.notificationCenter = notificationCenter
    }

    /// Called by `DefaultTerminalPipeline` on every BEL. The pipeline already
    /// hops to MainActor before forwarding; this entry point is `nonisolated`
    /// only so it can be referenced from non-MainActor BellHandler callers.
    public nonisolated func bellRequested() {
        Task { @MainActor in
            self.handleOnMain()
        }
    }

    private func handleOnMain() {
        let now = nowProvider()
        if now &- lastFiredAt < Self.throttleNanoseconds {
            return
        }
        lastFiredAt = now

        switch config.bellBehavior {
        case .silent:
            return
        case .visual:
            view?.flashBell()
        case .visualAndNotification:
            view?.flashBell()
            if shouldFireNotification() {
                fireNotification()
            }
        }
    }

    /// Notification gate: only fire when the user is unlikely to see the
    /// visual flash — backgrounded app, miniaturized window, or fully
    /// occluded.
    private func shouldFireNotification() -> Bool {
        if let provider = isForegroundProvider {
            return !provider()
        }
        let appActive = NSApp?.isActive ?? false
        guard let window else { return !appActive }
        if window.isMiniaturized { return true }
        if !window.occlusionState.contains(.visible) { return true }
        return !appActive
    }

    private func fireNotification() {
        didAttemptNotification?()
        guard let center = notificationCenter else { return }

        if notificationDenied {
            NSApp?.requestUserAttention(.criticalRequest)
            return
        }

        if !notificationAuthRequested {
            notificationAuthRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.postBellNotification(via: center)
                    } else {
                        self.notificationDenied = true
                        NSApp?.requestUserAttention(.criticalRequest)
                    }
                }
            }
            return
        }

        postBellNotification(via: center)
    }

    private func postBellNotification(via center: UNUserNotificationCenterAdapter) {
        let content = UNMutableNotificationContent()
        content.title = "Hi-Terms"
        content.body = "Terminal bell"
        let request = UNNotificationRequest(
            identifier: "com.hiterms.bell.\(UUID().uuidString)",
            content: content,
            trigger: nil)
        center.add(request) { _ in }
    }
}

/// Thin protocol over `UNUserNotificationCenter` so tests can inject a stub
/// without touching the system center (which would prompt for permissions
/// during the test run).
public protocol UNUserNotificationCenterAdapter: AnyObject {
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void)
    func add(_ request: UNNotificationRequest,
             withCompletionHandler completionHandler: @escaping (Error?) -> Void)
}

/// Default adapter that forwards directly to the live system center.
public final class LiveUserNotificationCenter: UNUserNotificationCenterAdapter {
    public init() {}

    public func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: options, completionHandler: completionHandler)
    }

    public func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: @escaping (Error?) -> Void
    ) {
        UNUserNotificationCenter.current()
            .add(request, withCompletionHandler: completionHandler)
    }
}
