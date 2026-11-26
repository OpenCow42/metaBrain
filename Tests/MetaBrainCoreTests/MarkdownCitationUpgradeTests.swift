import Foundation
import Testing
@testable import MetaBrainCore

@Test func citationUpgradeRepairsBothDirectionsAndPreservesHistoricalBindings() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let moved = try await store.putDocument(DocumentInput(path: DocumentPath("/moved.md"), body: "Original."))
        let deleted = try await store.putDocument(DocumentInput(path: DocumentPath("/deleted.md"), body: "Original."))
        let found = try await store.putDocument(DocumentInput(path: DocumentPath("/found.md"), body: "Newly visible."))
        let body = "[[moved]] [[deleted]] [[found]]\n" + "\u{60}[[literal]]\u{60}"
        let source = try await store.putDocument(DocumentInput(path: DocumentPath("/source.md"), body: body))
        let ref = DocumentReference.documentID(source.id)
        let archived = try DocumentPath("/archive/old.md")
        _ = try await store.moveDocument(.documentID(moved.id), to: archived)
        #expect(try await store.deleteDocument(.documentID(deleted.id)))
        let reusedMove = try await store.putDocument(DocumentInput(path: moved.path, body: "Replacement."))
        let reusedDelete = try await store.putDocument(DocumentInput(path: deleted.path, body: "Replacement."))

        // Recreate the previous index's two possible parsing mistakes: it missed a real
        // occurrence, and gave a literal an outgoing row and a matching backlink.
        let before = try await store.links(for: ref)
        let missed = try #require(before.first { $0.targetID == found.id })
        let outKey = MetaBrainKeyspace.citationOutPrefix(source.id) + String(missed.start)
        let missedRow = try #require(try await store.compressedRecord(forKey: outKey, as: MarkdownCitation.self))
        try await store.deleteRawValue(forKey: outKey)
        for key in missedRow.secondaryKeys { try await store.deleteRawValue(forKey: key) }
        let start = try #require(body.range(of: "[[literal]]")).lowerBound
        let offset = body.distance(from: body.startIndex, to: start)
        let literal = MarkdownLink(
            syntax: .wiki, start: offset, end: offset + "[[literal]]".count,
            snippet: "[[literal]]", label: nil, destination: "literal", embed: nil
        )
        let stale = MarkdownCitation(
            sourceID: source.id, sourcePath: source.path, sourceVersion: source.currentVersion,
            link: literal, targetID: found.id, status: .resolved
        )
        try await store.putCompressedRecord(stale, forKey: stale.key)
        for key in stale.secondaryKeys { try await store.writeRawValue(Data(), forKey: key) }
        try await store.writeRawValue(Data([1]), forKey: MetaBrainKeyspace.citationLayout)
        let versions = try await store.listVersions(of: ref)
        await store.close()

        let upgraded = try MetaBrainStore(url: fixture.storeURL)
        let links = try await upgraded.links(for: ref)
        #expect(links == before)
        #expect(links.map(\.targetID) == [moved.id, nil, found.id])
        #expect(links.map(\.targetPath) == [archived, nil, found.path])
        #expect(links.map(\.status) == [.resolved, .unresolved, .resolved])
        #expect(try await upgraded.links(for: .documentID(found.id), direction: .incoming) == [missed])
        for replacement in [reusedMove, reusedDelete] {
            #expect(try await upgraded.links(for: .documentID(replacement.id), direction: .incoming).isEmpty)
        }
        #expect(try await upgraded.rawValue(forKey: stale.key) == nil)
        for key in stale.secondaryKeys { #expect(try await upgraded.rawValue(forKey: key) == nil) }
        #expect(try await upgraded.listVersions(of: ref) == versions)
        #expect(try await upgraded.rawValue(forKey: MetaBrainKeyspace.citationLayout) == Data([3]))
        await upgraded.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.links(for: ref) == links)
    }
}

@Test func unknownCitationLayoutLeavesDocumentsAndMarkerIntact() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(path: DocumentPath("/source.md"), body: "[[a]]"))
        let ref = DocumentReference.documentID(document.id)
        let future = Data([255])
        try await store.writeRawValue(future, forKey: MetaBrainKeyspace.citationLayout)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let error = MetaBrainStoreError.operationFailed(message: "Unrecognized Markdown citation index layout.")
        await #expect(throws: error) { try await reopened.links(for: ref) }
        await #expect(throws: error) {
            try await reopened.putDocument(DocumentInput(path: document.path, body: "[[b]]"))
        }
        #expect(try await reopened.rawValue(forKey: MetaBrainKeyspace.citationLayout) == future)
        #expect(try await reopened.getDocument(ref, trackingRead: false) == document)
    }
}

@Test func failedCitationUpgradeCanRetryWithoutLosingTheOldBacklink() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let target = try await store.putDocument(DocumentInput(path: DocumentPath("/target.md"), body: "Target."))
        let source = try await store.putDocument(DocumentInput(path: DocumentPath("/source.md"), body: "See [[target]]."))
        let ref = DocumentReference.documentID(source.id)
        let occurrence = try #require(try await store.links(for: ref).first)
        let primary = MetaBrainKeyspace.citationOutPrefix(source.id) + String(occurrence.start)
        let secondary = MetaBrainKeyspace.citationInPrefix(target.id) + source.id.rawValue + "/" + String(occurrence.start)
        let original = try #require(try await store.rawValue(forKey: primary))
        try await store.writeRawValue(Data([1]), forKey: MetaBrainKeyspace.citationLayout)
        try await store.writeRawValue(Data("incomplete row".utf8), forKey: primary)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        await #expect(throws: (any Error).self) { try await reopened.links(for: ref) }
        #expect(try await reopened.rawValue(forKey: MetaBrainKeyspace.citationLayout) == Data([1]))
        #expect(try await reopened.rawValue(forKey: secondary) == Data())
        try await reopened.writeRawValue(original, forKey: primary)
        #expect(try await reopened.links(for: .documentID(target.id), direction: .incoming) == [occurrence])
        #expect(try await reopened.rawValue(forKey: MetaBrainKeyspace.citationLayout) == Data([3]))
    }
}
