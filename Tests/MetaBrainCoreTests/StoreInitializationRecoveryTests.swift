import Foundation
import Testing
@testable import MetaBrainCore

@Test func failedGuideSeedReleasesStoreWhileFailedHandleIsRetained() async throws {
    enum SeedFailure: Error {
        case interrupted
    }

    try await withTemporaryStoreFixture { fixture in
        var failedStore: MetaBrainStore?
        do {
            _ = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: false) { store in
                failedStore = store
                throw SeedFailure.interrupted
            }
            Issue.record("Expected initialization to propagate its seeding error.")
        } catch SeedFailure.interrupted {
            let failed = try #require(failedStore)
            await #expect(throws: MetaBrainStoreError.operationFailed(message: "metaBrain store is closed.")) {
                try await failed.rawValue(forKey: MetaBrainKeyspace.treeLayout)
            }

            let reopened = try MetaBrainStore(url: fixture.storeURL)
            let restored = try await reopened.ensureAgentGuide()
            #expect(restored.status == .created)
            #expect(restored.document.path == MetaBrainAgentGuide.document.path)
        }
    }
}
