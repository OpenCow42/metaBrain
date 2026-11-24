import Foundation
import Testing
@testable import MetaBrainCore

@Test func storageRejectsUnsupportedTreeLayoutAndCanRetryAfterRepair() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/wiki/note.md")
        let document = try await store.putDocument(DocumentInput(path: path, body: "Original"))
        let key = MetaBrainKeyspace.treeLayout
        let supported = try #require(try await store.rawValue(forKey: key))
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let future = Data([255])
        try await reopened.writeRawValue(future, forKey: key)
        await #expect(throws: MetaBrainStoreError.operationFailed(
            message: "Unrecognized tree index layout. Upgrade metaBrain to use this store's tree."
        )) {
            try await reopened.tree()
        }
        #expect(try await reopened.rawValue(forKey: key) == future)
        try await reopened.writeRawValue(supported, forKey: key)
        #expect(try await reopened.tree().last?.documentID == document.id)
    }
}

@Test func storageDetectsPartialSearchIndexAndRebuildsAfterRepair() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(
            path: DocumentPath("/record"), body: "Searchable"
        ))
        try await store.deleteRawValue(forKey: MetaBrainKeyspace.searchFieldLayout)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        await #expect(throws: MetaBrainStoreError.operationFailed(
            message: "Search field index exists without its layout marker."
        )) {
            try await reopened.searchCorpusDocumentCount()
        }
        #expect(try await reopened.getDocument(.documentID(document.id), trackingRead: false) == document)
        try await reopened.deleteRawValue(forKey: MetaBrainKeyspace.searchDocumentCount)
        try await reopened.deleteRawValue(forKey: MetaBrainKeyspace.searchFieldTerm("record", id: document.id))
        #expect(try await reopened.searchCorpusDocumentCount() == 1)
        #expect(try await reopened.searchFieldDocumentIDs(matching: "record") == [document.id])
    }
}

@Test func storageRejectsInvalidSearchCountWithoutCommittingDocumentWrites() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/new")
        let input = DocumentInput(path: path, body: "Proposed")
        #expect(try await store.searchCorpusDocumentCount() == 0)
        let countKey = MetaBrainKeyspace.searchDocumentCount

        try await store.writeRawValue(Data("invalid".utf8), forKey: countKey)
        await #expect(throws: MetaBrainStoreError.operationFailed(
            message: "Missing or invalid search corpus document count."
        )) {
            try await store.putDocument(input)
        }

        try await store.writeRawValue(Data(String(Int.max).utf8), forKey: countKey)
        await #expect(throws: MetaBrainStoreError.operationFailed(
            message: "Invalid search corpus document count adjustment."
        )) {
            try await store.putDocument(input)
        }
        #expect(try await store.getDocument(.path(path), trackingRead: false) == nil)
        #expect(try await store.tree().isEmpty)

        try await store.writeRawValue(Data("0".utf8), forKey: countKey)
        #expect(try await store.putDocument(input).currentVersion == 1)
        #expect(try await store.searchCorpusDocumentCount() == 1)
    }
}

@Test func storageUpdateOfMissingIDCreatesFreshIdentity() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let unknown = try DocumentID(rawValue: "missing-id")
        let input = DocumentInput(path: try DocumentPath("/new"), body: "Proposed")
        let created = try await store.updateDocument(.documentID(unknown), with: input)
        #expect(created.id != unknown)
        #expect(created.currentVersion == 1)
        #expect(try await store.getDocument(.path(input.path), trackingRead: false) == created)
        #expect(try await store.getDocument(.documentID(unknown), trackingRead: false) == nil)
    }
}

@Test func lintRejectsMalformedPathAndCitationIndexKeys() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let scope = try DocumentPath("/wiki")
        let source = try await store.putDocument(DocumentInput(
            path: DocumentPath("/wiki/source.md"), body: "[[target]]"
        ))
        let target = try await store.putDocument(DocumentInput(
            path: DocumentPath("/wiki/target.md"), body: "Target"
        ))

        let malformedPath = MetaBrainKeyspace.documentPath(try DocumentPath("/wiki/broken"))
        try await store.writeRawValue(Data([0xFF]), forKey: malformedPath)
        await #expect(throws: MetaBrainStoreError.operationFailed(
            message: "Invalid ID in document path index."
        )) {
            try await store.lint(DocumentLintQuery(path: scope))
        }
        try await store.deleteRawValue(forKey: malformedPath)

        let badOccurrenceKey = MetaBrainKeyspace.citationInPrefix(target.id) + "/invalid"
        try await store.writeRawValue(Data(), forKey: badOccurrenceKey)
        await #expect(throws: MetaBrainStoreError.operationFailed(
            message: "Invalid Markdown citation occurrence key."
        )) {
            try await store.links(for: .documentID(target.id), direction: .incoming)
        }
        try await store.deleteRawValue(forKey: badOccurrenceKey)

        let resolved = try #require(try await store.links(for: .documentID(source.id)).first)
        #expect(resolved.status == .resolved)
        #expect(resolved.targetID == target.id)

        let targetHeader = MetaBrainKeyspace.citationPath(target.id)
        try await store.deleteRawValue(forKey: targetHeader)
        let missingTarget = try #require(try await store.links(for: .documentID(source.id)).first)
        #expect(missingTarget.status == .unresolved)
        #expect(missingTarget.targetID == nil)
        #expect(missingTarget.targetPath == nil)
    }
}

@Test func evidenceMergesOverlappingWindowsAndUsesParagraphsForPlainText() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = String(repeating: "x", count: 50) + " needle "
            + String(repeating: "x", count: 240) + " needle " + String(repeating: "x", count: 100)
        let document = try await store.putDocument(DocumentInput(path: DocumentPath("/samples"), body: body))
        let matched = try await store.searchEvidence(SearchQuery(text: "needle"), view: .evidence)
        #expect(matched.items.count == 1)
        #expect(matched.items.first?.text == body)
        #expect(matched.items.first?.ref.documentID == document.id)

        let text = "Before.\n \nA plain text paragraph.\nIts second line.\n \nAfter."
        let plain = try await store.putDocument(DocumentInput(path: DocumentPath("/plain"), body: text))
        let start = "Before.\n \nA plain text ".count
        let reference = try EvidenceReference("\(plain.id.rawValue)@1#\(start)-\(start + 9)")
        let section = try await store.getEvidence(reference, context: .section)
        #expect(section.items.first?.text == "A plain text paragraph.\nIts second line.")
        #expect(!section.truncated)
    }
}

@Test func evidenceAndRecallOrderEquallyRankedDocumentsByIdentity() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let first = try await store.putDocument(DocumentInput(path: DocumentPath("/z"), body: "Needle"))
        let second = try await store.putDocument(DocumentInput(path: DocumentPath("/a"), body: "Needle"))
        let ids = [first.id, second.id].sorted()
        let query = SearchQuery(text: "needle")

        #expect(try await store.searchEvidence(query, view: .refs).items.map(\.ref.documentID) == ids)
        #expect(try await store.recall(query).map(\.documentID) == ids.map(\.rawValue))
        #expect(try await store.searchEvidence(SearchQuery(text: "!?"), view: .refs).items.isEmpty)
    }
}

@Test func markdownTreatsUnclosedMetadataAsProseAndSkipsUnquotedHTMLAttributes() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let input = DocumentInput(path: try DocumentPath("/wiki/note.md"), body: "---\ntags: hidden")
        #expect(input.isMarkdown)
        _ = try await store.putDocument(input)
        #expect(try await store.searchEvidence(SearchQuery(text: "", tags: ["hidden"]), view: .refs).items.isEmpty)

        let source = "<span title=[[hidden]]>[[visible]]</span>"
        let parsed = MarkdownDocument(body: source)
        #expect(parsed.links.map(\.destination) == ["visible"])
        #expect(try parsed.anchor(for: .range(start: 0, end: 4)) == nil)
    }
}
