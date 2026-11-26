import Foundation
import Testing
@testable import MetaBrainCore

@Test func ensureGuideCreatesOnceAndPreservesCustomizedInstructions() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: true)
        let statuses = try await withThrowingTaskGroup(of: DocumentWriteStatus.self) { group in
            for _ in 0..<12 { group.addTask { try await store.ensureAgentGuide().status } }
            var statuses: [DocumentWriteStatus] = []
            for try await status in group { statuses.append(status) }
            return statuses
        }
        #expect(statuses.filter { $0 == .created }.count == 1)
        #expect(statuses.filter { $0 == .unchanged }.count == 11)
        let initial = try await store.ensureAgentGuide().document
        #expect(initial.body.contains("--view evidence"))
        #expect(initial.body.contains("mb lint /decisions"))
        #expect(initial.body.contains("mb operation inspect"))
        #expect(initial.body.contains("$metabrain-wiki"))
        #expect(initial.body.contains("/metabrain-wiki"))
        #expect(initial.body.contains("metabrain-wiki-ingest"))
        #expect(initial.body.contains("mb preview /projects/atlas/decisions.base"))
        #expect(initial.metadata["guide-revision"] == "10")
        let custom = try await store.putDocument(DocumentInput(path: initial.path, body: "Project instructions."))
        let preserved = try await store.ensureAgentGuide()
        #expect(preserved.document == custom)
        #expect(preserved.status == .unchanged)
        #expect(try await store.listVersions(of: .documentID(initial.id)).count == 2)
        await store.close()
    }
}
