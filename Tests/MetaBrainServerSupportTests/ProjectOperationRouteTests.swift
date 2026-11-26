import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func operationRoutesInspectApplyAndReplayAReviewedWrite() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-operation")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }
    let router = ServerRouter(storeServer: server)
    let operation = ProjectOperation(
        operationID: UUID(),
        project: try DocumentPath("/projects/demo"),
        documents: [
            DocumentInput(path: try DocumentPath("/projects/demo/source.md"), body: "Source text"),
            DocumentInput(path: try DocumentPath("/projects/demo/decision.md"), body: "[[source]]")
        ]
    )

    let inspect = "/v1/operation-inspect"
    let apply = "/v1/operation-apply"
    let check = "/v1/operation-check-citations"
    for path in [inspect, check, apply] {
        let response = await router.route(ServerHTTPRequest(method: .get, path: path))
        #expect(response.statusCode == 405)
    }

    let invalid = try await postOperation(router, inspect, ProjectOperation(
        operationID: UUID(), project: operation.project,
        documents: [DocumentInput(path: try DocumentPath("/projects/another/note.md"), body: "Outside")]
    ))
    #expect(invalid.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalid.body).error == "invalid_request")

    let preview = try await postOperation(router, check, operation)
    #expect(preview.statusCode == 200)
    let decodedPreview = try MetaBrainJSON.decoder().decode(OperationPreview.self, from: preview.body)
    #expect(decodedPreview.operation == operation)
    #expect(decodedPreview.targets.map(\.version) == [0, 0])
    #expect(decodedPreview.citationChecks?.map(\.link.status) == [.resolved])
    let reference = DocumentReferenceDTO(kind: .path, value: operation.documents[1].path.rawValue)
    let getRequest = ServerGetRequest(reference: reference, trackingRead: false)
    let before = try await postOperation(router, "/v1/get", getRequest)
    #expect(before.statusCode == 404)

    let tampered = String(decoding: preview.body, as: UTF8.self)
        .replacingOccurrences(of: "Source text", with: "Unreviewed source")
    let rejected = await router.route(ServerHTTPRequest(method: .post, path: apply, body: Data(tampered.utf8)))
    #expect(rejected.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: rejected.body).error == "invalid_request")

    let commit = ServerHTTPRequest(method: .post, path: apply, body: preview.body)
    let receipt = await router.route(commit)
    #expect(receipt.statusCode == 200)
    let decodedReceipt = try MetaBrainJSON.decoder().decode(OperationReceipt.self, from: receipt.body)
    #expect(decodedReceipt.operationID == operation.operationID)
    #expect(decodedReceipt.digest == decodedPreview.digest)
    let after = try await postOperation(router, "/v1/get", getRequest)
    #expect(after.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: after.body).body == "[[source]]")

    let retry = await router.route(commit)
    #expect(retry.statusCode == 200)
    #expect(retry.body == receipt.body)

    let stale = try await postOperation(router, inspect, ProjectOperation(
        operationID: UUID(), project: operation.project, documents: operation.documents
    ))
    #expect(stale.statusCode == 200)
    let edit = try await postOperation(router, "/v1/put", ServerPutRequest(path: reference.value, body: "New decision"))
    #expect(edit.statusCode == 200)
    let conflict = await router.route(ServerHTTPRequest(method: .post, path: apply, body: stale.body))
    #expect(conflict.statusCode == 409)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: conflict.body).error == "conflict")
}

@Test(arguments: [false, true])
func damagedOperationStoreIdentityPreservesOrdinaryRoutes(isDirectory: Bool) async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-operation-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let location = root.appendingPathComponent("store.leveldb")
    let initial = try MetaBrainStoreServer(storePath: location.path)
    let path = try DocumentPath("/projects/demo/note.md")
    _ = try await initial.put(ServerPutRequest(path: path.rawValue, body: "Existing note"))
    await initial.close()

    let identity = location.appendingPathComponent("metabrain-identity")
    try FileManager.default.removeItem(at: identity)
    if isDirectory {
        try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: false)
    } else {
        try Data("invalid UUID".utf8).write(to: identity)
    }
    let server = try MetaBrainStoreServer(storePath: location.path)
    defer { server.closeBlocking() }
    let router = ServerRouter(storeServer: server)
    let reference = DocumentReferenceDTO(kind: .path, value: path.rawValue)
    let get = try await postOperation(router, "/v1/get", ServerGetRequest(reference: reference, trackingRead: false))
    #expect(get.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: get.body).body == "Existing note")

    let operation = ProjectOperation(
        operationID: UUID(), project: try DocumentPath("/projects/demo"),
        documents: [DocumentInput(path: path, body: "Proposed note")]
    )
    let inspect = try await postOperation(router, "/v1/operation-inspect", operation)
    #expect(inspect.statusCode == 500)
    let failure = try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: inspect.body)
    #expect(failure.error == "store_error")
    let message = isDirectory
        ? "Unable to read project operation store identity"
        : "Invalid project operation store identity"
    #expect(failure.message.contains(message))
}

private func postOperation(
    _ router: ServerRouter, _ path: String, _ payload: some Encodable
) async throws -> ServerHTTPResponse {
    let body = try MetaBrainJSON.encoder().encode(payload)
    return await router.route(ServerHTTPRequest(method: .post, path: path, body: body))
}
