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
