import Foundation
import Testing
@testable import MetaBrainCore

@Test func historicalDocumentReadsKeepTheRevisionSnapshotAfterEditsAndMoves() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let originalPath = try DocumentPath("/notes/original")
        let movedPath = try DocumentPath("/archive/moved")
        let first = try await store.putDocument(DocumentInput(
            path: originalPath,
            title: "Original title",
            body: "original body",
            tags: ["original"],
            metadata: ["state": "draft"],
            references: [.path(try DocumentPath("/notes/original-reference"))]
        ))
        let reference = DocumentReference.documentID(first.id)
        let second = try await store.putDocument(DocumentInput(
            path: originalPath,
            title: "Revised title",
            body: "revised body",
            tags: ["revised"],
            metadata: ["state": "done"],
            references: [.path(try DocumentPath("/notes/revised-reference"))]
        ))
        let move = try await store.moveDocument(reference, to: movedPath)

        #expect(try await store.getDocument(reference, version: 1) == first)
        #expect(try await store.getDocument(reference, version: 2) == second)
        #expect(try await store.getDocument(reference, version: 3) == move.document)
        #expect(try await store.getDocument(.path(movedPath), version: 1) == first)
        #expect(try await store.getDocument(.path(originalPath), version: 1) == nil)
        #expect(try await store.getDocument(reference, version: 4) == nil)
        #expect(try await store.entryMetadata(for: reference)?.access.readCount == 0)

        let result = try await store.prune(PruneRequest(reference: reference, policy: .keepMostRecent(2)))
        #expect(result.prunedVersionCount == 1)
        #expect(try await store.getDocument(reference, version: 1) == nil)
        #expect(try await store.getDocument(reference, version: 2) == second)
    }
}

@Test func historicalDocumentReadOnlyLoadsTheRequestedRevision() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(
            path: DocumentPath("/notes/original"), body: "original body"
        ))
        try await store.writeRawValue(
            Data("unreadable unrelated revision".utf8),
            forKey: MetaBrainKeyspace.version(id: document.id, sequence: 2)
        )
        let reference = DocumentReference.documentID(document.id)

        #expect(try await store.getDocument(reference, version: 1) == document)
        await #expect(throws: MetaBrainStoreError.invalidDocumentVersion(0)) {
            try await store.getDocument(reference, version: 0)
        }
    }
}
