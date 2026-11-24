import Foundation
@testable import MetaBrainCore
import Testing

@Test func evidenceKeepsTheMatchingSentenceAndQualifierUnderATightBudget() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let lead = "Routine update from " + String(repeating: "another team, ", count: 10) + "in May."
        let claim = "The backups keep two versions. However, pinned versions are exempt."
        let path = try DocumentPath("/notes/retention")
        let document = try await store.putDocument(DocumentInput(path: path, body: lead + "\n" + claim))
        let query = SearchQuery(text: "backups")

        let full = try await store.searchEvidence(query, view: .evidence)
        #expect(full.items.first?.text?.contains(lead) == true)
        #expect(!full.truncated)
        let compact = try await store.searchEvidence(query, view: .evidence, maxTokens: 200)
        let hit = try #require(compact.items.first)
        #expect(compact.items.count == 1)
        #expect(compact.truncated)
        #expect(hit.text == claim)
        #expect(try compact.fits(maxTokens: 200))
        #expect(hit.ref.location == .range((lead.count + 1)..<document.body.count))
        let exact = try await store.getEvidence(hit.ref)
        #expect(exact.items == [hit])
        #expect(!exact.truncated)
    }
}

@Test func evidenceMergesOverlappingMatchesAndQueriesReturnCompactReferences() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let first = "\nNeedle in 🧑‍🚀 \"e\u{301}\"; needle again. Except for backups on Mondays.\n"
        let body = String(repeating: "x ", count: 1850) + first
            + String(repeating: "y ", count: 2250) + "\nSecond needle is at the end.\n"
        let path = try DocumentPath("/legacy/overlap")
        let document = try await store.putDocument(DocumentInput(path: path, body: body))
        let query = SearchQuery(text: "needle", limit: 1)

        let evidence = try await store.searchEvidence(query, view: .evidence)
        let refs = try await store.searchEvidence(query, view: .refs)
        #expect(!evidence.truncated)
        #expect(evidence.items.count == 2)
        #expect(evidence.items.map(\.ref) == refs.items.map(\.ref))
        #expect(refs.items.allSatisfy { $0.text == nil })
        #expect(try refs.jsonData().count < evidence.jsonData().count)
        #expect(!String(decoding: try refs.jsonData(), as: UTF8.self).contains("Second needle"))

        let characters = Array(body)
        var ranges: [Range<Int>] = []
        for hit in evidence.items {
            #expect(hit.ref.documentID == document.id)
            #expect(hit.ref.version == 1)
            guard case .range(let range) = hit.ref.location else { Issue.record("Expected range reference"); continue }
            #expect(ranges.allSatisfy { !$0.overlaps(range) })
            ranges.append(range)
            let text = try #require(hit.text)
            #expect(text.utf8.elementsEqual(String(characters[range]).utf8))
            #expect(text.lowercased().contains("needle"))
        }
        #expect(evidence.items.contains { $0.text?.contains("Except for backups on Mondays.") == true })
    }
}

@Test func filterOnlyReferencesUsePathTagAndMetadataWithoutExposingBody() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/archive")
        let child = try DocumentPath("/archive/child")
        let body = "A very long note. " + String(repeating: "\"🧑‍🚀\\\t", count: 2_000)
        let matched = try await store.putDocument(DocumentInput(path: path, body: body, tags: ["keep"], metadata: ["scope": "release"]))
        _ = try await store.putDocument(DocumentInput(path: child, body: "", tags: ["keep"]))
        _ = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/archived/fail"), body: "No", tags: ["keep"], metadata: ["scope": "release"]
        ))

        let all = try await store.searchEvidence(SearchQuery(text: "", pathPrefix: path), view: .refs)
        #expect(all.items.map(\.path) == [path.rawValue, child.rawValue])
        let query = SearchQuery(text: " \n", pathPrefix: path, tags: ["keep"], metadata: ["SCOPE": "release"])
        let refs = try await store.searchEvidence(query, view: .refs)
        let hit = try #require(refs.items.first)
        #expect(refs.items.count == 1)
        #expect(hit.ref.documentID == matched.id)
        #expect(hit.ref.location == .range(0..<body.count))
        #expect(hit.text == nil)

        let expansion = try await store.getEvidence(hit.ref, maxTokens: 150)
        #expect(expansion.truncated)
        #expect(try expansion.fits(maxTokens: 150))
        let prefix = try #require(expansion.items.first)
        let prefixText = try #require(prefix.text)
        #expect(!prefixText.isEmpty)
        #expect(body.utf8.starts(with: prefixText.utf8))
        #expect(prefix.ref.location == .range(0..<prefixText.count))
        #expect(try await store.getEvidence(prefix.ref).items == [prefix])
        let empty = try #require(all.items.last)
        #expect(try await store.getEvidence(empty.ref).items.first?.text == "")

        await #expect(throws: EvidenceError.missingTextOrFilters) {
            try await store.searchEvidence(SearchQuery(text: ""), view: .refs)
        }
        await #expect(throws: EvidenceError.filterOnlyRequiresRefs) {
            try await store.searchEvidence(query, view: .evidence)
        }
    }
}

@Test func evidenceReadsHistoricalRangesAndNamedBlocksAfterMove() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/notes/backup.md")
        let paragraph = "Keep two backups. However, never erase pinned ones."
        let section = "## Retention\n\n\(paragraph) ^keep-last\n\nTest the restore."
        let input = DocumentInput(path: path, body: section + "\n\n## Rotation\n\nRotate elsewhere.")
        let document = try await store.putDocument(input)
        let refs = try await store.searchEvidence(SearchQuery(text: "backups"), view: .refs)
        let hit = try #require(refs.items.first)
        let named = try EvidenceReference("\(document.id.rawValue)@1#^keep-last")
        _ = try await store.putDocument(DocumentInput(path: path, body: "Replaced the original advice."))
        _ = try await store.moveDocument(.path(path), to: DocumentPath("/notes/rewritten.md"))

        let old = try await store.getEvidence(hit.ref)
        #expect(old.items.first?.path == path.rawValue)
        #expect(old.items.first?.text?.contains(paragraph) == true)
        let anchored = try await store.getEvidence(named)
        #expect(anchored.items.first?.ref == named)
        #expect(anchored.items.first?.text == paragraph)
        #expect(anchored.items.first?.path == path.rawValue)
        let expanded = try await store.getEvidence(named, context: .section)
        #expect(expanded.items.first?.text == section)
        #expect(expanded.items.first?.ref.location == .range(0..<section.count))
        let sectionBudget = try anchored.jsonData().count + 1
        let fallback = try await store.getEvidence(named, context: .section, maxTokens: sectionBudget)
        #expect(fallback.items == anchored.items)
        #expect(fallback.truncated)
        #expect(try fallback.fits(maxTokens: sectionBudget))

        let invalid = try EvidenceReference("\(document.id.rawValue)@1#0-9999")
        await #expect(throws: EvidenceError.invalidRange(invalid)) { try await store.getEvidence(invalid) }
        let missing = try EvidenceReference("\(document.id.rawValue)@1#^missing")
        await #expect(throws: EvidenceError.blockNotFound(missing)) { try await store.getEvidence(missing) }
        _ = try await store.removeVersion(documentID: document.id, sequence: 1)
        await #expect(throws: MetaBrainStoreError.documentVersionNotFound(reference: named.rawValue, version: 1)) {
            try await store.getEvidence(named)
        }
    }
}

@Test func evidenceBudgetCoversEncodedEscapesEnvelopeSeparatorsAndLineFeed() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let a = try DocumentPath("/one/🍐")
        let b = try DocumentPath("/two/quoted\"")
        _ = try await store.putDocument(DocumentInput(path: a, body: "🍐 needle is \"here\".\r\nUnless marked \u{1b}!"))
        _ = try await store.putDocument(DocumentInput(path: b, title: "needle 🚀", body: "\nOnly a title match."))
        let query = SearchQuery(text: "needle")
        let full = try await store.searchEvidence(query, view: .evidence)
        #expect(full.items.count == 2)
        #expect(full.items.first { $0.path == b.rawValue }?.text == "Only a title match.")
        let exactBudget = try full.jsonData().count + 1
        #expect(try await store.searchEvidence(query, view: .evidence, maxTokens: exactBudget) == full)
        #expect(try await store.searchEvidence(query, view: .evidence, maxTokens: exactBudget - 1).truncated)
        #expect(try await store.searchEvidence(SearchQuery(text: "needle", limit: 1), view: .refs).truncated)

        for budget in [31, 60, 110, 168, exactBudget, 345, Int.max] {
            let result = try await store.searchEvidence(query, view: .evidence, maxTokens: budget)
            let data = try result.jsonData()
            #expect(data.count < budget)
            #expect(try JSONDecoder().decode(EvidenceOutput.self, from: data) == result)
        }
        let tiny = try await store.searchEvidence(query, view: .evidence, maxTokens: 31)
        #expect(tiny.items.isEmpty && tiny.truncated)
        let empty = try await store.searchEvidence(SearchQuery(text: "nothing"), view: .evidence, maxTokens: 31)
        #expect(empty.items.isEmpty && !empty.truncated)
        #expect(try empty.jsonData().count + 1 == 31)
        await #expect(throws: EvidenceError.invalidTokenBudget(30)) {
            try await store.searchEvidence(query, view: .evidence, maxTokens: 30)
        }
        await #expect(throws: EvidenceError.invalidDocumentLimit(0)) {
            try await store.searchEvidence(SearchQuery(text: "needle", limit: 0), view: .refs)
        }
    }
}

@Test func evidenceReferenceParsesRangesAndRejectsMalformedValues() throws {
    let range = try EvidenceReference("d73a@4#12-34")
    #expect(range.location == .range(12..<34))
    #expect(range.rawValue == "d73a@4#12-34")
    let named = try EvidenceReference("d73a@4#^keep-last_2")
    #expect(named.location == .block("keep-last_2"))
    #expect(try JSONEncoder().encode(named) == Data("\"d73a@4#^keep-last_2\"".utf8))
    for value in ["doc", "@1#0-1", "d73a@0#0-1", "d73a@1#1-0", "d73a@1#-1-1", "d73a@1#^", "d73a@1#^two words", "d73a@1#0-9223372036854775808"] {
        #expect(throws: EvidenceError.invalidReference(value)) { try EvidenceReference(value) }
    }
}
