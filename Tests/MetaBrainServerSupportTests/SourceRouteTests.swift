import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func sourceRoutesStageAndReadOriginalBytesThroughAReviewedDocument() async throws {
    let directory = try temporaryServerDirectory(prefix: "mbd-source")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try MetaBrainStoreServer(storePath: directory.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }
    let router = ServerRouter(storeServer: server)
    let stagePath = "/v1/source-stage-chunk"
    let finishPath = "/v1/source-finish-blob"
    let descriptorPath = "/v1/source-descriptor"
    let readPath = "/v1/source-chunk"
    for path in [stagePath, finishPath, descriptorPath, readPath] {
        let response = await router.route(ServerHTTPRequest(method: .get, path: path))
        #expect(response.statusCode == 405)
        #expect(response.headers["Allow"] == "POST")
    }

    let bytes = Data([0x00, 0xff, 0x68, 0xc3, 0xff])
    let staged = try await sourcePost(router, stagePath, ServerSourceChunk(bytes: bytes))
    #expect(staged.statusCode == 200)
    let digest = try MetaBrainJSON.decoder().decode(ServerSourceChunkDigest.self, from: staged.body)
    let finished = try await sourcePost(router, finishPath, ServerSourceFinishRequest(chunks: [digest.sha256]))
    #expect(finished.statusCode == 200)
    let blob = try MetaBrainJSON.decoder().decode(SourceBlob.self, from: finished.body)
    #expect(blob.sha256 == digest.sha256)
    #expect(blob.byteCount == bytes.count)

    let path = try DocumentPath("/projects/demo/binary.md")
    let reference = DocumentReferenceDTO(.path(path))
    let descriptorRequest = ServerSourceDescriptorRequest(reference: reference, version: nil)
    let missing = try await sourcePost(router, descriptorPath, descriptorRequest)
    #expect(missing.statusCode == 404)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: missing.body).error == "document_not_found")

    let capture = SourceCapture(
        blob: blob, filename: "binary.dat", mediaType: "application/octet-stream", origin: "local fixture"
    )
    let operation = ProjectOperation(
        operationID: UUID(), project: try DocumentPath("/projects/demo"),
        documents: [DocumentInput(path: path, body: "", sourceCapture: capture)]
    )
    let preview = try await server.inspectOperation(operation)
    let receipt = try await server.applyOperation(preview)
    let result = try #require(receipt.results.first)

    let recorded = try await sourcePost(router, descriptorPath, descriptorRequest)
    #expect(recorded.statusCode == 200)
    let descriptor = try MetaBrainJSON.decoder().decode(SourceDescriptor.self, from: recorded.body)
    #expect(descriptor.capture == capture)
    #expect(descriptor.documentID == result.documentID)
    #expect(descriptor.version == result.version)

    let current = try await sourcePost(router, "/v1/get", ServerGetRequest(reference: reference, trackingRead: false))
    #expect(current.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: current.body).sourceCapture == capture)

    let historical = try await sourcePost(router, "/v1/get-version", ServerGetDocumentVersionRequest(
        reference: reference, version: descriptor.version
    ))
    #expect(historical.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: historical.body).sourceCapture == capture)

    let id = DocumentReferenceDTO(.documentID(descriptor.documentID))
    let recovered = try await sourcePost(router, readPath, ServerSourceReadRequest(
        reference: id, version: descriptor.version, index: 0
    ))
    #expect(recovered.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(ServerSourceChunk.self, from: recovered.body).bytes == bytes)

    let pastEnd = try await sourcePost(router, readPath, ServerSourceReadRequest(
        reference: id, version: descriptor.version, index: 1
    ))
    #expect(pastEnd.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: pastEnd.body).error == "invalid_request")
}

@Test func getOutputDecodesLegacyResponsesWithoutCaptureOrClaims() throws {
    let legacy = Data("""
    {"body":"Legacy note","createdAt":"2026-01-02T00:00:00Z","documentID":"legacy","metadata":{},"path":"/legacy.md","references":[],"tags":[],"title":null,"updatedAt":"2026-01-02T00:00:00Z","version":1}
    """.utf8)
    let output = try MetaBrainJSON.decoder().decode(GetOutput.self, from: legacy)
    #expect(output.sourceCapture == nil)
    #expect(output.claims == nil)
    #expect(output.sourceProfile == nil)
    #expect(try MetaBrainJSON.encoder().encode(output) == legacy)
}

@Test func sourceClientDistinguishesUnavailableRoutesFromMissingDocuments() throws {
    let codec = ServerHTTPCodec()
    let reference = DocumentReference.path(try DocumentPath("/projects/demo/missing.md"))
    let legacy = MetaBrainServerClient { bytes in
        let request = try codec.parseRequest(bytes)
        if request.path == "/v1/source-stage-chunk" {
            return codec.serializeResponse(ServerHTTPResponse(statusCode: 404, body: Data("unknown route".utf8)))
        }
        let payload = ServerErrorPayload(error: "not_found", message: "Unknown route.")
        return codec.serializeResponse(ServerHTTPResponse(statusCode: 404, body: try MetaBrainJSON.encoder().encode(payload)))
    }
    #expect(throws: ServerClientError.sourceOperationUnsupported) {
        try legacy.stageSourceChunk(Data([0xab]))
    }
    #expect(throws: ServerClientError.sourceOperationUnsupported) {
        try legacy.sourceDescriptor(reference)
    }
    #expect(ServerClientError.sourceOperationUnsupported.description.contains("Upgrade mbd"))

    let missing = MetaBrainServerClient { _ in
        let payload = ServerErrorPayload(error: "document_not_found", message: "Document not found")
        return codec.serializeResponse(ServerHTTPResponse(statusCode: 404, body: try MetaBrainJSON.encoder().encode(payload)))
    }
    #expect(throws: ServerClientError.serverError(statusCode: 404, error: "document_not_found", message: "Document not found")) {
        try missing.sourceDescriptor(reference)
    }
}

private func sourcePost(
    _ router: ServerRouter, _ path: String, _ payload: some Encodable
) async throws -> ServerHTTPResponse {
    let body = try MetaBrainJSON.encoder().encode(payload)
    return await router.route(ServerHTTPRequest(method: .post, path: path, body: body))
}
