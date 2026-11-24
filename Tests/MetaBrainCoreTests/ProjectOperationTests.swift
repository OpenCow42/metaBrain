import Foundation
import Testing
@testable import MetaBrainCore

@Test func projectOperationCommitsLinkedDecisionAndSourcesInOrder() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/projects/atlas")
        let decision = try DocumentPath("/projects/atlas/decision.md")
        let first = try DocumentPath("/projects/atlas/reviews/local.md")
        let second = try DocumentPath("/projects/atlas/reviews/server.md")
        let log = try DocumentPath("/projects/atlas/log.md")
        let firstClaim = "The storage review favors local durability."
        let secondClaim = "The storage review favors server replication."
        let decisionBody = "Compare [[reviews/local#^recommendation]] with [[reviews/server#^recommendation]]."
        let watcher = try await store.putDocument(DocumentInput(
            path: DocumentPath("/outside/watch.md"), body: "Await [[/projects/atlas/reviews/local#^recommendation]]."
        ))
        #expect(try await store.links(for: .documentID(watcher.id)).map(\.status) == [.unresolved])
        let documents = [
            DocumentInput(path: decision, body: decisionBody),
            DocumentInput(path: second, body: secondClaim + " ^recommendation"),
            DocumentInput(path: first, body: firstClaim + " ^recommendation"),
            DocumentInput(path: log, body: "Recorded [[decision]].", references: [.path(second)])
        ]
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: documents)
        let preview = try await store.inspectOperation(operation)
        #expect(preview.targets.map(\.path) == documents.map(\.path))
        #expect(preview.targets.allSatisfy { $0.version == 0 && $0.documentID == nil })
        #expect(try await store.listDirectory(path: project, recursive: true).isEmpty)

        let receipt = try await store.applyOperation(preview)
        #expect(receipt.operationID == operation.operationID)
        #expect(receipt.digest == preview.digest)
        #expect(receipt.results.map(\.path) == documents.map(\.path))
        #expect(receipt.results.map(\.status) == [.created, .created, .created, .created])
        #expect(receipt.results.map(\.version) == [1, 1, 1, 1])
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let tree = try await reopened.tree(TreeQuery(path: project))
        let actualPaths = tree.filter { $0.documentID != nil }.map(\.path)
        #expect(Set(actualPaths) == Set(documents.map(\.path)))
        #expect(actualPaths.count == documents.count)
        #expect(try await reopened.searchCorpusDocumentCount() == documents.count + 1)
        let links = try await reopened.links(for: .path(decision))
        let firstResult = try #require(receipt.results.first { $0.path == first })
        let secondResult = try #require(receipt.results.first { $0.path == second })
        #expect(links.map(\.status) == [.resolved, .resolved])
        #expect(links.map(\.targetID) == [firstResult.documentID, secondResult.documentID])
        #expect(try await reopened.links(for: .documentID(watcher.id)).map(\.targetID) == [firstResult.documentID])
        #expect(try await reopened.links(for: .path(first), direction: .incoming).count == 2)
        #expect(try await reopened.links(for: .path(decision), direction: .incoming).count == 1)
        let logResult = try #require(receipt.results.last)
        #expect(try await reopened.outboundReferences(from: logResult.documentID).contains(secondResult.documentID))
        #expect(try await reopened.inboundReferences(to: secondResult.documentID).contains(logResult.documentID))

        let evidence = try await reopened.searchEvidence(
            SearchQuery(text: "storage", pathPrefix: project), view: .refs
        )
        #expect(Set(evidence.items.map(\.ref.documentID)) == [firstResult.documentID, secondResult.documentID])
        let firstReference = try EvidenceReference("\(firstResult.documentID.rawValue)@1#^recommendation")
        let secondReference = try EvidenceReference("\(secondResult.documentID.rawValue)@1#^recommendation")
        #expect(try await reopened.getEvidence(firstReference).items.first?.text == firstClaim)
        #expect(try await reopened.getEvidence(secondReference).items.first?.text == secondClaim)
        let revision = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: decision, body: "Revised decision. " + decisionBody)
        ])
        let reviewedRevision = try await reopened.inspectOperation(revision)
        #expect(try await reopened.applyOperation(reviewedRevision).results.map(\.status) == [.updated])
        #expect(try await reopened.links(for: .path(decision)).map(\.targetID) == [firstResult.documentID, secondResult.documentID])
        _ = try await reopened.putDocument(DocumentInput(path: first, body: "The recommendation changed."))
        let moved = try DocumentPath("/projects/atlas/reviews/revised.md")
        _ = try await reopened.moveDocument(.path(first), to: moved)
        #expect(try await reopened.getDocument(.documentID(firstResult.documentID), trackingRead: false)?.path == moved)
        #expect(try await reopened.getEvidence(firstReference).items.first?.text == firstClaim)
    }
}

@Test(arguments: ["update", "replace", "move", "create"])
func projectOperationRejectsStaleTargetWithoutWritingOtherDocuments(change: String) async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let guarded = try DocumentPath("/atlas/review.md")
        let new = try DocumentPath("/atlas/decision.md")
        let previous: StoredDocument? = if change == "create" {
            nil
        } else {
            try await store.putDocument(DocumentInput(path: guarded, body: "Before"))
        }
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: new, body: "Decision"),
            DocumentInput(path: guarded, body: "After")
        ])
        let preview = try await store.inspectOperation(operation)

        switch change {
        case "update":
            _ = try await store.putDocument(DocumentInput(path: guarded, body: "Concurrent edit"))
        case "replace":
            #expect(try await store.deleteDocument(.path(guarded)))
            let replacement = try await store.putDocument(DocumentInput(path: guarded, body: "Replacement"))
            #expect(replacement.id != previous?.id)
            #expect(replacement.currentVersion == previous?.currentVersion)
        case "move":
            _ = try await store.moveDocument(.path(guarded), to: DocumentPath("/atlas/moved.md"))
        default:
            _ = try await store.putDocument(DocumentInput(path: guarded, body: "Concurrent create"))
        }
        let concurrent = try await store.getDocument(.path(guarded), trackingRead: false)
        await #expect(throws: ProjectOperationError.conflict("A target document changed after inspection. Inspect the operation again.")) {
            try await store.applyOperation(preview)
        }
        #expect(try await store.getDocument(.path(new), trackingRead: false) == nil)
        #expect(try await store.getDocument(.path(guarded), trackingRead: false) == concurrent)
        let retry = try await store.inspectOperation(operation)
        #expect(try await store.applyOperation(retry).results.first?.status == .created)
    }
}

@Test func projectOperationFailureAfterPreparingOneWriteLeavesNoChangesOrReceipt() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let corrupt = try DocumentPath("/atlas/corrupt")
        let new = try DocumentPath("/atlas/new")
        let original = try await store.putDocument(DocumentInput(path: corrupt, body: "Original"))
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: new, body: "Prepared"),
            DocumentInput(path: corrupt, body: "Updated")
        ])
        let documentKey = MetaBrainKeyspace.document(id: original.id)
        let originalDocument = try #require(try await store.rawValue(forKey: documentKey))
        try await store.deleteRawValue(forKey: documentKey)
        await #expect(throws: MetaBrainStoreError.operationFailed(message: "Invalid document record at /atlas/corrupt.")) {
            try await store.inspectOperation(operation)
        }
        try await store.writeRawValue(originalDocument, forKey: documentKey)
        let preview = try await store.inspectOperation(operation)
        let versionKey = MetaBrainKeyspace.version(id: original.id, sequence: 1)
        let originalVersion = try #require(try await store.rawValue(forKey: versionKey))
        try await store.writeRawValue(Data([0]), forKey: versionKey)
        await #expect(throws: (any Error).self) {
            try await store.applyOperation(preview)
        }
        #expect(try await store.getDocument(.path(new), trackingRead: false) == nil)
        #expect(try await store.getDocument(.path(corrupt), trackingRead: false) == original)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.operationReceipt(operation.operationID)) == nil)

        try await store.writeRawValue(originalVersion, forKey: versionKey)
        #expect(try await store.applyOperation(preview).results.map(\.status) == [.created, .updated])
    }
}

@Test func projectOperationRetriesPersistOriginalResultAfterReopenAndWrites() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let updated = try DocumentPath("/atlas/decision.md")
        let unchanged = try DocumentPath("/atlas/log.md")
        let stable = DocumentInput(path: unchanged, body: "Log")
        let old = try await store.putDocument(DocumentInput(path: updated, body: "Before"))
        let log = try await store.putDocument(stable)
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: updated, body: "After"), stable
        ])
        let preview = try await store.inspectOperation(operation)
        #expect(preview.targets.map(\.documentID) == [old.id, log.id])
        #expect(preview.targets.map(\.version) == [1, 1])
        let receipt = try await store.applyOperation(preview)
        #expect(receipt.results.map(\.status) == [.updated, .unchanged])
        #expect(receipt.results.map(\.version) == [2, 1])
        #expect(receipt.results.map(\.documentID) == [old.id, log.id])
        #expect(try await store.applyOperation(preview) == receipt)
        #expect(try await store.listVersions(of: .path(updated)).count == 2)
        #expect(try await store.listVersions(of: .path(unchanged)).count == 1)
        #expect(try await store.searchCorpusDocumentCount() == 2)
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/other/notice"), body: "Unrelated"))
        _ = try await store.putDocument(DocumentInput(path: updated, body: "Revised after commit"))
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.applyOperation(preview) == receipt)
        #expect(try await reopened.getDocument(.path(updated), trackingRead: false)?.body == "Revised after commit")
        let altered = ProjectOperation(operationID: operation.operationID, project: project, documents: [
            DocumentInput(path: updated, body: "Reused operation identifier")
        ])
        await #expect(throws: ProjectOperationError.conflict("The operation ID was already used with a different preview.")) {
            let alteredPreview = try await reopened.inspectOperation(altered)
            _ = try await reopened.applyOperation(alteredPreview)
        }
    }
}

@Test func projectOperationPreservesTreeAndRefreshesReferencesInMixedBatch() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let folder = try DocumentPath("/atlas/reviews")
        let source = try DocumentPath("/atlas/reviews/overview")
        let target = try DocumentPath("/atlas/reviews/new")
        let oldChild = try DocumentPath("/atlas/reviews/existing")
        let stable = DocumentInput(path: source, body: "Overview", references: [.path(target)])
        let oldSource = try await store.putDocument(stable)
        let oldFolder = try await store.putDocument(DocumentInput(path: folder, body: "Old folder note"))
        let existing = try await store.putDocument(DocumentInput(path: oldChild, body: "Existing child"))
        #expect(try await store.outboundReferences(from: oldSource.id).isEmpty)

        let documents = [
            stable,
            DocumentInput(path: target, body: "New child"),
            DocumentInput(path: folder, body: "New folder note")
        ]
        let preview = try await store.inspectOperation(
            ProjectOperation(operationID: UUID(), project: project, documents: documents)
        )
        let receipt = try await store.applyOperation(preview)
        #expect(receipt.results.map(\.status) == [.unchanged, .created, .updated])
        let newDocument = try #require(receipt.results.first { $0.path == target })
        #expect(try await store.outboundReferences(from: oldSource.id) == [newDocument.documentID])
        #expect(try await store.inboundReferences(to: newDocument.documentID) == [oldSource.id])
        let tree = try await store.tree(TreeQuery(path: project))
        let branch = try #require(tree.first { $0.path == folder })
        #expect(branch.hasChildren)
        #expect(branch.documentID == oldFolder.id)
        #expect(Set(tree.compactMap(\.documentID)) == [oldSource.id, oldFolder.id, existing.id, newDocument.documentID])
        #expect(try await store.searchCorpusDocumentCount() == 4)

        let addChild = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: try DocumentPath("/atlas/reviews/another"), body: "Another child")
        ])
        let reviewedChild = try await store.inspectOperation(addChild)
        #expect(try await store.applyOperation(reviewedChild).results.map(\.status) == [.created])
        #expect(try await store.tree(TreeQuery(path: project)).first { $0.path == folder } == branch)
    }
}

@Test func projectOperationRejectsInvalidScopeAndTamperedOrForeignPreviews() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let other = try MetaBrainStore(url: fixture.rootURL.appendingPathComponent("other.leveldb"))
        let project = try DocumentPath("/atlas")
        let note = DocumentInput(path: try DocumentPath("/atlas/decision.md"), body: "Decision")
        let lookalike = DocumentInput(path: try DocumentPath("/atlas-other/decision.md"), body: "Foreign")
        for documents in [[], [note, note], [note, lookalike]] {
            await #expect(throws: (any Error).self) {
                try await store.inspectOperation(ProjectOperation(operationID: UUID(), project: project, documents: documents))
            }
        }
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [note])
        let preview = try await store.inspectOperation(operation)
        let tamperedDigest = OperationPreview(
            operation: operation, storePath: preview.storePath, storeIdentity: preview.storeIdentity, targets: preview.targets, digest: "invalid"
        )
        var changed = note
        changed.body = "Modified after inspection"
        let tamperedBody = OperationPreview(
            operation: ProjectOperation(operationID: operation.operationID, project: project, documents: [changed]),
            storePath: preview.storePath, storeIdentity: preview.storeIdentity, targets: preview.targets, digest: preview.digest
        )
        for invalid in [tamperedDigest, tamperedBody] {
            await #expect(throws: (any Error).self) { try await store.applyOperation(invalid) }
        }
        await #expect(throws: ProjectOperationError.conflict("The preview identifies a different store.")) {
            try await other.applyOperation(preview)
        }
        #expect(try await store.getDocument(.path(note.path), trackingRead: false) == nil)
        #expect(try await other.getDocument(.path(note.path), trackingRead: false) == nil)
        #expect(try await store.applyOperation(preview).results.first?.status == .created)
    }
}

@Test func projectOperationUsesAllNewTargetsWhenResolvingNames() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let root = try DocumentPath("/atlas")
        let watcher = try await store.putDocument(DocumentInput(
            path: DocumentPath("/outside/watch.md"), body: "Await [[review]]."
        ))
        let operation = ProjectOperation(operationID: UUID(), project: root, documents: [
            DocumentInput(path: try DocumentPath("/atlas/local/review.md"), body: "Local review"),
            DocumentInput(path: try DocumentPath("/atlas/server/review.md"), body: "Server review"),
            DocumentInput(path: try DocumentPath("/atlas/decision.md"), body: "Read [[review]].")
        ])
        let preview = try await store.inspectOperation(operation)
        let receipt = try await store.applyOperation(preview)
        let decision = try #require(receipt.results.last)
        let expected = Set(receipt.results.prefix(2).map(\.documentID))
        for source in [watcher.id, decision.documentID] {
            let link = try #require(try await store.links(for: .documentID(source)).first)
            #expect(link.status == .ambiguous)
            #expect(link.targetID == nil)
            #expect(Set(link.candidates.map(\.documentID)) == expected)
        }
    }
}

@Test func projectOperationValidationRejectsDecodedNoncanonicalPaths() throws {
    #expect(ProjectOperationError.invalid("Invalid preview").description == "Invalid preview")
    #expect(ProjectOperationError.conflict("Target conflict").description == "Target conflict")
    let project = try DocumentPath("/atlas")
    let root = try DocumentPath("/")
    let note = DocumentInput(path: try DocumentPath("/atlas/note"), body: "Note")
    let operationID = UUID()
    #expect(throws: ProjectOperationError.invalid("Select a project below / and at least one document.")) {
        try ProjectOperation(operationID: operationID, project: root, documents: [note]).validate()
    }
    for rawPath in ["/atlas/../outside", "/atlas//note", "/atlas/./note"] {
        let data = try JSONEncoder().encode(["rawValue": rawPath])
        let decodedPath = try JSONDecoder().decode(DocumentPath.self, from: data)
        let invalid = DocumentInput(path: decodedPath, body: "Invalid")
        #expect(throws: ProjectOperationError.invalid("Expected a unique document path under /atlas: \(rawPath)")) {
            try ProjectOperation(operationID: operationID, project: project, documents: [invalid]).validate()
        }
    }
    let projectData = Data(#"{"rawValue":"/atlas/."}"#.utf8)
    let invalidProject = try JSONDecoder().decode(DocumentPath.self, from: projectData)
    #expect(throws: ProjectOperationError.invalid("Select a project below / and at least one document.")) {
        try ProjectOperation(operationID: operationID, project: invalidProject, documents: [note]).validate()
    }
}

@Test func projectOperationPreviewChecksTargetPathsOrderAndIdentityBeforeDigest() throws {
    let project = try DocumentPath("/atlas")
    let first = try DocumentPath("/atlas/first")
    let second = try DocumentPath("/atlas/second")
    let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
        DocumentInput(path: first, body: "First", metadata: ["z": "Z", "a": "A"]),
        DocumentInput(path: second, body: "Second")
    ])
    let id = try DocumentID(rawValue: "document")
    let existing = OperationTarget(path: first, documentID: id, version: 1)
    let absent = OperationTarget(path: second, documentID: nil, version: 0)
    let storePath = "/test/store.leveldb"
    let storeIdentity = UUID()
    let valid = try OperationPreview.make(operation: operation, storePath: storePath, storeIdentity: storeIdentity, targets: [existing, absent])
    try valid.verify()
    #expect(valid.digest.count == 64)
    let encoded = try JSONEncoder().encode(valid)
    let decoded = try JSONDecoder().decode(OperationPreview.self, from: encoded)
    #expect(decoded == valid)
    try decoded.verify()

    let malformedTargets = [
        [existing],
        [absent, existing],
        [existing, OperationTarget(path: second, documentID: nil, version: 4)],
        [OperationTarget(path: first, documentID: id, version: 0), absent]
    ]
    for targets in malformedTargets {
        let preview = try OperationPreview.make(operation: operation, storePath: storePath, storeIdentity: storeIdentity, targets: targets)
        #expect(throws: ProjectOperationError.invalid("The inspected targets do not match the proposed writes.")) {
            try preview.verify()
        }
    }
}

@Test func projectOperationSerializesConcurrentRetriesAndCompetingPreviews() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let shared = try DocumentPath("/atlas/shared.md")
        let first = try DocumentPath("/atlas/first.md")
        let second = try DocumentPath("/atlas/second.md")
        let firstPreview = try await store.inspectOperation(ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: first, body: "First only"),
            DocumentInput(path: shared, body: "First winner")
        ]))
        let secondPreview = try await store.inspectOperation(ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: second, body: "Second only"),
            DocumentInput(path: shared, body: "Second winner")
        ]))
        async let initial = try? store.applyOperation(firstPreview)
        async let duplicate = try? store.applyOperation(firstPreview)
        async let competitor = try? store.applyOperation(secondPreview)
        async let competitorRetry = try? store.applyOperation(secondPreview)
        let (firstResult, duplicateResult, secondResult, secondRetry) =
            await (initial, duplicate, competitor, competitorRetry)
        #expect(firstResult == duplicateResult)
        #expect(secondResult == secondRetry)
        #expect((firstResult != nil) != (secondResult != nil))
        #expect(try await store.listVersions(of: .path(shared)).count == 1)
        #expect(try await store.getDocument(.path(first), trackingRead: false)?.body == (firstResult == nil ? nil : "First only"))
        #expect(try await store.getDocument(.path(second), trackingRead: false)?.body == (secondResult == nil ? nil : "Second only"))
        #expect(try await store.getDocument(.path(shared), trackingRead: false)?.body == (firstResult == nil ? "Second winner" : "First winner"))
    }
}

@Test func projectOperationRejectsReusingACreationIDAfterMovingTheDocument() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let path = try DocumentPath("/atlas/report.md")
        let destination = try DocumentPath("/atlas/archived-report.md")
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: path, body: "Review.")
        ])
        let preview = try await store.inspectOperation(operation)
        let receipt = try await store.applyOperation(preview)
        let moved = try await store.moveDocument(.path(path), to: destination).document

        await #expect(throws: ProjectOperationError.conflict("A planned creation ID already belongs to a document.")) {
            try await store.inspectOperation(operation)
        }
        #expect(moved.id == operation.creationID(for: path))
        #expect(try await store.getDocument(.path(path), trackingRead: false) == nil)
        #expect(try await store.getDocument(.path(destination), trackingRead: false) == moved)
        #expect(try await store.applyOperation(preview) == receipt)
    }
}
