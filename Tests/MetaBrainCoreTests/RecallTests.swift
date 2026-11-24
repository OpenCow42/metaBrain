import Foundation
@testable import MetaBrainCore
import Testing

@Test func recallKeepsTailEvidenceWithinTheEncodedByteBudget() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let tail = "🧑‍🚀 \"e\u{301}\"\nneedle / mark\t🌍"
        let body = String(repeating: "🌊 filler ", count: 900) + tail
        let path = try DocumentPath("/unicode/tail")
        let source = try #require(URL(string: "https://example.org/source"))
        let document = try await store.putDocument(DocumentInput(
            path: path,
            title: "A \"quoted\" title 🫐",
            body: body,
            tags: ["keep"],
            metadata: ["source": source.absoluteString, "private": String(repeating: "x", count: 20_000)],
            references: [.externalURL(source)]
        ))
        _ = try await store.putDocument(DocumentInput(path: path, title: document.title, body: body + "!", tags: document.tags, metadata: document.metadata, references: document.references))
        _ = try await store.putDocument(DocumentInput(path: try DocumentPath("/excluded"), body: "needle"))

        let query = SearchQuery(
            text: "needle", pathPrefix: try DocumentPath("/unicode"), tags: ["keep"],
            metadata: ["SOURCE": source.absoluteString], limit: 4
        )
        let budget = 320
        let results = try await store.recall(query, maxBytes: budget)
        let citation = try #require(results.first)
        let passage = try #require(citation.passages.first)
        #expect(results.count == 1)
        #expect(citation.documentID == document.id.rawValue)
        #expect(citation.path == path.rawValue)
        #expect(citation.version == 2)
        #expect(citation.title == document.title)
        #expect(citation.sources == [source.absoluteString])
        #expect(passage.start > body.count - 200)
        #expect(passage.text.contains("needle"))
        let exactBodyPassage = String(Array(body + "!")[passage.start..<passage.end])
        #expect(passage.text.utf8.elementsEqual(exactBodyPassage.utf8))
        let encoded = try RecallResult.jsonData(results)
        #expect(encoded.count + 1 <= budget)
        #expect(String(decoding: encoded, as: UTF8.self).contains(source.absoluteString))
        #expect(try JSONDecoder().decode([RecallResult].self, from: encoded) == results)
        #expect(try await store.entryMetadata(for: .path(path))?.access.readCount == 0)

        for bytes in [3, 17, 90, 179, 230, 511, 1024] {
            let result = try await store.recall(query, maxBytes: bytes)
            #expect(try RecallResult.jsonData(result).count + 1 <= bytes)
        }
    }
}

@Test func recallSelectsDistinctDocumentsFromAllCandidates() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let longMatch = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/dominant"), title: "Needle Needles", body: String(repeating: "needle ", count: 2100)
        ))
        let other = try await store.putDocument(DocumentInput(path: try DocumentPath("/different"), body: "Buried needle."))
        let oversizedSource = String(repeating: "\"\\\n🎋", count: 2_000)
        let oversized = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/needle/oversized"), title: "Needle Needle Needle", body: "needle needle",
            metadata: ["source": oversizedSource]
        ))
        let query = SearchQuery(text: "needle", limit: 2)

        let results = try await store.recall(query, maxBytes: 550)
        #expect(results.map(\.documentID) == [longMatch.id.rawValue, other.id.rawValue])
        #expect(results.allSatisfy { $0.passages.contains { $0.text.contains("needle") } })
        #expect(!results.contains { $0.documentID == oversized.id.rawValue })
        #expect(try RecallResult.jsonData(results).count + 1 <= 550)
    }
}

@Test func recallMergesOverlappingEvidenceAndKeepsSeparateWindows() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let body = String(repeating: "x ", count: 1850) + "needle " + String(repeating: "y ", count: 2350) + "needle end"
        _ = try await store.putDocument(DocumentInput(path: try DocumentPath("/overlap"), body: body))

        let results = try await store.recall(SearchQuery(text: "needle", limit: 1))
        let citation = try #require(results.first)
        let windows = citation.passages
        #expect(windows.count == 2)
        let first = try #require(windows.first)
        let last = try #require(windows.last)
        #expect(first.end <= last.start)
        for passage in windows {
            #expect(passage.text.contains("needle"))
            #expect(passage.end - passage.start <= 480)
            #expect(passage.text == String(Array(body)[passage.start..<passage.end]))
        }
    }
}

@Test func recallReturnsOpeningEvidenceForFieldOnlyMatches() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let opening = "🧑‍🚀 The service reloads its configuration whenever it restarts."
        let body = opening + String(repeating: " Other detail follows.", count: 500)
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/technical-decision"), title: "Persistence rationale", body: body
        ))

        let results = try await store.recall(SearchQuery(text: "Persistence rationale", limit: 1))
        let citation = try #require(results.first)
        let passage = try #require(citation.passages.first)
        #expect(citation.documentID == document.id.rawValue)
        #expect(passage.start == 0)
        #expect(passage.end == 120)
        #expect(passage.text == String(body.prefix(passage.end)))
        #expect(passage.text.hasPrefix(opening))
    }
}

@Test func recallReservesTheFinalNewlineAndHandlesEmptyBodies() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/field-only"), title: "Only title evidence", body: "",
            metadata: ["source": "archive \"shelf\" 4"]
        ))
        let query = SearchQuery(text: "evidence")
        let full = try await store.recall(query)
        let citation = try #require(full.first)
        #expect(citation.documentID == document.id.rawValue)
        #expect(citation.sources == ["archive \"shelf\" 4"])
        #expect(citation.passages.isEmpty)
        let requiredBytes = try RecallResult.jsonData(full).count + 1
        #expect(try await store.recall(query, maxBytes: requiredBytes) == full)
        #expect(try await store.recall(query, maxBytes: requiredBytes - 1).isEmpty)
        #expect(try await store.recall(query, maxBytes: 3).isEmpty)
        #expect(try await store.recall(SearchQuery(text: "--")).isEmpty)
        await #expect(throws: RecallError.invalidByteBudget(2)) {
            try await store.recall(query, maxBytes: 2)
        }
        await #expect(throws: RecallError.invalidDocumentLimit(0)) {
            try await store.recall(SearchQuery(text: "evidence", limit: 0))
        }
    }
}

@Test func recallCitationsMatchAStoredRevisionUnderConcurrentWrites() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/concurrent")
        let document = try await store.putDocument(recallRevisionInput(path: path, version: 1))

        async let editing: Void = {
            for version in 2...12 {
                try await store.putDocument(recallRevisionInput(path: path, version: version))
            }
        }()
        let citations = try await withThrowingTaskGroup(of: RecallResult.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try #require(try await store.recall(SearchQuery(text: "anchor", limit: 1), maxBytes: 400).first)
                }
            }
            var results: [RecallResult] = []
            for try await citation in group { results.append(citation) }
            return results
        }
        try await editing
        let history = try await store.listVersions(of: .documentID(document.id))
        for citation in citations {
            let version = try #require(history.first { $0.sequence == citation.version })
            #expect(citation.documentID == document.id.rawValue)
            #expect(citation.path == version.snapshot.path.rawValue)
            #expect(citation.title == version.snapshot.title)
            #expect(citation.sources == [try #require(version.snapshot.metadata["source"])])
            let passage = try #require(citation.passages.first)
            #expect(passage.text == String(Array(version.snapshot.body)[passage.start..<passage.end]))
        }
    }
}

private func recallRevisionInput(path: DocumentPath, version: Int) -> DocumentInput {
    DocumentInput(path: path, title: "Revision \(version)", body: "Citation anchor in body \(version)", metadata: ["source": "Source \(version)"])
}
