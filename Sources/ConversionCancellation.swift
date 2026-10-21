import Foundation

/// 可由主线程取消、由转换线程检查；回调只操作本次任务拥有的子进程。
final class ConversionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }

    /// 注册与取消在同一把锁内决议，避免检查后、启动前漏掉取消。
    fileprivate func register(_ handler: @escaping () -> Void) -> UUID? {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return nil
        }
        let identifier = UUID()
        handlers[identifier] = handler
        lock.unlock()
        return identifier
    }

    fileprivate func unregister(_ identifier: UUID?) {
        guard let identifier else { return }
        lock.lock()
        handlers.removeValue(forKey: identifier)
        lock.unlock()
    }

    // 同步转换留在同一线程；只有这个调用区间中的 Shell.run 会继承 token。
    private static let contextKey = "totori.conversion-cancellation"
    static var current: ConversionCancellation? {
        Thread.current.threadDictionary[contextKey] as? ConversionCancellation
    }

    static func withCurrent<T>(_ cancellation: ConversionCancellation?,
                               perform: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[contextKey]
        if let cancellation {
            Thread.current.threadDictionary[contextKey] = cancellation
        } else {
            Thread.current.threadDictionary.removeObject(forKey: contextKey)
        }
        defer {
            if let previous {
                Thread.current.threadDictionary[contextKey] = previous
            } else {
                Thread.current.threadDictionary.removeObject(forKey: contextKey)
            }
        }
        return try perform()
    }
}

extension ConversionCancellation {
    // Shell 的注册入口为模块内部可见，取消处理不暴露到产品 UI。
    func registerProcess(_ handler: @escaping () -> Void) -> UUID? { register(handler) }
    func unregisterProcess(_ identifier: UUID?) { unregister(identifier) }
}
