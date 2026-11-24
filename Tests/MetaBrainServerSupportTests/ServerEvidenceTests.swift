import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func citationRoutesReadMarkdownLinksAndHistoricalPassages() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-citations")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }
    let router = ServerRouter(storeServer: server)
    let source = ServerPutRequest(
        path: "/notes/source",
        body: "# Release\n\nThe rollback uses [[/notes/target.md#^step]]. ^proof\n"
    )
    let sourceReference = DocumentReferenceDTO(kind: .path, value: source.path)
    let target = ServerPutRequest(path: "/notes/target.md", body: "# Steps\n\nRoll back. ^step\n")
    let targetReference = DocumentReferenceDTO(kind: .path, value: target.path)

    let targetPut = try await citationPost(router, "/v1/put", target)
    #expect(targetPut.statusCode == 200)
    let markdownRequest = ServerMarkdownPutRequest(document: source, ifVersion: 0)
    let sourcePut = try await citationPost(router, "/v1/put-markdown", markdownRequest)
    #expect(sourcePut.statusCode == 200)
    let sourceOutput = try MetaBrainJSON.decoder().decode(PutOutput.self, from: sourcePut.body)
    let retry = try await citationPost(router, "/v1/put-markdown", markdownRequest)
    #expect(retry.statusCode == 200)
    let retryOutput = try MetaBrainJSON.decoder().decode(PutOutput.self, from: retry.body)
    #expect(retryOutput.status == "unchanged")
    #expect(retryOutput.version == sourceOutput.version)
    let conflict = try await citationPost(router, "/v1/put-markdown", ServerMarkdownPutRequest(
        document: ServerPutRequest(path: source.path, body: "A different write."),
        ifVersion: 0
    ))
    #expect(conflict.statusCode == 409)

    let outgoing = try await citationPost(router, "/v1/links", ServerLinksRequest(reference: sourceReference, block: "proof"))
    #expect(outgoing.statusCode == 200)
    let links = try MetaBrainJSON.decoder().decode([DocumentLinkOutput].self, from: outgoing.body)
    let link = try #require(links.first)
    #expect(links.count == 1)
    #expect(link.sourceID == sourceOutput.documentID)
    #expect(link.sourcePath == source.path)
    #expect(link.sourceVersion == 1)
    #expect(link.targetPath == target.path)
    #expect(link.status == .resolved)
    #expect(link.candidates == nil)

    let incoming = try await citationPost(router, "/v1/links", ServerLinksRequest(
        reference: targetReference, direction: .incoming, block: "step"
    ))
    #expect(incoming.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([DocumentLinkOutput].self, from: incoming.body) == links)

    let edit = try await citationPost(router, "/v1/put-conditional", ServerConditionalPutRequest(
        document: ServerPutRequest(path: source.path, body: "# New\n\nNew text. ^new\n"),
        ifVersion: 1,
        bodyOnly: true
    ))
    #expect(edit.statusCode == 200)
    let historical = try await citationPost(router, "/v1/get-passage", ServerGetPassageRequest(
        reference: sourceReference, block: "proof", version: 1
    ))
    #expect(historical.statusCode == 200)
    let passage = try MetaBrainJSON.decoder().decode(DocumentPassageOutput.self, from: historical.body)
    #expect(passage.documentID == sourceOutput.documentID)
    #expect(passage.path == source.path)
    #expect(passage.version == 1)
    #expect(passage.block == "proof")
    #expect(passage.text.contains("The rollback uses"))
    #expect(passage.end - passage.start == passage.text.count)

    let current = try await citationPost(router, "/v1/get-passage", ServerGetPassageRequest(
        reference: sourceReference, heading: "New"
    ))
    #expect(current.statusCode == 200)
    let currentPassage = try MetaBrainJSON.decoder().decode(DocumentPassageOutput.self, from: current.body)
    #expect(currentPassage.heading == "New")
    #expect(currentPassage.version == 2)

    let missing = try await citationPost(router, "/v1/get-passage", ServerGetPassageRequest(
        reference: sourceReference, block: "proof"
    ))
    #expect(missing.statusCode == 404)
    let invalid = try await citationPost(router, "/v1/get-passage", ServerGetPassageRequest(
        reference: sourceReference, block: "new", heading: "New"
    ))
    #expect(invalid.statusCode == 400)

    for path in ["/alpha/Shared.md", "/beta/Shared.md"] {
        let put = try await citationPost(router, "/v1/put", ServerPutRequest(path: path, body: "Shared title"))
        #expect(put.statusCode == 200)
    }
    let ambiguousPath = "/notes/ambiguous.md"
    let ambiguousPut = try await citationPost(router, "/v1/put", ServerPutRequest(path: ambiguousPath, body: "[[Shared]]"))
    #expect(ambiguousPut.statusCode == 200)
    let ambiguous = try await citationPost(router, "/v1/links", ServerLinksRequest(
        reference: DocumentReferenceDTO(kind: .path, value: ambiguousPath)
    ))
    #expect(ambiguous.statusCode == 200)
    let ambiguousLinks = try MetaBrainJSON.decoder().decode([DocumentLinkOutput].self, from: ambiguous.body)
    let ambiguousLink = try #require(ambiguousLinks.first)
    #expect(ambiguousLink.status == .ambiguous)
    #expect(Set(ambiguousLink.candidates?.map(\.path) ?? []) == ["/alpha/Shared.md", "/beta/Shared.md"])
}

@Test func evidenceRoutesUseCompactBudgetedJSONAndReplayReferences() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-evidence")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }
    let router = ServerRouter(storeServer: server)
    let document = ServerPutRequest(
        path: "/notes/runbook.md", body: "# Release\n\nRoll back the café migration.\n", tags: ["runbook"]
    )
    let put = try await citationPost(router, "/v1/put", document)
    #expect(put.statusCode == 200)

    let query = "café"
    let budget = 256
    let response = try await citationPost(router, "/v1/search-evidence", ServerEvidenceSearchRequest(
        query: query, view: .evidence, maxTokens: budget
    ))
    #expect(response.statusCode == 200)
    #expect(response.body.count + 1 <= budget)
    let result = try MetaBrainJSON.decoder().decode(EvidenceOutput.self, from: response.body)
    let evidence = try #require(result.items.first)
    #expect(evidence.path == document.path)
    #expect(evidence.text?.contains(query) == true)
    #expect(try result.jsonData() == response.body)

    let read = try await citationPost(router, "/v1/get-ref", ServerGetEvidenceRequest(ref: evidence.ref, maxTokens: budget))
    #expect(read.statusCode == 200)
    let replay = try MetaBrainJSON.decoder().decode(EvidenceOutput.self, from: read.body)
    #expect(replay.items.first == evidence)
    #expect(try replay.jsonData() == read.body)

    let refsResponse = try await citationPost(router, "/v1/search-evidence", ServerEvidenceSearchRequest(
        tags: ["runbook"], view: .refs, maxTokens: budget
    ))
    #expect(refsResponse.statusCode == 200)
    let refs = try MetaBrainJSON.decoder().decode(EvidenceOutput.self, from: refsResponse.body)
    #expect(refs.items.first?.path == document.path)
    #expect(refs.items.first?.text == nil)

    let minimum = EvidenceOutput.minimumMaxTokens
    let bounded = try await citationPost(router, "/v1/search-evidence", ServerEvidenceSearchRequest(
        query: query, view: .evidence, maxTokens: minimum
    ))
    #expect(bounded.statusCode == 200)
    #expect(bounded.body.count + 1 <= minimum)
    #expect(try MetaBrainJSON.decoder().decode(EvidenceOutput.self, from: bounded.body).truncated)
    let invalid = try await citationPost(router, "/v1/get-ref", ServerGetEvidenceRequest(
        ref: evidence.ref, maxTokens: minimum - 1
    ))
    #expect(invalid.statusCode == 400)
    let missingBlock = try EvidenceReference("\(evidence.ref.documentID)@1#^missing")
    let missing = try await citationPost(router, "/v1/get-ref", ServerGetEvidenceRequest(ref: missingBlock))
    #expect(missing.statusCode == 404)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: missing.body).error == "evidence_block_not_found")

    let legacy = try await citationPost(router, "/v1/search", ServerSearchRequest(query: query))
    #expect(legacy.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([SearchOutput].self, from: legacy.body).first?.path == document.path)
}

@Test func markdownClientReportsUnsupportedDaemons() throws {
    let codec = ServerHTTPCodec()
    let document = ServerPutRequest(path: "/extensionless", body: "[[reference]]")
    let request = ServerMarkdownPutRequest(document: document, ifVersion: 0)
    let client = MetaBrainServerClient { data in
        let wireRequest = try codec.parseRequest(data)
        #expect(wireRequest.method == .post)
        #expect(wireRequest.path == "/v1/put-markdown")
        #expect(try MetaBrainJSON.decoder().decode(ServerMarkdownPutRequest.self, from: wireRequest.body) == request)
        let body = try MetaBrainJSON.encoder().encode(ServerErrorPayload(error: "not_found", message: "Unknown route."))
        return codec.serializeResponse(ServerHTTPResponse(statusCode: 404, body: body))
    }
    #expect(throws: ServerClientError.citationOperationUnsupported("put --markdown")) {
        try client.putMarkdown(request)
    }
}

private func citationPost(
    _ router: ServerRouter, _ route: String, _ request: some Encodable
) async throws -> ServerHTTPResponse {
    let data = try MetaBrainJSON.encoder().encode(request)
    return await router.route(ServerHTTPRequest(method: .post, path: route, body: data))
}
