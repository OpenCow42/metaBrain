import Dispatch
import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func requestLimiterTracksAvailablePermits() {
    let limiter = ServerRequestLimiter(maximumConcurrentRequests: 2)

    #expect(limiter.maximumConcurrentRequests == 2)
    #expect(limiter.maximumQueuedRequests == 0)
    #expect(limiter.tryAcquire())
    #expect(limiter.tryAcquire())
    #expect(!limiter.tryAcquire())
    #expect(limiter.activeRequestCount == 2)
    #expect(limiter.queuedRequestCount == 0)

    limiter.release()
    #expect(limiter.tryAcquire())
    limiter.release()
    limiter.release()
    #expect(limiter.activeRequestCount == 0)
}

@Test func requestLimiterIgnoresExtraReleases() {
    let limiter = ServerRequestLimiter(maximumConcurrentRequests: 1)

    limiter.release()
    #expect(limiter.tryAcquire())
    #expect(!limiter.tryAcquire())
}

@Test func requestLimiterQueuesUntilPermitIsReleased() {
    let limiter = ServerRequestLimiter(maximumConcurrentRequests: 1, maximumQueuedRequests: 1)
    let queued = DispatchSemaphore(value: 0)
    let acquired = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    #expect(limiter.tryAcquire())

    DispatchQueue.global(qos: .userInitiated).async {
        queued.signal()
        #expect(limiter.tryAcquire())
        acquired.signal()
        finished.wait()
        limiter.release()
    }

    #expect(queued.wait(timeout: .now() + 5) == .success)
    let queueDeadline = Date().addingTimeInterval(5)
    while limiter.queuedRequestCount == 0, Date() < queueDeadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
    #expect(limiter.queuedRequestCount == 1)
    #expect(!limiter.tryAcquire())
    #expect(acquired.wait(timeout: .now() + 0.05) == .timedOut)

    limiter.release()
    #expect(acquired.wait(timeout: .now() + 5) == .success)
    #expect(limiter.activeRequestCount == 1)

    finished.signal()
    let finishDeadline = Date().addingTimeInterval(5)
    while limiter.activeRequestCount != 0, Date() < finishDeadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
    #expect(limiter.activeRequestCount == 0)
}
