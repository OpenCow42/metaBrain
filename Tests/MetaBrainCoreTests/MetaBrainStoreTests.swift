import Foundation
import LevelDBTyped
import LevelDBZstd
@testable import MetaBrainCore
import swift_leveldb
import Testing

private struct StoredNote: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var body: String
}

private func storeTestCodec<Value: Codable & Sendable>(
    options: MetaBrainStoreOptions,
    for type: Value.Type
) -> ZstdCodec<JSONCodec<MetaBrainRecordEnvelope<Value>>> {
    ZstdCodec(
        wrapping: JSONCodec<MetaBrainRecordEnvelope<Value>>(),
        compressionLevel: options.zstdCompressionLevel,
        storageStrategy: .adaptive(
            minimumCompressionSavingsRatio: options.zstdAdaptiveMinimumSavingsRatio
        )
    )
}

@Test func opensTemporaryMetaBrainStore() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)

        #expect(store.url == fixture.storeURL)
        #expect(FileManager.default.fileExists(atPath: fixture.storeURL.path))
    }
}

@Test func opensStoreFromStringPathAndPreservesCustomOptions() async throws {
    try await withTemporaryStoreFixture { fixture in
        let options = MetaBrainStoreOptions(
            createIfMissing: true,
            errorIfExists: false,
            zstdCompressionLevel: 5,
            zstdAdaptiveMinimumSavingsRatio: 0.25,
            lruCacheCapacity: nil,
            bloomFilterBitsPerKey: nil
        )
        let store = try MetaBrainStore(path: fixture.storeURL.path, options: options)

        #expect(store.url.path == fixture.storeURL.path)
        #expect(store.options == options)
    }
}

@Test func storeErrorsHaveActionableDescriptions() async throws {
    let path = try DocumentPath("/taken")
    let id = try DocumentID(rawValue: "doc-1")

    #expect(MetaBrainStoreError.openFailed(path: "/tmp/store", message: "locked").description == "Could not open metaBrain store at /tmp/store: locked")
    #expect(MetaBrainStoreError.operationFailed(message: "write failed").description == "LevelDB operation failed: write failed")
    #expect(MetaBrainStoreError.pathAlreadyExists(path, existingID: id).description == "Document path /taken already points to document doc-1.")
    #expect(MetaBrainStoreError.unsupportedRecordSchemaVersion(2).description == "Unsupported metaBrain record schema version: 2")
    #expect(MetaBrainStore.storeError(from: .operationFailed("boom"), path: "/tmp/store") == .operationFailed(message: "boom"))
    await #expect(throws: MetaBrainStoreError.operationFailed(message: "boom")) {
        try await MetaBrainStore.mapLevelDBErrors(path: "/tmp/store") {
            throw LevelDBError.operationFailed("boom")
        }
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

@Test func unsupportedCompressedRecordSchemaVersionThrows() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let invalidEnvelope = MetaBrainRecordEnvelope(
            schemaVersion: 2,
            payload: StoredNote(id: "note-1", title: "Bad Schema", body: "body")
        )
        let data = try storeTestCodec(options: store.options, for: StoredNote.self)
            .encode(invalidEnvelope)

        try await store.writeRawValue(data, forKey: "test/bad-schema")

        await #expect(throws: MetaBrainStoreError.unsupportedRecordSchemaVersion(2)) {
            try await store.compressedRecord(
                forKey: "test/bad-schema",
                as: StoredNote.self
            )
        }
    }
}

@Test func unsupportedVersionAndChunkSchemaVersionsThrow() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let id = try DocumentID(rawValue: "doc-1")
        let path = try DocumentPath("/bad/schema")
        let version = DocumentVersion(
            documentID: id,
            sequence: 1,
            snapshot: DocumentInput(path: path, body: "bad version"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let chunk = MetaBrainChunkRecord(
            documentID: id,
            versionSequence: 1,
            ordinal: 0,
            text: "bad chunk",
            startOffset: 0,
            endOffset: 9
        )
        let versionData = try storeTestCodec(options: store.options, for: DocumentVersion.self)
            .encode(MetaBrainRecordEnvelope(schemaVersion: 2, payload: version))
        let chunkData = try storeTestCodec(options: store.options, for: MetaBrainChunkRecord.self)
            .encode(MetaBrainRecordEnvelope(schemaVersion: 2, payload: chunk))

        try await store.writeRawValue(versionData, forKey: MetaBrainKeyspace.version(id: id, sequence: 1))
        try await store.writeRawValue(chunkData, forKey: MetaBrainKeyspace.currentChunk(id: id, ordinal: 0))

        await #expect(throws: MetaBrainStoreError.unsupportedRecordSchemaVersion(2)) {
            try await store.listVersions(of: .documentID(id))
        }
        await #expect(throws: MetaBrainStoreError.unsupportedRecordSchemaVersion(2)) {
            try await store.currentChunks(for: id)
        }
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

@Test func updateMissingReferenceCreatesDocument() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let input = DocumentInput(
            path: try DocumentPath("/created/from-missing-reference"),
            body: "created"
        )

        let document = try await store.updateDocument(
            .path(try DocumentPath("/missing/reference")),
            with: input
        )

        #expect(document.currentVersion == 1)
        #expect(document.path == input.path)
        #expect(try await store.getDocument(.path(input.path)) == document)
    }
}

@Test func putDocumentWithDanglingPathAliasCreatesFreshDocument() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let fakeID = try DocumentID(rawValue: "fake-doc")
        let path = try DocumentPath("/created/from-dangling-alias")

        try await store.writeRawValue(
            Data(fakeID.rawValue.utf8),
            forKey: MetaBrainKeyspace.documentPath(path)
        )

        let document = try await store.putDocument(DocumentInput(
            path: path,
            body: "created despite stale alias"
        ))

        #expect(document.id != fakeID)
        #expect(try await store.getDocument(.path(path)) == document)
    }
}

@Test func updatingDocumentToOccupiedPathThrowsAndPreservesAliases() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let firstPath = try DocumentPath("/notes/first")
        let secondPath = try DocumentPath("/notes/second")
        let first = try await store.putDocument(DocumentInput(
            path: firstPath,
            body: "first"
        ))
        let second = try await store.putDocument(DocumentInput(
            path: secondPath,
            body: "second"
        ))

        do {
            _ = try await store.updateDocument(
                .documentID(first.id),
                with: DocumentInput(path: secondPath, body: "conflict")
            )
            Issue.record("Expected occupied path update to fail.")
        } catch let error as MetaBrainStoreError {
            #expect(error == .pathAlreadyExists(secondPath, existingID: second.id))
        } catch {
            Issue.record("Expected MetaBrainStoreError.pathAlreadyExists, got \(error).")
        }

        #expect(try await store.getDocument(.path(firstPath)) == first)
        #expect(try await store.getDocument(.path(secondPath)) == second)
        #expect(try await store.listVersions(of: .documentID(first.id)).map(\.sequence) == [1])
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

@Test func explicitPruneCanRetainAllExistingVersions() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/retention/noop")
        let created = try await store.putDocument(DocumentInput(path: path, body: "v1"))
        _ = try await store.putDocument(DocumentInput(path: path, body: "v2"))

        let result = try await store.prune(PruneRequest(
            reference: .documentID(created.id),
            policy: .keepAll
        ))

        #expect(result == PruneResult(prunedVersionCount: 0, retainedVersionCount: 2))
        #expect(try await store.listVersions(of: .documentID(created.id)).map(\.sequence) == [1, 2])
    }
}

@Test func retentionPoliciesPreservePinnedVersions() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let keepRecentID = try DocumentID(rawValue: "pinned-recent")
        let keepWithinID = try DocumentID(rawValue: "pinned-window")
        let path = try DocumentPath("/retention/pinned")
        let oldDate = Date(timeIntervalSince1970: 0)

        for version in [
            DocumentVersion(documentID: keepRecentID, sequence: 1, snapshot: DocumentInput(path: path, body: "pinned"), createdAt: oldDate, isPinned: true),
            DocumentVersion(documentID: keepRecentID, sequence: 2, snapshot: DocumentInput(path: path, body: "middle"), createdAt: oldDate),
            DocumentVersion(documentID: keepRecentID, sequence: 3, snapshot: DocumentInput(path: path, body: "current"), createdAt: oldDate),
            DocumentVersion(documentID: keepWithinID, sequence: 1, snapshot: DocumentInput(path: path, body: "pinned"), createdAt: oldDate, isPinned: true),
            DocumentVersion(documentID: keepWithinID, sequence: 2, snapshot: DocumentInput(path: path, body: "middle"), createdAt: oldDate),
            DocumentVersion(documentID: keepWithinID, sequence: 3, snapshot: DocumentInput(path: path, body: "current"), createdAt: oldDate)
        ] {
            let data = try storeTestCodec(options: store.options, for: DocumentVersion.self)
                .encode(MetaBrainRecordEnvelope(payload: version))
            try await store.writeRawValue(
                data,
                forKey: MetaBrainKeyspace.version(id: version.documentID, sequence: version.sequence)
            )
        }

        let recentResult = try await store.prune(PruneRequest(
            reference: .documentID(keepRecentID),
            policy: .keepMostRecent(1)
        ))
        let windowResult = try await store.prune(PruneRequest(
            reference: .documentID(keepWithinID),
            policy: .keepWithin(0)
        ))

        #expect(recentResult == PruneResult(prunedVersionCount: 1, retainedVersionCount: 2))
        #expect(windowResult == PruneResult(prunedVersionCount: 1, retainedVersionCount: 2))
        #expect(try await store.listVersions(of: .documentID(keepRecentID)).map(\.sequence) == [1, 3])
        #expect(try await store.listVersions(of: .documentID(keepWithinID)).map(\.sequence) == [1, 3])
    }
}

@Test func explicitPruneOfMissingDocumentReportsZeroCounts() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)

        let result = try await store.prune(PruneRequest(
            reference: .path(try DocumentPath("/missing")),
            policy: .keepMostRecent(1)
        ))

        #expect(result == PruneResult(prunedVersionCount: 0, retainedVersionCount: 0))
        #expect(try await store.listVersions(of: .path(try DocumentPath("/missing"))) == [])
    }
}

@Test func explicitPruneOfDocumentIDWithNoVersionsReportsZeroCounts() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let missingID = try DocumentID(rawValue: "missing-id")

        let result = try await store.prune(PruneRequest(
            reference: .documentID(missingID),
            policy: .keepAll
        ))

        #expect(result == PruneResult(prunedVersionCount: 0, retainedVersionCount: 0))
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

@Test func currentVersionChunksPreserveUnicodeOffsetsAndOverlap() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = String(repeating: "é", count: 3_600)
            + String(repeating: "界", count: 400)
            + String(repeating: "🙂", count: 200)
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/index/unicode-chunks"),
            body: body
        ))

        let chunks = try await store.currentChunks(for: document.id)

        #expect(chunks.count == 2)
        #expect(chunks.map(\.ordinal) == [0, 1])
        #expect(chunks.map(\.startOffset) == [0, 3_600])
        #expect(chunks.map(\.endOffset) == [4_000, 4_200])
        #expect(chunks[0].text.count == 4_000)
        #expect(chunks[1].text.count == 600)
        #expect(chunks[0].text.suffix(400) == chunks[1].text.prefix(400))
    }
}

@Test func emptyDocumentBodyStoresCurrentEmptyChunkButNoTermIndexes() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/index/empty"),
            body: ""
        ))

        let chunks = try await store.currentChunks(for: document.id)

        #expect(chunks.count == 1)
        #expect(chunks.first?.ordinal == 0)
        #expect(chunks.first?.text == "")
        #expect(chunks.first?.startOffset == 0)
        #expect(chunks.first?.endOffset == 0)
        #expect(try await store.search(SearchQuery(text: "anything")) == [])
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

@Test func editingDocumentRemovesStaleTagAndMetadataIndexes() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/index/filter-edits")
        let created = try await store.putDocument(DocumentInput(
            path: path,
            body: "filterable content",
            tags: ["Legacy"],
            metadata: ["status": "draft"]
        ))

        _ = try await store.putDocument(DocumentInput(
            path: path,
            body: "filterable content",
            tags: ["Fresh"],
            metadata: ["status": "published"]
        ))

        #expect(try await store.documentIDs(tagged: "legacy") == [])
        #expect(try await store.documentIDs(tagged: "fresh") == [created.id])
        #expect(try await store.documentIDs(metadataKey: "status", value: "draft") == [])
        #expect(try await store.documentIDs(metadataKey: "status", value: "published") == [created.id])
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

@Test func unresolvedAndExternalReferencesDoNotCreateEdges() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let source = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/refs/unresolved-source"),
            body: "source",
            references: [
                .path(try DocumentPath("/refs/missing-target")),
                .externalURL(try #require(URL(string: "https://example.com/missing")))
            ]
        ))

        #expect(try await store.outboundReferences(from: source.id) == [])

        let target = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/refs/missing-target"),
            body: "target"
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

@Test func searchSortsTiesByDocumentIDAndChunkOrdinal() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let first = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/tie-a"),
            body: "needle"
        ))
        let second = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/tie-b"),
            body: "needle"
        ))
        let longBody = String(repeating: "filler ", count: 650) + " needle"
        let multiChunk = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/tie-c"),
            body: longBody
        ))

        let results = try await store.search(SearchQuery(text: "needle"))
        let ids = results.map(\.documentID)

        #expect(ids.contains(first.id))
        #expect(ids.contains(second.id))
        #expect(ids.contains(multiChunk.id))
        #expect(results.first { $0.documentID == multiChunk.id }?.chunkOrdinal == 1)
    }
}

@Test func searchSortsSameDocumentTieByChunkOrdinal() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = "needle " + String(repeating: "filler ", count: 650) + "needle"
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/chunk-tie"),
            body: body
        ))

        let results = try await store.search(SearchQuery(text: "needle"))

        #expect(results.filter { $0.documentID == document.id }.map(\.chunkOrdinal) == [0, 1])
    }
}

@Test func searchLimitMatchesFullSearchPrefix() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-strong"),
            body: "alpha beta alpha beta alpha"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-medium"),
            body: "alpha beta"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-weak"),
            body: "alpha only"
        ))

        let full = try await store.search(SearchQuery(text: "alpha beta", limit: 10))
        let limited = try await store.search(SearchQuery(text: "alpha beta", limit: 2))

        #expect(limited == Array(full.prefix(2)))
    }
}

@Test func searchLimitPreservesTieOrdering() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-tie-a"),
            body: "needle"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-tie-b"),
            body: "needle"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-tie-c"),
            body: "needle"
        ))

        let full = try await store.search(SearchQuery(text: "needle", limit: 10))
        let limited = try await store.search(SearchQuery(text: "needle", limit: 2))

        #expect(limited == Array(full.prefix(2)))
        #expect(limited.map(\.documentID) == Array(full.map(\.documentID).prefix(2)))
    }
}

@Test func searchLimitKeepsLaterHigherScoringChunk() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = "alpha "
            + String(repeating: "filler ", count: 700)
            + "alpha beta beta beta"
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-later-stronger"),
            body: body
        ))

        let results = try await store.search(SearchQuery(text: "alpha beta", limit: 1))

        #expect(results.map(\.documentID) == [document.id])
        #expect(results.map(\.chunkOrdinal) == [1])
    }
}

@Test func searchLimitPreservesReferenceHintsOnRetainedResults() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let target = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-target"),
            body: "target target target"
        ))
        let source = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-source"),
            body: "source source source",
            references: [.documentID(target.id)]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-source-loser"),
            body: "source"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/limit-target-loser"),
            body: "target"
        ))

        let outbound = try #require(try await store.search(SearchQuery(
            text: "source",
            includeLinkedDocuments: true,
            limit: 1
        )).first)
        let inbound = try #require(try await store.search(SearchQuery(
            text: "target",
            includeBacklinks: true,
            limit: 1
        )).first)

        #expect(outbound.documentID == source.id)
        #expect(outbound.linkedDocuments == [.documentID(target.id)])
        #expect(inbound.documentID == target.id)
        #expect(inbound.backlinks == [.documentID(source.id)])
    }
}

@Test func searchSkipsDanglingDocumentAndChunkPostings() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let fakeID = try DocumentID(rawValue: "fake-doc")
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/dangling"),
            body: "dangling"
        ))

        try await store.writeRawValue(
            Data(),
            forKey: MetaBrainKeyspace.term("ghost", id: fakeID, ordinal: 0)
        )
        try await store.writeRawValue(
            Data(),
            forKey: MetaBrainKeyspace.term("dangling", id: document.id, ordinal: 99)
        )

        #expect(try await store.search(SearchQuery(text: "ghost")) == [])
        #expect(try await store.search(SearchQuery(text: "dangling")).map(\.chunkOrdinal) == [0])
    }
}

@Test func nonTokenTermsAndExternalReferencesResolveToNoDocuments() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let url = try #require(URL(string: "https://example.com/doc"))

        #expect(try await store.documentIDs(matchingTerm: "!!!") == [])
        #expect(try await store.getDocument(.externalURL(url)) == nil)
    }
}

@Test func malformedIndexKeysUseDefensiveFallbacks() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let id = try DocumentID(rawValue: "doc-1")

        try await store.writeRawValue(Data(), forKey: MetaBrainKeyspace.tagPrefix("empty"))
        await #expect(throws: MetaBrainDomainError.invalidDocumentID("")) {
            try await store.documentIDs(tagged: "empty")
        }

        try await store.writeRawValue(Data(), forKey: MetaBrainKeyspace.termPrefix("bad"))
        await #expect(throws: MetaBrainDomainError.invalidDocumentID("")) {
            try await store.search(SearchQuery(text: "bad"))
        }

        try await store.writeRawValue(
            Data(),
            forKey: MetaBrainKeyspace.termPrefix("noordinal") + id.rawValue
        )
        try await store.writeRawValue(
            Data(),
            forKey: MetaBrainKeyspace.termPrefix("notnumber") + id.rawValue + "/not-a-number"
        )

        #expect(try await store.search(SearchQuery(text: "noordinal")) == [])
        #expect(try await store.search(SearchQuery(text: "notnumber")) == [])
    }
}

@Test func searchPathPrefixMatchesExactPathAndDescendantsOnly() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let exact = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/projects/meta"),
            body: "prefix needle"
        ))
        let child = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/projects/meta/child"),
            body: "prefix needle"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/projects/metabrain"),
            body: "prefix needle"
        ))

        let results = try await store.search(SearchQuery(
            text: "needle",
            pathPrefix: try DocumentPath("/projects/meta")
        ))

        #expect(results.map(\.documentID).sorted() == [exact.id, child.id].sorted())
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

@Test func searchIntersectsMultipleTagAndMetadataFilters() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let matching = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/filters/matching"),
            body: "multi filter needle",
            tags: ["Search", "Daily"],
            metadata: ["status": "active", "kind": "design"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/filters/tag-miss"),
            body: "multi filter needle",
            tags: ["Search"],
            metadata: ["status": "active", "kind": "design"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/filters/meta-miss"),
            body: "multi filter needle",
            tags: ["Search", "Daily"],
            metadata: ["status": "active", "kind": "draft"]
        ))

        let tagAndMetadataResults = try await store.search(SearchQuery(
            text: "needle",
            tags: ["search", "daily"],
            metadata: ["status": "active", "kind": "design"]
        ))
        let metadataOnlyResults = try await store.search(SearchQuery(
            text: "needle",
            metadata: ["status": "active"]
        ))

        #expect(tagAndMetadataResults.map(\.documentID) == [matching.id])
        #expect(metadataOnlyResults.map(\.documentID).contains(matching.id))
    }
}

@Test func searchContextSortsNeighborsAndDropsDistantChunks() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = String(repeating: "before ", count: 600)
            + "needle "
            + String(repeating: "after ", count: 600)
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/context-sort"),
            body: body
        ))

        let result = try #require(try await store.search(SearchQuery(text: "needle")).first)

        #expect(result.chunkOrdinal == 1)
        #expect(result.context.map(\.ordinal) == [0, 2])
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

@Test func searchPreservesMultiChunkResultsFiltersAndReferenceHints() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let target = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/grouped/target"),
            body: "target clue"
        ))
        let sourceBody = "needle first "
            + String(repeating: "context ", count: 650)
            + "needle second"
        let source = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/grouped/source"),
            body: sourceBody,
            tags: ["grouped"],
            metadata: ["kind": "search"],
            references: [.documentID(target.id)]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/grouped/other"),
            body: "needle filtered out",
            tags: ["grouped"],
            metadata: ["kind": "other"]
        ))

        let results = try await store.search(SearchQuery(
            text: "needle",
            pathPrefix: try DocumentPath("/grouped"),
            tags: ["grouped"],
            metadata: ["kind": "search"],
            includeLinkedDocuments: true,
            limit: 10
        ))

        #expect(results.map(\.documentID) == [source.id, source.id])
        #expect(results.map(\.chunkOrdinal) == [0, 1])
        #expect(results.allSatisfy { $0.linkedDocuments == [.documentID(target.id)] })
        #expect(results.first?.context.map(\.ordinal) == [1])
        #expect(results.last?.context.map(\.ordinal) == [0])
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

@Test func searchSkipsDanglingChunkPostingsForExistingDocuments() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/dangling-chunk"),
            body: "real content"
        ))
        try await store.writeRawValue(
            Data(),
            forKey: MetaBrainKeyspace.term("dangling", id: document.id, ordinal: 99)
        )

        let results = try await store.search(SearchQuery(text: "dangling"))

        #expect(results.isEmpty)
    }
}

@Test func searchCachesBacklinkHintsAcrossMultipleResultsForSameDocument() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let firstChunkText = "needle " + String(repeating: "alpha ", count: 700)
        let secondChunkText = "needle beta"
        let target = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/backlink-target"),
            body: firstChunkText + secondChunkText
        ))
        let source = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/search/backlink-source"),
            body: "source reference",
            references: [.documentID(target.id)]
        ))

        let results = try await store.search(SearchQuery(
            text: "needle",
            includeBacklinks: true,
            limit: 10
        ))
        let targetResults = results.filter { $0.documentID == target.id }

        #expect(targetResults.count == 2)
        #expect(targetResults.allSatisfy { $0.backlinks == [.documentID(source.id)] })
    }
}

@Test func patchDocumentUpdatesBodyAndPreservesDocumentFields() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let target = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/refs/target"),
            body: "target reference"
        ))
        let sourcePath = try DocumentPath("/notes/patch")
        let source = try await store.putDocument(DocumentInput(
            path: sourcePath,
            title: "Patchable",
            body: "alpha beta searchable\nstale term\nomega\n",
            tags: ["patch"],
            metadata: ["status": "active"],
            references: [.documentID(target.id)],
            retention: .keepAll
        ))
        let patch = """
        --- a/notes/patch
        +++ b/notes/patch
        @@ -1,3 +1,3 @@
         alpha beta searchable
        -stale term
        +fresh term
         omega
        """

        let patched = try await store.patchDocument(DocumentPatchRequest(
            reference: .path(sourcePath),
            unifiedDiff: patch
        ))

        #expect(patched.id == source.id)
        #expect(patched.path == sourcePath)
        #expect(patched.title == "Patchable")
        #expect(patched.tags == ["patch"])
        #expect(patched.metadata == ["status": "active"])
        #expect(patched.references == [.documentID(target.id)])
        #expect(patched.currentVersion == 2)
        #expect(patched.body == "alpha beta searchable\nfresh term\nomega\n")
        #expect(try await store.outboundReferences(from: source.id) == [target.id])
        #expect(try await store.search(SearchQuery(text: "fresh", tags: ["patch"])).map(\.documentID) == [source.id])
        #expect(try await store.search(SearchQuery(text: "stale")).isEmpty)

        let versions = try await store.listVersions(of: .path(sourcePath))
        #expect(versions.map(\.sequence) == [1, 2])
        #expect(versions.map(\.snapshot.body) == [
            "alpha beta searchable\nstale term\nomega\n",
            "alpha beta searchable\nfresh term\nomega\n"
        ])
    }
}

@Test func checkDocumentPatchDoesNotWriteNewVersion() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/notes/check")
        let document = try await store.putDocument(DocumentInput(
            path: path,
            body: "one\ntwo\n"
        ))
        let patch = """
        @@ -1,2 +1,2 @@
         one
        -two
        +TWO
        """

        try await store.checkDocumentPatch(DocumentPatchRequest(
            reference: .documentID(document.id),
            unifiedDiff: patch
        ))

        let fetched = try await store.getDocument(.path(path))
        let versions = try await store.listVersions(of: .path(path))
        #expect(fetched?.currentVersion == 1)
        #expect(fetched?.body == "one\ntwo\n")
        #expect(versions.map(\.sequence) == [1])
    }
}

@Test func patchDocumentAppliesRetentionAndRejectsMissingDocuments() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/notes/retained-patch")
        try await store.putDocument(DocumentInput(
            path: path,
            body: "before\n"
        ))
        let patch = """
        @@ -1 +1 @@
        -before
        +after
        """

        try await store.patchDocument(DocumentPatchRequest(
            reference: .path(path),
            unifiedDiff: patch,
            retention: .keepMostRecent(1)
        ))

        let versions = try await store.listVersions(of: .path(path))
        #expect(versions.map(\.sequence) == [2])

        await #expect(throws: MetaBrainPatchError.documentNotFound) {
            try await store.patchDocument(DocumentPatchRequest(
                reference: .path(try DocumentPath("/missing")),
                unifiedDiff: patch
            ))
        }
    }
}

@Test func listDirectoryReadsIndexedDirectRecursiveAndDirectoryOnlyEntries() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)

        #expect(try await store.listDirectory().isEmpty)

        let notes = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/notes"),
            body: "folder document"
        ))
        let today = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/notes/today"),
            body: "daily note"
        ))
        let archived = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/notes/archive/final"),
            body: "archived note"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/refs/source"),
            body: "reference note"
        ))

        let rootEntries = try await store.listDirectory()
        let notesEntry = try #require(rootEntries.first { $0.path == notes.path })
        let notesChildren = try await store.listDirectory(path: notes.path)
        let noteDirectories = try await store.listDirectory(
            path: notes.path,
            directoriesOnly: true
        )
        let recursiveNotes = try await store.listDirectory(path: notes.path, recursive: true)
        let recursiveDirectories = try await store.listDirectory(
            path: try DocumentPath("/"),
            recursive: true,
            directoriesOnly: true
        )

        #expect(rootEntries.map(\.path.rawValue) == ["/notes", "/refs"])
        #expect(notesEntry.hasChildren)
        #expect(notesEntry.documentID == notes.id)
        #expect(notesEntry.createdAt == notes.createdAt)
        #expect(notesEntry.updatedAt == notes.updatedAt)
        #expect(notesChildren.map(\.path.rawValue) == ["/notes/archive", "/notes/today"])
        #expect(notesChildren.map(\.hasChildren) == [true, false])
        #expect(noteDirectories.map(\.path.rawValue) == ["/notes/archive"])
        #expect(recursiveNotes.map(\.path.rawValue) == [
            "/notes/archive",
            "/notes/archive/final",
            "/notes/today"
        ])
        #expect(recursiveNotes.first { $0.path == today.path }?.documentID == today.id)
        #expect(recursiveNotes.first { $0.path == archived.path }?.documentID == archived.id)
        #expect(recursiveDirectories.map(\.path.rawValue) == [
            "/notes",
            "/notes/archive",
            "/refs"
        ])
    }
}

@Test func treeHonorsDepthAndDirectoryOnlyOptions() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/a/b/c"),
            body: "deep note"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/a/root"),
            body: "shallow note"
        ))

        let rootOnly = try await store.tree(TreeQuery(maxDepth: 0))
        let oneLevel = try await store.tree(TreeQuery(maxDepth: 1))
        let twoLevels = try await store.tree(TreeQuery(maxDepth: 2))
        let directoriesOnly = try await store.tree(TreeQuery(directoriesOnly: true))

        #expect(rootOnly == [])
        #expect(oneLevel.map(\.path.rawValue) == ["/a"])
        #expect(twoLevels.map(\.path.rawValue) == ["/a", "/a/b", "/a/root"])
        #expect(directoriesOnly.map(\.path.rawValue) == ["/a", "/a/b"])
    }
}

@Test func treeIndexRemovesOldEmptyAncestorsAfterRename() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let created = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/old/path/doc"),
            body: "before rename"
        ))

        let renamed = try await store.updateDocument(
            .documentID(created.id),
            with: DocumentInput(
                path: try DocumentPath("/new/path/doc"),
                body: "after rename"
            )
        )

        let rootEntries = try await store.listDirectory()
        let oldEntries = try await store.listDirectory(path: try DocumentPath("/old"), recursive: true)
        let newEntries = try await store.listDirectory(path: try DocumentPath("/new/path"))

        #expect(renamed.id == created.id)
        #expect(rootEntries.map(\.path.rawValue) == ["/new"])
        #expect(oldEntries == [])
        #expect(newEntries.map(\.path.rawValue) == ["/new/path/doc"])
        #expect(newEntries.first?.documentID == created.id)
    }
}

@Test func treeIndexPreservesSharedOldAncestorsAfterRename() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let moved = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/old/path/moved"),
            body: "move me"
        ))
        let sibling = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/old/path/sibling"),
            body: "stay here"
        ))

        _ = try await store.updateDocument(
            .documentID(moved.id),
            with: DocumentInput(
                path: try DocumentPath("/new/path/moved"),
                body: "moved"
            )
        )

        let rootEntries = try await store.listDirectory()
        let oldPathEntries = try await store.listDirectory(path: try DocumentPath("/old/path"))
        let newPathEntries = try await store.listDirectory(path: try DocumentPath("/new/path"))

        #expect(rootEntries.map(\.path.rawValue) == ["/new", "/old"])
        #expect(oldPathEntries.map(\.path.rawValue) == ["/old/path/sibling"])
        #expect(oldPathEntries.first?.documentID == sibling.id)
        #expect(newPathEntries.map(\.path.rawValue) == ["/new/path/moved"])
        #expect(newPathEntries.first?.documentID == moved.id)
    }
}

@Test func treeIndexPreservesDocumentThatIsAlsoDirectoryAfterChildRename() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let parent = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/topic"),
            body: "parent document"
        ))
        let child = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/topic/child"),
            body: "child document"
        ))

        _ = try await store.updateDocument(
            .documentID(child.id),
            with: DocumentInput(
                path: try DocumentPath("/other/child"),
                body: "moved child"
            )
        )

        let rootEntries = try await store.listDirectory()
        let topicEntries = try await store.listDirectory(path: try DocumentPath("/topic"))
        let topicEntry = try #require(rootEntries.first { $0.path == parent.path })

        #expect(rootEntries.map(\.path.rawValue) == ["/other", "/topic"])
        #expect(topicEntry.documentID == parent.id)
        #expect(!topicEntry.hasChildren)
        #expect(topicEntries == [])
    }
}

@Test func treeIndexUpdatesDocumentEntryInPlaceWithoutChangingBranches() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let original = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/same/path/doc"),
            body: "before"
        ))

        let updated = try await store.putDocument(DocumentInput(
            path: original.path,
            body: "after"
        ))
        let entries = try await store.listDirectory(path: try DocumentPath("/same/path"))

        #expect(entries.map(\.path) == [original.path])
        #expect(entries.first?.documentID == original.id)
        #expect(entries.first?.updatedAt == updated.updatedAt)
    }
}

@Test func treeIndexIgnoresMalformedDescendantPathKeys() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/corrupt")

        try await store.writeRawValue(
            Data("bad-id".utf8),
            forKey: MetaBrainKeyspace.documentPathDescendantPrefix(path) + "\u{0}"
        )
        let document = try await store.putDocument(DocumentInput(
            path: path,
            body: "before"
        ))

        let updated = try await store.putDocument(DocumentInput(
            path: document.path,
            body: "after"
        ))
        let entries = try await store.listDirectory()

        #expect(updated.id == document.id)
        #expect(entries.map(\.path) == [path])
        #expect(entries.first?.documentID == document.id)
        #expect(entries.first?.hasChildren == false)
    }
}

@Test func rootPathDocumentDoesNotCreateSyntheticTreeChild() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let root = try DocumentPath("/")
        let document = try await store.putDocument(DocumentInput(
            path: root,
            body: "root document"
        ))

        #expect(try await store.getDocument(.path(root)) == document)
        #expect(try await store.listDirectory().isEmpty)
        #expect(try await store.tree().isEmpty)
    }
}
