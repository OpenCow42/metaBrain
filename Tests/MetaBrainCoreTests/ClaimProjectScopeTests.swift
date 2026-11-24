import Foundation
import Testing
@testable import MetaBrainCore

@Test func claimLintKeepsTheReviewProjectAcrossOwnerAndSourceMoves() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let sourcePath = try DocumentPath("/atlas/source")
        let ownerPath = try DocumentPath("/atlas/decision")
        let sourceBody = "Verified finding"
        let profile = ClaimSourceProfile(
            status: .active, synthetic: false, independenceGroup: "Field review",
            freshUntil: Date().addingTimeInterval(86_400)
        )
        let source = try await store.putDocument(DocumentInput(
            path: sourcePath, body: sourceBody, sourceProfile: profile
        ))
        let reference = try EvidenceReference("\(source.id)@1#0-\(sourceBody.count)")
        let claim = ProjectClaim(id: UUID(), text: sourceBody, state: .accepted, evidence: [
            ClaimEvidence(relation: .supports, ref: reference)
        ])
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: ownerPath, body: "Decision", claims: [claim])
        ])
        let receipt = try await store.applyOperation(store.inspectOperation(operation))
        let owner = try #require(receipt.results.first?.documentID)

        let movedOwnerPath = try DocumentPath("/decisions/atlas")
        _ = try await store.moveDocument(.documentID(owner), to: movedOwnerPath)
        _ = try await store.moveDocument(.documentID(source.id), to: DocumentPath("/atlas/reviews/source"))
        let beforeMove = try await store.lint(DocumentLintQuery(path: movedOwnerPath))
        #expect(beforeMove.documentsChecked == 1)
        #expect(beforeMove.findings.isEmpty)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let externalPath = try DocumentPath("/atlas-other/source")
        _ = try await reopened.moveDocument(.documentID(source.id), to: externalPath)
        let report = try await reopened.lint(DocumentLintQuery(path: movedOwnerPath))
        #expect(report.documentsChecked == 1)
        let finding = try #require(report.findings.first { $0.evidenceIssue == .invalid })
        #expect(finding.claimID == claim.id)
        #expect(finding.evidenceRef == reference)
        #expect(finding.message?.contains(project.rawValue) == true)
        #expect(finding.message?.contains(externalPath.rawValue) == true)

        let clearClaims = ProjectOperation(
            operationID: UUID(), project: try DocumentPath("/decisions"),
            documents: [DocumentInput(path: movedOwnerPath, body: "Decision", claims: [])]
        )
        _ = try await reopened.applyOperation(reopened.inspectOperation(clearClaims))
        let versions = try await reopened.listVersions(of: .documentID(owner))
        #expect(versions.first { $0.sequence == 1 }?.claimProject == project)
        #expect(versions.first { $0.sequence == 2 }?.claimProject == project)
        let latest = try #require(versions.first { $0.sequence == 3 })
        #expect(latest.claimProject == nil)
        #expect(latest.snapshot.claims == [])
    }
}
