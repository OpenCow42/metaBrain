import Dispatch
import Foundation

public final class ServerRequestLimiter: @unchecked Sendable {
    public let maximumConcurrentRequests: Int
    public let maximumQueuedRequests: Int

    private enum Admission {
        case immediate
        case queued
        case rejected
    }

    private let lock = NSLock()
    private var activeRequests = 0
    private var pending: [@Sendable () -> Void] = []

    public init(maximumConcurrentRequests: Int, maximumQueuedRequests: Int = 0) {
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumQueuedRequests = maximumQueuedRequests
    }

    public var activeRequestCount: Int {
        lock.withLock { activeRequests }
    }

    public var queuedRequestCount: Int {
        lock.withLock { pending.count }
    }

    public func tryAcquire() -> Bool {
        let accepted = DispatchSemaphore(value: 0)
        switch reserve({ accepted.signal() }) {
        case .immediate:
            return true
        case .queued:
            accepted.wait()
            return true
        case .rejected:
            return false
        }
    }

    // An admitted operation owns one permit until it calls release.
    // Queued operations wait here without occupying a worker thread.
    func submit(_ start: @escaping @Sendable () -> Void) -> Bool {
        switch reserve(start) {
        case .immediate:
            start()
            return true
        case .queued:
            return true
        case .rejected:
            return false
        }
    }

    public func release() {
        let next: (@Sendable () -> Void)? = lock.withLock {
            guard activeRequests > 0 else {
                return nil
            }
            if !pending.isEmpty {
                // Transfer the active permit directly to the next queued operation.
                return pending.removeFirst()
            }
            activeRequests -= 1
            return nil
        }
        next?()
    }

    private func reserve(_ start: @escaping @Sendable () -> Void) -> Admission {
        lock.withLock {
            if activeRequests < maximumConcurrentRequests {
                activeRequests += 1
                return .immediate
            }
            guard pending.count < maximumQueuedRequests else {
                return .rejected
            }
            pending.append(start)
            return .queued
        }
    }
}
