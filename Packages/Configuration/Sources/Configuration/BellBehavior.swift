import Foundation

/// 终端 BEL（0x07）的处理策略。
///
/// - `silent`: 完全忽略
/// - `visual`: 仅做视觉提示（窗口闪烁等）
/// - `visualAndNotification`: 视觉提示 + 系统通知
public enum BellBehavior: String, Sendable, CaseIterable {
    case silent
    case visual
    case visualAndNotification
}
