import Foundation
import LevelDBTyped
import LevelDBZstd
@testable import MetaBrainCore
import Testing

@Test func searchFieldIndexTracksCurrentTitlesPathsAndCorpusCount() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await store.searchCorpusDocumentCount() == 0)
        let firstPath = try DocumentPath("/Launch/first-note")
        let first = try await store.putDocument(DocumentInput(
            path: firstPath,
            title: "Launch Launch Preview",
            body: "old words\n"
        ))
        let second = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/LAUNCH/second"),
            body: ""
        ))
        let root = try await store.putDocument(DocumentInput(path: try DocumentPath("/"), body: ""))

        #expect(try await store.searchCorpusDocumentCount() == 3)
        #expect(try await store.searchFieldDocumentIDs(matching: "lAuNcH") == [first.id, second.id])
        #expect(try await store.searchFieldDocumentIDs(matching: "preview") == [first.id])
        #expect(try await store.searchFieldDocumentIDs(matching: "first") == [first.id])
        #expect(try await store.searchFieldDocumentIDs(matching: "words").isEmpty)

        _ = try await store.writeDocument(DocumentInput(path: firstPath, title: "Final", body: first.body), ifVersion: 1)
        #expect(try await store.searchCorpusDocumentCount() == 3)
        #expect(try await store.searchFieldDocumentIDs(matching: "launch") == [first.id, second.id])
        #expect(try await store.searchFieldDocumentIDs(matching: "preview").isEmpty)
        #expect(try await store.searchFieldDocumentIDs(matching: "final") == [first.id])

        _ = try await store.patchDocument(DocumentPatchRequest(
            reference: .documentID(first.id),
            unifiedDiff: "@@ -1 +1 @@\n-old words\n+new words\n"
        ))
        let destination = try DocumentPath("/archive/finished")
        _ = try await store.moveDocument(.path(firstPath), to: destination)
        #expect(try await store.searchCorpusDocumentCount() == 3)
        #expect(try await store.searchFieldDocumentIDs(matching: "launch") == [second.id])
        #expect(try await store.searchFieldDocumentIDs(matching: "final") == [first.id])
        #expect(try await store.searchFieldDocumentIDs(matching: "finished") == [first.id])

        #expect(try await store.deleteDocument(.documentID(root.id)))
        #expect(try await store.deleteDocument(.path(destination)))
        #expect(try await store.searchCorpusDocumentCount() == 1)
        #expect(try await store.searchFieldDocumentIDs(matching: "finished").isEmpty)
        #expect(try await store.searchFieldDocumentIDs(matching: "final").isEmpty)
        #expect(try await store.searchFieldDocumentIDs(matching: "launch") == [second.id])
    }
}

@Test func searchFieldIndexBackfillsLegacyDocumentsOnce() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let legacy = try await seedSearchFieldLegacyDocument(in: store, id: "legacy", schemaVersion: 1)
        let future = try await seedSearchFieldLegacyDocument(in: store, id: "future", schemaVersion: 2)
        let futureKey = MetaBrainKeyspace.document(id: future.id)
        let savedFutureRecord = try await store.rawValue(forKey: futureKey)
        let savedVersions = try await store.listVersions(of: .documentID(legacy.id))
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.searchFieldLayout) == nil)

        async let countBeforeOrAfterWrite = store.searchCorpusDocumentCount()
        async let matched = store.searchFieldDocumentIDs(matching: "migrated")
        async let created = store.putDocument(DocumentInput(path: try DocumentPath("/after-backfill"), body: ""))
        let (documentCount, legacyMatches, newDocument) = try await (countBeforeOrAfterWrite, matched, created)

        #expect((2...3).contains(documentCount))
        #expect(legacyMatches == [legacy.id, future.id])
        #expect(try await store.searchCorpusDocumentCount() == 3)
        #expect(try await store.searchFieldDocumentIDs(matching: "backfill") == [newDocument.id])
        #expect(try await store.rawValue(forKey: futureKey) == savedFutureRecord)
        #expect(try await store.listVersions(of: .documentID(legacy.id)) == savedVersions)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.searchCorpusDocumentCount() == 3)
        #expect(try await reopened.searchFieldDocumentIDs(matching: "migrated") == [legacy.id, future.id])
    }
}

@Test func searchFieldIndexRetriesAfterFailedBackfill() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let valid = try await seedSearchFieldLegacyDocument(in: store, id: "a-valid", schemaVersion: 1)
        let unsupported = try await seedSearchFieldLegacyDocument(in: store, id: "z-unsupported", schemaVersion: 0)
        let validPostingKey = MetaBrainKeyspace.searchFieldTerm("migrated", id: valid.id)

        await #expect(throws: MetaBrainStoreError.unsupportedRecordSchemaVersion(0)) {
            try await store.searchCorpusDocumentCount()
        }
        #expect(try await store.rawValue(forKey: validPostingKey) == nil)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.searchFieldLayout) == nil)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.searchDocumentCount) == nil)

        try await store.deleteRawValue(forKey: MetaBrainKeyspace.document(id: unsupported.id))
        #expect(try await store.searchCorpusDocumentCount() == 1)
        #expect(try await store.searchFieldDocumentIDs(matching: "migrated") == [valid.id])
    }
}

@Test func searchFieldIndexPreservesUnknownLayouts() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let futureLayout = Data([2])
        let key = MetaBrainKeyspace.searchFieldLayout
        try await store.writeRawValue(futureLayout, forKey: key)
        let path = try DocumentPath("/must-remain-absent")

        await #expect(throws: MetaBrainStoreError.operationFailed(
            message: "Unrecognized search field index layout. Upgrade metaBrain to use this store's search index."
        )) {
            try await store.writeDocument(DocumentInput(path: path, body: "new"))
        }
        #expect(try await store.rawValue(forKey: key) == futureLayout)
        #expect(try await store.getDocument(.path(path), trackingRead: false) == nil)
    }
}

private struct SearchFieldLegacyDocumentRecord: Codable, Sendable {
    var document: StoredDocument
    var retention: VersionRetentionPolicy
}

private func seedSearchFieldLegacyDocument(
    in store: MetaBrainStore,
    id rawID: String,
    schemaVersion: UInt8
) async throws -> StoredDocument {
    let id = try DocumentID(rawValue: rawID)
    let path = try DocumentPath("/legacy/\(rawID)")
    let date = Date(timeIntervalSince1970: 1)
    let input = DocumentInput(path: path, title: "Migrated", body: "legacy body")
    let document = StoredDocument(
        id: id, path: path, title: input.title, body: input.body, currentVersion: 1, createdAt: date, updatedAt: date
    )
    let record = SearchFieldLegacyDocumentRecord(document: document, retention: .keepAll)
    let codec = ZstdCodec(wrapping: JSONCodec<MetaBrainRecordEnvelope<SearchFieldLegacyDocumentRecord>>())
    let data = try codec.encode(MetaBrainRecordEnvelope(schemaVersion: schemaVersion, payload: record))
    try await store.writeRawValue(data, forKey: MetaBrainKeyspace.document(id: id))
    try await store.writeRawValue(Data(id.rawValue.utf8), forKey: MetaBrainKeyspace.documentPath(path))
    let version = DocumentVersion(documentID: id, sequence: 1, snapshot: input, createdAt: date)
    try await store.putCompressedRecord(version, forKey: MetaBrainKeyspace.version(id: id, sequence: 1))
    return document
}
