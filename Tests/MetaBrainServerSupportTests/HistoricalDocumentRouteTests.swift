import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func historicalDocumentRouteReturnsTheRequestedRevisionAndReportsUnavailableVersions() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-get-version")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    let router = ServerRouter(storeServer: server)
    let first = try await server.put(ServerPutRequest(path: "/notes/original", body: "original body"))
    let reference = DocumentReferenceDTO(kind: .documentID, value: first.documentID)
    let original = try await server.get(ServerGetRequest(reference: reference, trackingRead: false))
    _ = try await server.put(ServerPutRequest(path: "/notes/original", body: "new body"))
    _ = try await server.move(ServerMoveRequest(reference: reference, destinationPath: "/archive/moved"))

    let request = ServerHTTPRequest(
        method: .post,
        path: "/v1/get-version",
        body: try MetaBrainJSON.encoder().encode(ServerGetDocumentVersionRequest(reference: reference, version: 1))
    )
    let historical = await router.route(request)
    #expect(historical.statusCode == 200)
    #expect(historical.body == (try MetaBrainJSON.encoder().encode(original)))

    let invalid = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get-version",
        body: try MetaBrainJSON.encoder().encode(ServerGetDocumentVersionRequest(reference: reference, version: 0))
    ))
    #expect(invalid.statusCode == 400)
    let invalidError = try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalid.body)
    #expect(invalidError.error == "invalid_request")
    #expect(invalidError.message == "Document version must be greater than zero, got 0.")
    let methodNotAllowed = await router.route(ServerHTTPRequest(method: .get, path: "/v1/get-version"))
    #expect(methodNotAllowed.statusCode == 405)
    #expect(methodNotAllowed.headers["Allow"] == "POST")

    _ = try await server.prune(ServerPruneRequest(
        reference: reference, retention: DocumentRetentionPolicyDTO(kind: .keepLast, count: 1)
    ))
    let pruned = await router.route(request)
    #expect(pruned.statusCode == 404)
    let prunedError = try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: pruned.body)
    #expect(prunedError.error == "document_version_not_found")
    #expect(prunedError.message.contains("Document version 1 not found for \(first.documentID)"))
    await server.close()
}

@Test(arguments: ["not_found", "document_version_not_found", nil] as [String?])
func historicalDocumentClientDistinguishesAnOldDaemonFromAnUnavailableRevision(code: String?) throws {
    let codec = ServerHTTPCodec()
    let expected = ServerGetDocumentVersionRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/original"), version: 1
    )
    let message = "Revision unavailable."
    let body = try code.map { try MetaBrainJSON.encoder().encode(ServerErrorPayload(error: $0, message: message)) }
    let client = MetaBrainServerClient { data in
        let request = try codec.parseRequest(data)
        #expect(request.method == .post)
        #expect(request.path == "/v1/get-version")
        #expect(try MetaBrainJSON.decoder().decode(ServerGetDocumentVersionRequest.self, from: request.body) == expected)
        return codec.serializeResponse(ServerHTTPResponse(statusCode: 404, body: body ?? Data()))
    }
    let error: ServerClientError = if code == "document_version_not_found" {
        .serverError(statusCode: 404, error: "document_version_not_found", message: message)
    } else {
        .historicalGetUnsupported
    }
    #expect(throws: error) {
        try client.getVersion(expected)
    }
}
