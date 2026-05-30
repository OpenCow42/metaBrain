import Foundation

public final class ServerRequestLimiter: @unchecked Sendable {
    public let maximumConcurrentRequests: Int
    public let maximumQueuedRequests: Int

    private let condition = NSCondition()
    private var activeRequests = 0
    private var queuedRequests = 0

    public init(maximumConcurrentRequests: Int, maximumQueuedRequests: Int = 0) {
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumQueuedRequests = maximumQueuedRequests
    }

    public var activeRequestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeRequests
    }

    public var queuedRequestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return queuedRequests
    }

    public func tryAcquire() -> Bool {
        condition.lock()
        defer { condition.unlock() }

        if activeRequests < maximumConcurrentRequests, queuedRequests == 0 {
            activeRequests += 1
            return true
        }

        guard queuedRequests < maximumQueuedRequests else {
            return false
        }

        queuedRequests += 1
        while activeRequests >= maximumConcurrentRequests {
            condition.wait()
        }
        queuedRequests -= 1

        activeRequests += 1
        return true
    }

    public func release() {
        condition.lock()
        defer { condition.unlock() }

        if activeRequests > 0 {
            activeRequests -= 1
            condition.signal()
        }
    }
}
