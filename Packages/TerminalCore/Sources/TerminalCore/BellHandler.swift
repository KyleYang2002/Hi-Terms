import Foundation

/// Hi-Terms 内 BEL（0x07）发生时的处理协议。
///
/// 实现方一般在 UI 层（视觉闪烁 + 系统通知），保持本协议不依赖 AppKit。
/// V0.2 引入；典型实现是主线程上的 `BellCoordinator`（位于 UI 层）。
public protocol BellHandler: AnyObject {
    /// 终端发出 BEL（0x07）时调用。实现方需自行处理线程切换。
    func bellRequested()
}
