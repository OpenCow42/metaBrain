import Foundation
import Testing
@testable import MetaBrainCore

@Test func graphGroupsOccurrencesAndScopesNeighborhoods() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let folder = try DocumentPath("/project")
        let sourcePath = try DocumentPath("/project/reviews/source.md")
        let unlinked = try await store.putDocument(DocumentInput(path: DocumentPath("/project/unlinked.md"), body: ""))
        let outside = try await store.putDocument(DocumentInput(path: DocumentPath("/project-other/other.md"), body: ""))
        let source = try await store.putDocument(DocumentInput(
            path: sourcePath, title: "Source review",
            body: "Result. ^result\n\n[[/project/decision.md]]",
            references: [.documentID(outside.id)]
        ))
        let decision = try await store.putDocument(DocumentInput(
            path: DocumentPath("/project/decision.md"),
            body: "[[reviews/source.md#^result]] and [[reviews/source.md#^result]]\n\n[Review]\n\n[[missing]] [[reviews/source.md#^gone]] [Site](https://example.test/)\n\n[Review]: reviews/source.md#^result",
            references: [.documentID(source.id)]
        ))

        let local = try await store.graph(DocumentGraphQuery(scope: .note(id: decision.id, depth: 1)))
        #expect(Set(local.nodes.map(\.id)) == [decision.id, source.id])
        #expect(local.connections.count == 3)
        let edge = try #require(local.connections.first {
            $0.id.source == decision.id && $0.id.relationship == .markdown
        })
        #expect(edge.count == 3)
        #expect(edge.occurrences.count == 3)
        #expect(local.diagnostics.map(\.destination) == ["missing", "reviews/source.md#^gone"])

        let deeper = try await store.graph(DocumentGraphQuery(scope: .note(id: decision.id, depth: 2)))
        #expect(deeper.nodes.contains { $0.id == outside.id })
        let folderMap = try await store.graph(DocumentGraphQuery(scope: .folder(path: folder)))
        #expect(Set(folderMap.nodes.map(\.id)) == [decision.id, source.id])
        let all = try await store.graph(DocumentGraphQuery(scope: .folder(path: folder), includeUnlinked: true))
        #expect(Set(all.nodes.map(\.id)) == [decision.id, source.id, unlinked.id])
        let filtered = try await store.graph(DocumentGraphQuery(
            scope: .folder(path: folder), includeUnlinked: true, filter: " Source Review "
        ))
        #expect(filtered.nodes.map(\.id) == [source.id])
        #expect(filtered.connections.isEmpty)
        let empty = try await store.graph(DocumentGraphQuery(scope: .folder(path: DocumentPath("/missing"))))
        #expect(empty.nodes.isEmpty)
        await #expect(throws: ProjectOperationError.self) {
            try await store.graph(DocumentGraphQuery(scope: .note(id: decision.id, depth: 3)))
        }
        _ = try await store.deleteDocument(.documentID(decision.id))
        await #expect(throws: MetaBrainStoreError.documentNotFound(decision.id.rawValue)) {
            try await store.graph(DocumentGraphQuery(scope: .note(id: decision.id, depth: 1)))
        }
    }
}

@Test func graphRebuildsRetainedAndClaimBacklinksAndTracksUpdates() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/project")
        let reviewPath = try DocumentPath("/project/review.md")
        let decisionPath = try DocumentPath("/project/decision.md")
        let review = try await store.putDocument(DocumentInput(
            path: reviewPath, body: "The field result. ^result",
            sourceProfile: ClaimSourceProfile(status: .active, synthetic: false, independenceGroup: "field",
                                             freshUntil: Date(timeIntervalSince1970: 4_102_444_800))
        ))
        let ref = try EvidenceReference("\(review.id.rawValue)@1#^result")
        let quote = try await store.putDocument(DocumentInput(
            path: DocumentPath("/project/quote.md"), body: "[Quote](metabrain-ref:\(ref.rawValue)) [Invalid](metabrain-ref:bad)"
        ))
        let claim = ProjectClaim(id: UUID(), text: "Keep an offline copy.", state: .contested, evidence: [
            ClaimEvidence(relation: .supports, ref: ref),
            ClaimEvidence(relation: .contradicts, ref: ref)
        ])
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: decisionPath, body: "Decision.", claims: [claim])
        ])
        let decision = try #require(try await store.applyOperation(store.inspectOperation(operation)).results.first)
        try await store.deleteRawValue(forKey: MetaBrainKeyspace.graphDocument(review.id))
        try await store.deleteRawValue(forKey: MetaBrainKeyspace.graphDocument(decision.documentID))
        try await store.deleteRawValue(forKey: MetaBrainKeyspace.graphClaimInPrefix(review.id) + decision.documentID.rawValue)
        try await store.deleteRawValue(forKey: MetaBrainKeyspace.retainedCitationInPrefix(review.id) + quote.id.rawValue + "/0")
        try await store.writeRawValue(Data([2]), forKey: MetaBrainKeyspace.citationLayout)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let reviewScope = DocumentGraphScope.note(id: review.id, depth: 1)
        let withoutEvidence = try await reopened.graph(DocumentGraphQuery(scope: reviewScope))
        #expect(Set(withoutEvidence.nodes.map(\.id)) == [review.id, quote.id])
        #expect(withoutEvidence.diagnostics.map(\.destination) == ["metabrain-ref:bad"])
        let evidenceQuery = DocumentGraphQuery(scope: reviewScope, includeEvidence: true)
        let graph = try await reopened.graph(evidenceQuery)
        #expect(Set(graph.nodes.map(\.id)) == [review.id, quote.id, decision.documentID])
        let decisionGraph = try await reopened.graph(DocumentGraphQuery(
            scope: .note(id: decision.documentID, depth: 1), includeEvidence: true
        ))
        let connections = graph.connections.filter { $0.id.source == decision.documentID }
        #expect(Set(connections.map(\.id.relationship)) == [.supports, .contradicts])
        #expect(decisionGraph.connections == connections)
        for edge in connections {
            guard case .evidence(let evidence) = edge.occurrences.first else {
                Issue.record("Expected claim evidence.")
                continue
            }
            #expect(evidence.ref == ref)
            #expect(evidence.claimID == claim.id)
            #expect(evidence.state == .contested)
        }

        let moved = try DocumentPath("/project/archive/review.md")
        _ = try await reopened.moveDocument(.documentID(review.id), to: moved)
        #expect(try await reopened.graph(evidenceQuery).nodes.first?.path == moved)
        #expect(try await reopened.getEvidence(ref).items.first?.text == "The field result.")
        #expect(try await reopened.removeVersion(documentID: review.id, sequence: 1))
        #expect(try await reopened.graph(evidenceQuery).connections.filter { $0.id.source == decision.documentID } == connections)
        await #expect(throws: MetaBrainStoreError.documentVersionNotFound(reference: ref.rawValue, version: 1)) {
            try await reopened.getEvidence(ref)
        }

        let clear = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: decisionPath, body: "No claims.", claims: [])
        ])
        _ = try await reopened.applyOperation(reopened.inspectOperation(clear))
        #expect(try await reopened.graph(evidenceQuery).nodes.contains { $0.id == decision.documentID } == false)
        _ = try await reopened.deleteDocument(.documentID(quote.id))
        #expect(try await reopened.graph(evidenceQuery).nodes.map(\.id) == [review.id])
    }
}

@Test func graphReportsDisplayLimits() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let folder = try DocumentPath("/project")
        let inputs = try (0...DocumentGraph.nodeLimit).map { index in
            DocumentInput(path: try DocumentPath("/project/n-\(String(format: "%03d", index)).md"), body: "")
        }
        let operation = ProjectOperation(operationID: UUID(), project: folder, documents: inputs)
        _ = try await store.applyOperation(store.inspectOperation(operation))
        let graph = try await store.graph(DocumentGraphQuery(scope: .folder(path: folder), includeUnlinked: true))
        #expect(graph.nodes.count == DocumentGraph.nodeLimit)
        #expect(graph.truncated)

        let repeated = String(repeating: "[[/project/n-000.md]] ", count: DocumentGraph.occurrenceLimit + 1)
        let owner = try await store.putDocument(DocumentInput(path: DocumentPath("/project/owner.md"), body: repeated))
        let local = try await store.graph(DocumentGraphQuery(scope: .note(id: owner.id, depth: 1)))
        #expect(local.connections.first?.count == DocumentGraph.occurrenceLimit + 1)
        #expect(local.connections.first?.occurrences.count == DocumentGraph.occurrenceLimit)
        #expect(local.truncated)
    }
}

@Test func graphLimitsConnectionsAndDiagnosticsIndependently() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let folder = try DocumentPath("/project")
        let paths = try (0..<23).map { try DocumentPath("/project/\($0).md") }
        let operationID = UUID()
        let plan = ProjectOperation(operationID: operationID, project: folder, documents: [])
        let targets = paths.map { DocumentReference.documentID(plan.creationID(for: $0)) }
        let broken = String(repeating: "[[missing]] ", count: DocumentGraph.nodeLimit + 1)
        let inputs = paths.enumerated().map { index, path in
            DocumentInput(path: path, body: index == 0 ? broken : "", references: targets)
        }
        let operation = ProjectOperation(operationID: operationID, project: folder, documents: inputs)
        _ = try await store.applyOperation(store.inspectOperation(operation))

        let graph = try await store.graph(DocumentGraphQuery(scope: .folder(path: folder)))
        #expect(graph.nodes.count == 23)
        #expect(graph.connections.count == DocumentGraph.connectionLimit)
        #expect(graph.diagnostics.count == DocumentGraph.nodeLimit)
        #expect(graph.truncated)
    }
}

@Test func graphCanShowIndexedMarkdownWhileGraphMetadataIsAbsent() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let source = try await store.putDocument(DocumentInput(path: DocumentPath("/source.md"), body: ""))
        let note = try await store.putDocument(DocumentInput(path: DocumentPath("/note.md"), body: "[[source.md]]"))
        try await store.deleteRawValue(forKey: MetaBrainKeyspace.graphDocument(note.id))

        let graph = try await store.graph(DocumentGraphQuery(scope: .note(id: note.id, depth: 1), includeEvidence: true))
        #expect(graph.nodes.first?.id == note.id)
        #expect(graph.nodes.first?.title == nil)
        #expect(graph.connections.first?.id.target == source.id)
    }
}
