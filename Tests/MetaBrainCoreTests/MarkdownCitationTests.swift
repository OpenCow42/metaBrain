import Foundation
import Testing
@testable import MetaBrainCore

@Test func markdownCitationsParseVisibleLinksAndKeepExactOffsets() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let target = try await store.putDocument(DocumentInput(
            path: DocumentPath("/Target (draft).md"), body: "# Café archive\n\nThe rule ^keep-last\n"
        ))
        let sourceBody = """
        ---
        hidden: "[[yaml]]"
        ---
        👩🏽‍💻 Read [[Target (draft)#^keep-last|the rule]] and [café](<Target%20(draft).md#caf%C3%A9-archive> "Title"). ^excerpt

        [another][reference] and [outside](https://example.test/#x).

        [reference]: <Target (draft).md>
        ![image](Target%20(draft).md)
        ![[Target (draft)#^keep-last]]
        %% [[hidden inline]] %%
        %%
        [[hidden block]]
        \u{60}\u{60}\u{60}
        %%
        \\\u{005B}[escaped]]
        \u{60}[[inline]]\u{60} and <!-- [[comment]] --> <code>[[inline HTML]]</code>
        \u{60}\u{60}\u{60}md
        [[fenced]]
        # Not a heading
        \u{60}\u{60}\u{60}
            [[indented]]
        ~~~
        [literal](target.md)
        ~~~
        """
        let source = try await store.putDocument(DocumentInput(
            path: DocumentPath("/SOURCE.MD"), body: sourceBody
        ))
        let results = try await store.links(for: .documentID(source.id))
        try #require(results.count == 6)

        #expect(results.map(\.label) == ["the rule", "café", "another", "outside", "image", nil])
        #expect(results.map(\.targetID) == [target.id, target.id, target.id, nil, target.id, target.id])
        #expect(results.map(\.status) == [.resolved, .resolved, .resolved, .external, .resolved, .resolved])
        #expect(results.map(\.fragment) == ["^keep-last", "café-archive", nil, "x", nil, "^keep-last"])
        #expect(results.map(\.sourceBlock) == ["excerpt", "excerpt", nil, nil, nil, nil])
        #expect(results.map(\.isEmbed) == [false, false, false, false, true, true])
        let sourceCharacters = Array(sourceBody)
        #expect(String(sourceCharacters[results[0].start..<results[0].end]) == "[[Target (draft)#^keep-last|the rule]]")
        #expect(String(sourceCharacters[results[5].start..<results[5].end]) == "![[Target (draft)#^keep-last]]")
        #expect(try await store.links(for: .documentID(source.id), block: "^excerpt") == Array(results.prefix(2)))
        #expect(try await store.links(for: .documentID(target.id), direction: .incoming) == results.filter { $0.targetID == target.id })
        #expect(try await store.links(for: .documentID(target.id), direction: .incoming, block: "keep-last") == [results[0], results[5]])
        #expect(try await store.readPassage(.documentID(source.id), selector: .heading("Not a heading")) == nil)
    }
}

@Test func markdownCitationsResolveForwardAndKeepIdentityAcrossMoveAndPatch() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let native = try await store.putDocument(DocumentInput(path: DocumentPath("/native"), body: "Native ref"))
        let nativeReference = DocumentReference.documentID(native.id)
        let sourcePath = try DocumentPath("/team/decision")
        let source = try await store.putDocument(DocumentInput(
            path: sourcePath,
            body: "See [[Retention#^rule]].\n",
            references: [nativeReference],
            markdown: true
        ))
        let sourceReference = DocumentReference.documentID(source.id)
        let pending = try #require(try await store.links(for: sourceReference).first)
        #expect(pending.status == .unresolved)
        #expect(pending.targetID == nil)
        #expect(try await store.outboundReferences(from: source.id) == [native.id])

        let targetPath = try DocumentPath("/policy/Retention.md")
        let target = try await store.putDocument(DocumentInput(path: targetPath, body: "The rule ^rule\n"))
        let targetReference = DocumentReference.documentID(target.id)
        #expect(try await store.links(for: sourceReference).first?.targetID == target.id)
        #expect(try await store.outboundReferences(from: source.id) == [native.id, target.id].sorted())
        #expect(try await store.inboundReferences(to: target.id) == [source.id])
        let movedPath = try DocumentPath("/archive/policy")
        _ = try await store.moveDocument(targetReference, to: movedPath)
        let replacement = try await store.putDocument(DocumentInput(path: targetPath, body: "A different rule ^rule\n"))
        let patched = try await store.patchDocument(DocumentPatchRequest(
            reference: sourceReference,
            unifiedDiff: "@@ -1 +1,2 @@\n-See [[Retention#^rule]].\n+For details:\n+See [[Retention#^rule|stable]].\n"
        ))
        let link = try #require(try await store.links(for: sourceReference).first)
        #expect(link.targetID == target.id)
        #expect(link.targetPath == movedPath)
        #expect(link.status == .resolved)
        #expect(link.label == "stable")
        #expect(link.sourceVersion == patched.currentVersion)
        #expect(patched.references == [nativeReference])
        #expect(try await store.links(for: .documentID(replacement.id), direction: .incoming).isEmpty)
        #expect(try await store.readPassage(targetReference, selector: .block("rule"))?.passage.text == "The rule")

        await store.close()
        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.links(for: sourceReference) == [link])
        #expect(try await reopened.deleteDocument(targetReference))
        #expect(try await reopened.links(for: sourceReference).first?.status == .unresolved)
        #expect(try await reopened.outboundReferences(from: source.id) == [native.id])
        #expect(try await reopened.links(for: .documentID(replacement.id), direction: .incoming).isEmpty)
        _ = try await reopened.writeDocument(
            DocumentInput(path: sourcePath, body: "The bound link is [[Retention#^rule]]."),
            bodyOnly: true
        )
        #expect(try await reopened.links(for: sourceReference).first?.status == .unresolved)
        #expect(try await reopened.links(for: .documentID(replacement.id), direction: .incoming).isEmpty)
    }
}

@Test func markdownCitationsReportAmbiguousNamesAndUpdatePendingMatches() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let first = try await store.putDocument(DocumentInput(path: DocumentPath("/a/shared.md"), body: "First"))
        let second = try await store.putDocument(DocumentInput(path: DocumentPath("/b/shared.md"), body: "Second"))
        let source = try await store.putDocument(DocumentInput(
            path: DocumentPath("/c/source.md"), body: "[[shared]] [explicit](../a/shared.md) [[/b/shared.md]]"
        ))
        let sourceReference = DocumentReference.documentID(source.id)
        let results = try await store.links(for: sourceReference)
        try #require(results.count == 3)
        #expect(results.map(\.status) == [.ambiguous, .resolved, .resolved])
        #expect(results[0].candidates.map(\.documentID) == [first.id, second.id])
        #expect(results[0].candidates.map(\.path) == [first.path, second.path])
        #expect(results.map(\.targetID) == [nil, first.id, second.id])

        _ = try await store.moveDocument(.documentID(second.id), to: DocumentPath("/b/renamed.md"))
        let updated = try await store.links(for: sourceReference)
        #expect(updated.map(\.targetID) == [first.id, first.id, second.id])
        #expect(updated.map(\.status) == [.resolved, .resolved, .resolved])
        #expect(updated[0].candidates.isEmpty)
        #expect(try await store.links(for: .documentID(first.id), direction: .incoming) == Array(updated.prefix(2)))
        #expect(try await store.deleteDocument(sourceReference))
        #expect(try await store.links(for: .documentID(first.id), direction: .incoming).isEmpty)
    }
}

@Test func markdownPassagesReadCurrentAndRetainedBlocksSectionsAndRanges() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = "👨‍👩‍👧 title\r\n\r\n# Retention\r\n\r\nKeep nightly backups.\r\nFor seven days.\r\n\r\n^keep-last\r\n\r\n## Details\r\n\r\nMore.\r\n\r\n# Next\r\n"
        let path = try DocumentPath("/policy")
        let original = try await store.putDocument(DocumentInput(path: path, body: body))
        let reference = DocumentReference.documentID(original.id)
        #expect(try await store.readPassage(reference, selector: .block("keep-last")) == nil)
        let enabled = try await store.writeDocument(DocumentInput(path: path, body: body, markdown: true), ifVersion: 1)
        #expect(enabled.status == .updated)
        #expect(try await store.writeDocument(DocumentInput(path: path, body: body), ifVersion: 1).status == .unchanged)

        let block = try #require(try await store.readPassage(reference, selector: .block("^keep-last")))
        #expect(block.passage.text == "Keep nightly backups.\r\nFor seven days.")
        #expect(String(Array(body)[block.passage.start..<block.passage.end]) == block.passage.text)
        let heading = try #require(try await store.readPassage(reference, selector: .heading("retention")))
        #expect(heading.passage.text.hasPrefix("# Retention"))
        #expect(heading.passage.text.hasSuffix("More."))
        #expect(try await store.readPassage(reference, selector: .range(start: 0, end: 1))?.passage.text == "👨‍👩‍👧")
        await #expect(throws: DocumentPassageError.invalidRange(start: -1, end: 0)) {
            try await store.readPassage(reference, selector: .range(start: -1, end: 0))
        }

        let updated = try await store.writeDocument(DocumentInput(path: path, body: "Current ^keep-last"), bodyOnly: true)
        #expect(updated.document.isMarkdown)
        #expect(try await store.readPassage(reference, selector: .block("keep-last"))?.passage.text == "Current")
        #expect(try await store.readPassage(reference, selector: .block("keep-last"), version: 2)?.passage == block.passage)
        #expect(try await store.readPassage(reference, selector: .block("keep-last"), version: 1) == nil)
        #expect(try await store.readPassage(reference, selector: .block("keep-last"), version: 100) == nil)
        #expect(try await store.entryMetadata(for: reference)?.access.readCount == 0)
    }
}

@Test func markdownPassagesReportDuplicateSelectorsAndMissingFragments() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(
            path: DocumentPath("/duplicate.md"),
            body: "# Duplicate\n\nFirst ^block\n\n# Duplicate\n\nSecond ^block\n\n[[#^block]] [[#missing]] [[#duplicate-1]]"
        ))
        let reference = DocumentReference.documentID(document.id)
        await #expect(throws: DocumentPassageError.ambiguousSelector("Duplicate")) {
            try await store.readPassage(reference, selector: .heading("Duplicate"))
        }
        await #expect(throws: DocumentPassageError.ambiguousSelector("block")) {
            try await store.readPassage(reference, selector: .block("block"))
        }
        let results = try await store.links(for: reference)
        #expect(results.map(\.status) == [.ambiguous, .unresolved, .resolved])
        #expect(results.map(\.targetID) == [document.id, document.id, document.id])
        #expect(try await store.readPassage(reference, selector: .heading("duplicate-1"))?.passage.text.contains("Second") == true)
    }
}

@Test func markdownBlocksOnListItemsSelectOnlyTheirOwnItem() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(
            path: DocumentPath("/list.md"),
            body: """
            1. Previous [[#Rules]]
            2. Follow [[#Rules]]
               with the exception ^rule
            3. Subsequent

            # Rules

            Body.
            """
        ))
        let reference = DocumentReference.documentID(document.id)
        let passage = try #require(try await store.readPassage(reference, selector: .block("rule")))
        #expect(passage.passage.text == "2. Follow [[#Rules]]\n   with the exception")
        let occurrences = try await store.links(for: reference, block: "rule")
        #expect(occurrences.count == 1)
        #expect(occurrences.first?.status == .resolved)
        #expect(occurrences.first?.snippet == "2. Follow [[#Rules]]")
    }
}

@Test func markdownCitationIndexBackfillsLegacyNotesWithoutChangingTheirRecords() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let source = try await seedLegacyCitationDocument(
            in: store, id: "legacy-source", path: "/legacy/source.md", body: "[[Target#^rule]]"
        )
        let target = try await seedLegacyCitationDocument(
            in: store, id: "legacy-target", path: "/policy/Target.md", body: "Legacy rule ^rule"
        )
        let sourceKey = MetaBrainKeyspace.document(id: source.id)
        let saved = try await store.rawValue(forKey: sourceKey)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.citationLayout) == nil)

        let outgoing = try #require(try await store.links(for: .documentID(source.id)).first)
        #expect(outgoing.targetID == target.id)
        #expect(outgoing.status == .resolved)
        #expect(try await store.links(for: .documentID(target.id), direction: .incoming) == [outgoing])
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.citationLayout) == Data([3]))
        #expect(try await store.rawValue(forKey: sourceKey) == saved)

        await store.close()
        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.links(for: .documentID(source.id)) == [outgoing])
    }
}

@Test func markdownCitationBackfillAndUpdatesUseTheExactUTF8SpellingOfTargets() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let first = try await seedLegacyCitationDocument(in: store, id: "first", path: "/catalog/\(composed).md", body: "First target.")
        let second = try await seedLegacyCitationDocument(in: store, id: "second", path: "/catalog/\(decomposed).md", body: "Second target.")
        let body = "[[/catalog/\(composed).md]] [[/catalog/\(decomposed).md]] [[\(composed)]] [[\(decomposed)]]"
        let source = try await seedLegacyCitationDocument(in: store, id: "source", path: "/legacy/source.md", body: body)
        let expected: [DocumentID?] = [first.id, second.id, first.id, second.id]
        let reference = DocumentReference.documentID(source.id)

        let backfilled = try await store.links(for: reference)
        #expect(backfilled.map(\.status) == Array(repeating: .resolved, count: expected.count))
        #expect(backfilled.map(\.targetID) == expected)

        _ = try await store.writeDocument(DocumentInput(path: source.path, body: "Update: " + body), bodyOnly: true)
        #expect(try await store.links(for: reference).map(\.targetID) == expected)
        let newSource = try await store.putDocument(DocumentInput(path: DocumentPath("/new/source.md"), body: body))
        #expect(try await store.links(for: .documentID(newSource.id)).map(\.targetID) == expected)
    }
}

@Test func normalizationOnlyMoveUpdatesAliasesPendingCitationsAndPathFilters() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let composed = try DocumentPath("/caf\u{00E9}")
        let decomposed = try DocumentPath("/cafe\u{0301}")
        let from = try DocumentPath(composed.rawValue + "/policy.md")
        let to = try DocumentPath(decomposed.rawValue + "/policy.md")
        let bystander = try DocumentPath(decomposed.rawValue + "/bystander.md")
        let document = try await store.putDocument(DocumentInput(path: from, body: "Match this policy."))
        let other = try await store.putDocument(DocumentInput(path: bystander, body: "Match this note."))
        let source = try await store.putDocument(DocumentInput(
            path: DocumentPath("/source.md"), body: "[[\(from.rawValue)]] [[\(to.rawValue)]]"
        ))
        let sourceRef = DocumentReference.documentID(source.id)
        let left = SearchQuery(text: "match", pathPrefix: composed)
        let right = SearchQuery(text: "match", pathPrefix: decomposed)
        #expect(try await store.links(for: sourceRef).map(\.targetID) == [document.id, nil])
        #expect(try await store.search(left).map(\.documentID) == [document.id])
        #expect(try await store.search(right).map(\.documentID) == [other.id])

        let moved = try await store.moveDocument(.documentID(document.id), to: to)
        #expect(moved.moved)
        #expect(try await store.getDocument(.path(from), trackingRead: false) == nil)
        #expect(try await store.getDocument(.path(to), trackingRead: false)?.id == document.id)
        #expect(try await store.links(for: sourceRef).map(\.targetID) == [document.id, document.id])
        #expect(try await store.search(left).isEmpty)
        let finalResults = try await store.search(right)
        #expect(Set(finalResults.map(\.documentID)) == Set([document.id, other.id]))
        #expect(try await store.listDirectory(path: composed).isEmpty)
        #expect(try await store.listDirectory(path: decomposed).map(\.path) == [bystander, to])
    }
}

private struct CitationLegacyRecord: Codable, Sendable {
    let document: StoredDocument
    let retention: VersionRetentionPolicy
}

private func seedLegacyCitationDocument(
    in store: MetaBrainStore,
    id: String,
    path: String,
    body: String
) async throws -> StoredDocument {
    let now = Date()
    let document = StoredDocument(
        id: try DocumentID(rawValue: id),
        path: try DocumentPath(path),
        body: body,
        currentVersion: 1,
        createdAt: now,
        updatedAt: now
    )
    try await store.putCompressedRecord(
        CitationLegacyRecord(document: document, retention: .keepAll),
        forKey: MetaBrainKeyspace.document(id: document.id)
    )
    try await store.writeRawValue(Data(document.id.rawValue.utf8), forKey: MetaBrainKeyspace.documentPath(document.path))
    return document
}
