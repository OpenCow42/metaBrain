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
