import Foundation

/// 让异步回调只生效一次的容器。
///
/// PhotoKit 的回调（尤其是 `requestLivePhoto`）可能先给低清结果、
/// 再给高清结果，直接用它 resume continuation 会因为二次恢复而崩溃。
final class OnceBox: @unchecked Sendable {
    private var hasFired = false
    private let lock = NSLock()

    /// 返回 true 表示这是第一次调用，调用方可以安全地 resume。
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFired else { return false }
        hasFired = true
        return true
    }
}
