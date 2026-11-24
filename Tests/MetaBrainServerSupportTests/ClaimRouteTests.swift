import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func claimRoutesExposeCurrentAndRetainedMetadataAndLintMissingEvidence() async throws {
    let directory = try temporaryServerDirectory(prefix: "mbd-claims")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try MetaBrainStoreServer(storePath: directory.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }
    let router = ServerRouter(storeServer: server)

    let project = try DocumentPath("/projects/review")
    let path = try DocumentPath("/projects/review/decision")
    let sourcePath = try DocumentPath("/projects/review/analysis.md")
    let profile = ClaimSourceProfile(status: .active, synthetic: false, independenceGroup: "analysis",
                                     freshUntil: Date(timeIntervalSince1970: 4_000_000_000))
    let sourceOperation = ProjectOperation(operationID: UUID(), project: project, documents: [
        DocumentInput(path: sourcePath, body: "Original analysis", sourceProfile: profile)
    ])
    let sourceReceipt = try await applyClaimOperation(router, sourceOperation)
    let source = try #require(sourceReceipt.results.first)
    let evidenceRef = try EvidenceReference("\(source.documentID)@1#0-4")
    let claimID = UUID()
    let claim = ProjectClaim(id: claimID, text: "The proposed change is reversible.", state: .accepted,
                             evidence: [ClaimEvidence(relation: .supports, ref: evidenceRef)])
    let operation = ProjectOperation(
        operationID: UUID(), project: project, documents: [DocumentInput(path: path, body: "First decision", claims: [claim])]
    )
    _ = try await applyClaimOperation(router, operation)

    let claimReference = DocumentReferenceDTO(.path(path))
    let sourceReference = DocumentReferenceDTO(.path(sourcePath))
    let getClaim = try await claimPost(router, "/v1/get", ServerGetRequest(reference: claimReference, trackingRead: false))
    #expect(getClaim.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: getClaim.body).claims == [claim])
    let getSource = try await claimPost(router, "/v1/get", ServerGetRequest(reference: sourceReference, trackingRead: false))
    #expect(getSource.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: getSource.body).sourceProfile == profile)

    let getClaimVersion = try await claimPost(router, "/v1/get-version", ServerGetDocumentVersionRequest(
        reference: claimReference, version: 1
    ))
    #expect(getClaimVersion.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: getClaimVersion.body).claims == [claim])
    let getSourceVersion = try await claimPost(router, "/v1/get-version", ServerGetDocumentVersionRequest(
        reference: sourceReference, version: 1
    ))
    #expect(getSourceVersion.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: getSourceVersion.body).sourceProfile == profile)

    let deleted = try await claimPost(router, "/v1/delete", ServerDeleteRequest(reference: sourceReference))
    #expect(deleted.statusCode == 200)
    let lint = try await claimPost(router, "/v1/lint", ServerLintRequest(path: project.rawValue))
    #expect(lint.statusCode == 200)
    let report = try MetaBrainJSON.decoder().decode(DocumentLintReport.self, from: lint.body)
    let issue = try #require(report.findings.first { $0.evidenceIssue == .missing })
    #expect(report.documentsChecked == 1)
    #expect(report.counts["claimEvidence"] == 2)
    #expect(issue.kind == .claimEvidence)
    #expect(issue.sourcePath == path.rawValue)
    #expect(issue.sourceVersion == 1)
    #expect(issue.claimID == claimID)
    #expect(issue.evidenceRef == evidenceRef)
    #expect(issue.message?.isEmpty == false)
    let insufficiency = try #require(report.findings.first { $0.evidenceIssue == .insufficient })
    #expect(insufficiency.evidenceRef == nil)
}

private func applyClaimOperation(_ router: ServerRouter, _ operation: ProjectOperation) async throws -> OperationReceipt {
    let inspected = try await claimPost(router, "/v1/operation-inspect", operation)
    try #require(inspected.statusCode == 200, Comment(rawValue: inspected.bodyText))
    let preview = try MetaBrainJSON.decoder().decode(OperationPreview.self, from: inspected.body)
    let applied = try await claimPost(router, "/v1/operation-apply", preview)
    try #require(applied.statusCode == 200, Comment(rawValue: applied.bodyText))
    return try MetaBrainJSON.decoder().decode(OperationReceipt.self, from: applied.body)
}

private func claimPost(
    _ router: ServerRouter, _ path: String, _ payload: some Encodable
) async throws -> ServerHTTPResponse {
    let body = try MetaBrainJSON.encoder().encode(payload)
    return await router.route(ServerHTTPRequest(method: .post, path: path, body: body))
}
