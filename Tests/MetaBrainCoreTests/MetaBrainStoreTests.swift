import Foundation
@testable import MetaBrainCore
import Testing

private struct StoredNote: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var body: String
}

@Test func opensTemporaryMetaBrainStore() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)

        #expect(store.url == fixture.storeURL)
        #expect(FileManager.default.fileExists(atPath: fixture.storeURL.path))
    }
}

@Test func writesAndReadsCompressedCodableRecords() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let note = StoredNote(
            id: "note-1",
            title: "Storage",
            body: String(repeating: "compressed Codable JSON envelope ", count: 128)
        )

        try await store.putCompressedRecord(note, forKey: "test/notes/1")

        let stored = try await store.compressedRecord(
            forKey: "test/notes/1",
            as: StoredNote.self
        )
        let raw = try await store.rawValue(forKey: "test/notes/1")
        let uncompressedJSONEnvelope = try JSONEncoder().encode(
            MetaBrainRecordEnvelope(payload: note)
        )

        #expect(stored == note)
        #expect(raw != nil)
        #expect(raw != uncompressedJSONEnvelope)
    }
}

@Test func missingCompressedRecordReturnsNil() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)

        let missing = try await store.compressedRecord(
            forKey: "test/missing",
            as: StoredNote.self
        )

        #expect(missing == nil)
    }
}

@Test func openingLockedStoreSurfacesClearOpenFailure() async throws {
    try await withTemporaryStoreFixture { fixture in
        let firstStore = try MetaBrainStore(url: fixture.storeURL)
        _ = firstStore

        do {
            _ = try MetaBrainStore(url: fixture.storeURL)
            Issue.record("Expected opening an already-open LevelDB store to fail.")
        } catch let error as MetaBrainStoreError {
            guard case .openFailed(let path, let message) = error else {
                Issue.record("Expected openFailed, got \\(error).")
                return
            }

            #expect(path == fixture.storeURL.path)
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Expected MetaBrainStoreError.openFailed, got \\(error).")
        }

        #expect(firstStore.url == fixture.storeURL)
    }
}

@Test func createsDocumentAndFetchesByIDAndPath() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/notes/today")
        let input = DocumentInput(
            path: path,
            title: "Today",
            body: "First durable note",
            tags: ["daily"],
            metadata: ["source": "test"]
        )

        let created = try await store.putDocument(input)
        let byID = try await store.getDocument(.documentID(created.id))
        let byPath = try await store.getDocument(.path(path))
        let versions = try await store.listVersions(of: .documentID(created.id))

        #expect(created.path == path)
        #expect(created.currentVersion == 1)
        #expect(created.createdAt == created.updatedAt)
        #expect(byID == created)
        #expect(byPath == created)
        #expect(versions.count == 1)
        #expect(versions.first?.sequence == 1)
        #expect(versions.first?.snapshot == input)
    }
}

@Test func updatesDocumentAtSamePathAndPreservesStableID() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/notes/today")
        let created = try await store.putDocument(DocumentInput(
            path: path,
            title: "Draft",
            body: "Initial body"
        ))

        let updatedInput = DocumentInput(
            path: path,
            title: "Published",
            body: "Updated body",
            tags: ["edited"],
            metadata: ["revision": "2"]
        )
        let updated = try await store.putDocument(updatedInput)
        let versions = try await store.listVersions(of: .path(path))

        #expect(updated.id == created.id)
        #expect(updated.currentVersion == 2)
        #expect(updated.createdAt == created.createdAt)
        #expect(updated.updatedAt >= created.updatedAt)
        #expect(try await store.getDocument(.documentID(created.id)) == updated)
        #expect(versions.map(\.sequence) == [1, 2])
        #expect(versions.last?.snapshot == updatedInput)
    }
}

@Test func renamesDocumentPathAliasWithoutChangingID() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let oldPath = try DocumentPath("/notes/draft")
        let newPath = try DocumentPath("/notes/archive/final")
        let created = try await store.putDocument(DocumentInput(
            path: oldPath,
            title: "Draft",
            body: "Before rename"
        ))

        let renamed = try await store.updateDocument(
            .documentID(created.id),
            with: DocumentInput(
                path: newPath,
                title: "Final",
                body: "After rename"
            )
        )

        #expect(renamed.id == created.id)
        #expect(renamed.path == newPath)
        #expect(renamed.currentVersion == 2)
        #expect(try await store.getDocument(.path(oldPath)) == nil)
        #expect(try await store.getDocument(.path(newPath)) == renamed)
        #expect(try await store.getDocument(.documentID(created.id)) == renamed)
    }
}

@Test func keepAllRetentionPreservesEveryFullSnapshotVersion() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/retention/all")
        let created = try await store.putDocument(DocumentInput(
            path: path,
            body: "v1",
            retention: .keepAll
        ))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v2"))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v3"))

        let versions = try await store.listVersions(of: .documentID(created.id))

        #expect(versions.map(\.sequence) == [1, 2, 3])
        #expect(versions.map(\.snapshot.body) == ["v1", "v2", "v3"])
    }
}

@Test func keepMostRecentRetentionPrunesOnWrite() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/retention/last")
        let created = try await store.putDocument(DocumentInput(
            path: path,
            body: "v1",
            retention: .keepMostRecent(2)
        ))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v2"))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v3"))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v4"))

        let versions = try await store.listVersions(of: .documentID(created.id))

        #expect(versions.map(\.sequence) == [3, 4])
        #expect(versions.map(\.snapshot.body) == ["v3", "v4"])
    }
}

@Test func timeWindowRetentionKeepsCurrentVersionAndPrunesOlderSnapshots() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/retention/window")
        let created = try await store.putDocument(DocumentInput(
            path: path,
            body: "old",
            retention: .keepWithin(0)
        ))
        _ = try await store.putDocument(DocumentInput(path: path, body: "current"))

        let versions = try await store.listVersions(of: .documentID(created.id))

        #expect(versions.map(\.sequence) == [2])
        #expect(versions.map(\.snapshot.body) == ["current"])
    }
}

@Test func explicitPruneAppliesRetentionPolicyToExistingVersions() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/retention/manual")
        let created = try await store.putDocument(DocumentInput(path: path, body: "v1"))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v2"))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v3"))

        let result = try await store.prune(PruneRequest(
            reference: .documentID(created.id),
            policy: .keepMostRecent(1)
        ))
        let versions = try await store.listVersions(of: .documentID(created.id))

        #expect(result.prunedVersionCount == 2)
        #expect(result.retainedVersionCount == 1)
        #expect(versions.map(\.sequence) == [3])
        #expect(versions.map(\.snapshot.body) == ["v3"])
    }
}

@Test func currentVersionChunksIncludeConfiguredOverlap() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = String(repeating: "a", count: 3_600)
            + String(repeating: "b", count: 400)
            + String(repeating: "c", count: 200)
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/index/chunks"),
            body: body
        ))

        let chunks = try await store.currentChunks(for: document.id)

        #expect(chunks.count == 2)
        #expect(chunks.map(\.ordinal) == [0, 1])
        #expect(chunks[0].startOffset == 0)
        #expect(chunks[0].endOffset == 4_000)
        #expect(chunks[1].startOffset == 3_600)
        #expect(chunks[1].endOffset == 4_200)
        #expect(chunks[0].text.suffix(400) == chunks[1].text.prefix(400))
    }
}

@Test func tokenizationLowercasesTermsAndSplitsOnPunctuation() {
    #expect(MetaBrainStore.tokenize("Swift, SWIFT! café-42/path") == [
        "swift",
        "swift",
        "café",
        "42",
        "path"
    ])
}

@Test func editingDocumentReplacesCurrentTermIndexes() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/index/terms")
        let created = try await store.putDocument(DocumentInput(
            path: path,
            body: "legacy-only term survives nowhere"
        ))

        #expect(try await store.documentIDs(matchingTerm: "legacy") == [created.id])
        #expect(try await store.documentIDs(matchingTerm: "fresh") == [])

        let updated = try await store.putDocument(DocumentInput(
            path: path,
            body: "fresh searchable term"
        ))

        #expect(updated.id == created.id)
        #expect(try await store.documentIDs(matchingTerm: "legacy") == [])
        #expect(try await store.documentIDs(matchingTerm: "fresh") == [created.id])
    }
}

@Test func tagAndMetadataIndexesCanBeScanned() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let first = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/index/first"),
            body: "first",
            tags: ["Swift Notes", "Daily"],
            metadata: ["source/type": "Daily Note", "status": "draft"]
        ))
        let second = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/index/second"),
            body: "second",
            tags: ["Daily"],
            metadata: ["status": "draft"]
        ))

        #expect(try await store.documentIDs(tagged: "swift notes") == [first.id])
        #expect(try await store.documentIDs(tagged: "daily") == [first.id, second.id].sorted())
        #expect(try await store.documentIDs(metadataKey: "source/type", value: "daily note") == [first.id])
        #expect(try await store.documentIDs(metadataKey: "status", value: "draft") == [first.id, second.id].sorted())
    }
}

@Test func referencesCreateOutboundAndInboundIndexRecords() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let targetPath = try DocumentPath("/refs/target")
        let target = try await store.putDocument(DocumentInput(
            path: targetPath,
            body: "target"
        ))
        let source = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/refs/source"),
            body: "source",
            references: [
                .documentID(target.id),
                .path(targetPath),
                .externalURL(try #require(URL(string: "https://example.com/reference")))
            ]
        ))

        #expect(try await store.outboundReferences(from: source.id) == [target.id])
        #expect(try await store.inboundReferences(to: target.id) == [source.id])

        _ = try await store.putDocument(DocumentInput(
            path: source.path,
            body: "source without refs"
        ))

        #expect(try await store.outboundReferences(from: source.id) == [])
        #expect(try await store.inboundReferences(to: target.id) == [])
    }
}

@Test func searchRanksMultiTermMatchesByCoverageFrequencyAndLocality() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let strong = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/strong"),
            title: "Strong",
            body: "alpha beta alpha beta alpha"
        ))
        let weak = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/weak"),
            title: "Weak",
            body: "alpha alpha scattered"
        ))

        let results = try await store.search(SearchQuery(text: "alpha beta"))

        #expect(results.map(\.documentID).contains(strong.id))
        #expect(results.map(\.documentID).contains(weak.id))
        #expect(results.first?.documentID == strong.id)
        #expect((results.first?.score ?? 0) > (results.last?.score ?? 0))
    }
}

@Test func searchAppliesPathTagAndMetadataFilters() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let matching = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/projects/metabrain/search"),
            body: "lexical context retrieval",
            tags: ["Search"],
            metadata: ["status": "active", "kind": "design"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/projects/other/search"),
            body: "lexical context retrieval",
            tags: ["Search"],
            metadata: ["status": "active", "kind": "design"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/projects/metabrain/draft"),
            body: "lexical context retrieval",
            tags: ["Draft"],
            metadata: ["status": "active", "kind": "design"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/projects/metabrain/archived"),
            body: "lexical context retrieval",
            tags: ["Search"],
            metadata: ["status": "archived", "kind": "design"]
        ))

        let results = try await store.search(SearchQuery(
            text: "lexical retrieval",
            pathPrefix: try DocumentPath("/projects/metabrain"),
            tags: ["search"],
            metadata: ["status": "active", "kind": "design"]
        ))

        #expect(results.map(\.documentID) == [matching.id])
        #expect(results.first?.path == matching.path)
    }
}

@Test func searchReturnsNeighboringContextChunks() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let firstChunkText = String(repeating: "first context ", count: 340)
        let secondChunkText = "needle second context"
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/context"),
            body: firstChunkText + secondChunkText
        ))

        let result = try #require(try await store.search(SearchQuery(text: "needle")).first)

        #expect(result.documentID == document.id)
        #expect(result.chunkOrdinal == 1)
        #expect(result.snippet.contains("needle"))
        #expect(result.context.map(\.ordinal) == [0])
        #expect(result.context[0].text.contains("first context"))
    }
}

@Test func searchCanIncludeLinkedDocumentAndBacklinkHints() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let target = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/target"),
            body: "target clue"
        ))
        let source = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/source"),
            body: "source clue",
            references: [.documentID(target.id)]
        ))

        let outbound = try #require(try await store.search(SearchQuery(
            text: "source",
            includeLinkedDocuments: true
        )).first)
        let inbound = try #require(try await store.search(SearchQuery(
            text: "target",
            includeBacklinks: true
        )).first)

        #expect(outbound.documentID == source.id)
        #expect(outbound.linkedDocuments == [.documentID(target.id)])
        #expect(inbound.documentID == target.id)
        #expect(inbound.backlinks == [.documentID(source.id)])
    }
}

@Test func searchReturnsNoResultsForMissingTermsAndEmptyQueries() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/no-results"),
            body: "indexed content"
        ))

        #expect(try await store.search(SearchQuery(text: "absent")) == [])
        #expect(try await store.search(SearchQuery(text: "   ")) == [])
        #expect(try await store.search(SearchQuery(text: "indexed", limit: 0)) == [])
    }
}
