import Foundation
import Testing
@testable import MetaBrainCore

@Test func markdownPropertyFiltersHonorWritePatchAndMove() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/notes/policy.md")
        let yaml = """
        ---
        tags: ["on call", storage]
        reviewers:
          - Ann
          - 'Li: Operations'
        Owner: policy
        status: draft
        retries: 2
        pinned: true
        nested: {owner: hidden}
        ---
        Nightly backups.
        """
        let note = try await store.putDocument(DocumentInput(
            path: path, body: yaml, tags: ["storage"], metadata: ["OWNER": "cli"]
        ))
        func matches(_ tags: [String] = [], _ meta: [String: String] = [:]) async throws -> Bool {
            let results = try await store.search(SearchQuery(text: "nightly", tags: tags, metadata: meta))
            return results.contains { $0.documentID == note.id }
        }
        #expect(try await matches(["on call", "storage"], ["reviewers": "Li: Operations", "owner": "CLI"]))
        #expect(try await matches([], ["retries": "2", "pinned": "true"]))
        #expect(try await !matches([], ["owner": "policy"]))
        #expect(try await !matches([], ["nested": "hidden"]))

        let patch = DocumentPatchRequest(reference: .path(path), unifiedDiff: """
        @@ -7,1 +7,1 @@
        -status: draft
        +status: approved
        """)
        _ = try await store.patchDocument(patch)
        #expect(try await matches([], ["status": "approved"]))
        #expect(try await !matches([], ["status": "draft"]))
        let moved = try DocumentPath("/archive/policy.md")
        _ = try await store.moveDocument(.documentID(note.id), to: moved)
        #expect(try await matches(["on call"], ["status": "approved"]))
        _ = try await store.writeDocument(DocumentInput(path: moved, body: "Nightly backups."), bodyOnly: true)
        #expect(try await !matches(["on call"]))
        #expect(try await matches(["storage"], ["owner": "cli"]))

        let plain = try DocumentPath("/plain")
        _ = try await store.putDocument(DocumentInput(path: plain, body: yaml))
        let plainResults = try await store.search(SearchQuery(text: "nightly", tags: ["on call"]))
        #expect(plainResults.isEmpty)
        await store.close()
    }
}

@Test func existingMarkdownFiltersBackfillWithTheSearchIndex() async throws {
    try await withTemporaryStoreFixture { fixture in
        let path = try DocumentPath("/older.md")
        let store = try MetaBrainStore(url: fixture.storeURL)
        let note = try await store.putDocument(DocumentInput(
            path: path, body: "---\r\ntags: [legacy]\r\n...\r\nfindable"
        ))
        let key = MetaBrainKeyspace.tag("legacy", id: note.id)
        try await store.deleteRawValue(forKey: key)
        try await store.writeRawValue(Data([1]), forKey: MetaBrainKeyspace.searchFieldLayout)
        await store.close()
        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let hits = try await reopened.search(SearchQuery(text: "findable", tags: ["legacy"]))
        #expect(hits.map(\.documentID) == [note.id])
        #expect(try await reopened.listVersions(of: .path(path)).count == 1)
        await reopened.close()
    }
}
