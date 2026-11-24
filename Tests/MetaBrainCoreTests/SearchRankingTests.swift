import Testing
@testable import MetaBrainCore

@Test func searchRanksTitleAndPathWithSingleRepresentativePassages() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let titleMatch = try await store.putDocument(DocumentInput(
            path: DocumentPath("/manual/setup"),
            title: "Café deployment",
            body: "Opening instructions. " + String(repeating: "background ", count: 800)
        ))
        let pathMatch = try await store.putDocument(DocumentInput(
            path: DocumentPath("/manual/CAFÉ-checklist"),
            body: "Confirm the package is available."
        ))
        let bodyMatch = try await store.putDocument(DocumentInput(
            path: DocumentPath("/manual/schedule"),
            body: "Meet at the café."
        ))

        let results = try await store.search(SearchQuery(text: "CAFÉ"))
        try #require(results.count == 3)
        #expect(results.map(\.documentID) == [titleMatch.id, pathMatch.id, bodyMatch.id])
        #expect(results.map(\.chunkOrdinal) == [0, 0, 0])
        #expect(results[0].snippet.hasPrefix("Opening instructions."))
        #expect(results[0].context.map(\.ordinal) == [1])
        #expect(results[1].snippet == "Confirm the package is available.")
        #expect(results[0].score > results[1].score)
        #expect(results[1].score > results[2].score)
    }
}

@Test func searchUsesTitleOrPathWhenAFieldMatchHasNoBodyText() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/manual/release"), title: "Rollback guide", body: ""
        ))
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/manual/rollback"), body: ""
        ))

        let results = try await store.search(SearchQuery(text: "rollback"))
        #expect(results.map(\.snippet) == ["Rollback guide", "/manual/rollback"])
        #expect(results.allSatisfy { $0.chunkOrdinal == 0 && $0.context.isEmpty })
    }
}

@Test func searchRanksACompleteQueryAheadOfRepeatedOccurrencesOfACommonTerm() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let repetitions = try await store.putDocument(DocumentInput(
            path: DocumentPath("/manual/log"),
            body: String(repeating: "upgrade ", count: 650)
        ))
        let completeMatch = try await store.putDocument(DocumentInput(
            path: DocumentPath("/manual/guide"),
            body: "Upgrade instructions. " + String(repeating: "background ", count: 440) + "Use nebulizer."
        ))

        let results = try await store.search(SearchQuery(text: "upgrade nebulizer"))
        let first = try #require(results.first)
        let repeated = try #require(results.first { $0.documentID == repetitions.id })
        #expect(first.documentID == completeMatch.id)
        #expect(first.snippet.contains("nebulizer"))
        #expect(first.score > repeated.score)
    }
}

@Test func searchUsesCorpusRarityEvenWhenFiltersExcludeOtherMatches() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let common = try await store.putDocument(DocumentInput(
            path: DocumentPath("/target/common"),
            body: "alpha",
            tags: ["Selected", "Reviewed"], metadata: ["stage": "Published"]
        ))
        let rare = try await store.putDocument(DocumentInput(
            path: DocumentPath("/target/rare"),
            body: "rho",
            tags: ["Selected", "Reviewed"], metadata: ["stage": "Published"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/target/missing-tag"),
            title: "Alpha", body: "alpha",
            tags: ["Selected"], metadata: ["stage": "Published"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/target/missing-metadata"),
            body: "alpha",
            tags: ["Selected", "Reviewed"], metadata: ["stage": "Draft"]
        ))
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/targeting/other"),
            title: "Rho", body: "alpha",
            tags: ["Selected", "Reviewed"], metadata: ["stage": "Published"]
        ))

        let all = try await store.search(SearchQuery(text: "alpha rho"))
        let filtered = try await store.search(SearchQuery(
            text: "alpha rho",
            pathPrefix: DocumentPath("/target"),
            tags: ["selected", "reviewed"],
            metadata: ["stage": "published"]
        ))
        #expect(filtered.map(\.documentID) == [rare.id, common.id])
        #expect(filtered == all.filter { $0.documentID == rare.id || $0.documentID == common.id })
    }
}

@Test func searchCountsEachDocumentOncePerTermAcrossFieldsAndChunks() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/selected/first"), body: "alpha"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/selected/second"), body: "rho"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/outside/alpha"),
            title: "Alpha",
            body: "alpha " + String(repeating: "background ", count: 400) + "alpha"
        ))
        _ = try await store.putDocument(DocumentInput(
            path: DocumentPath("/outside/other"), body: "rho"
        ))

        let results = try await store.search(SearchQuery(
            text: "alpha rho",
            pathPrefix: DocumentPath("/selected")
        ))
        try #require(results.count == 2)
        #expect(results[0].score == results[1].score)
    }
}

@Test func searchReranksAfterTitleBodyAndPathEditsAndAfterReopen() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let first = try await store.putDocument(DocumentInput(
            path: DocumentPath("/notes/brief"),
            title: "Rollback",
            body: "Instructions."
        ))
        let second = try await store.putDocument(DocumentInput(
            path: DocumentPath("/notes/log"), body: "rollback"
        ))
        #expect(try await store.search(SearchQuery(text: "rollback")).map(\.documentID) == [first.id, second.id])

        _ = try await store.putDocument(DocumentInput(
            path: first.path, title: "Migration", body: "Finished."
        ))
        let destination = try DocumentPath("/notes/rollback-plan")
        _ = try await store.moveDocument(.documentID(second.id), to: destination)
        _ = try await store.writeDocument(DocumentInput(path: destination, body: "Inspect progress."), bodyOnly: true)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let rollback = try await reopened.search(SearchQuery(text: "rollback"))
        #expect(rollback.map(\.documentID) == [second.id])
        #expect(rollback.first?.path == destination)
        #expect(rollback.first?.snippet == "Inspect progress.")
        #expect(try await reopened.search(SearchQuery(text: "migration")).map(\.documentID) == [first.id])

        _ = try await reopened.deleteDocument(.documentID(second.id))
        #expect(try await reopened.search(SearchQuery(text: "rollback")).isEmpty)
    }
}
