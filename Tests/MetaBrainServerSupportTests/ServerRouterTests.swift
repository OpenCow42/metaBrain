import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func healthRouteReturnsStableJSON() async throws {
    let response = await ServerRouter().route(
        ServerHTTPRequest(method: .get, path: "/health?verbose=true")
    )

    #expect(response.statusCode == 200)
    #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
    #expect(response.headers["Cache-Control"] == "no-store")
    #expect(response.bodyText == #"{"service":"mbd","status":"ok","version":"\#(MetaBrainVersion.currentSoftwareTag())"}"#)
    #expect(try MetaBrainJSON.decoder().decode(ServerHealthPayload.self, from: response.body) == ServerHealthPayload())
}

@Test func routerCanBeBuiltFromServeConfiguration() async throws {
    let configuration = try ServerServeConfiguration()
    let response = await ServerRouter(configuration: configuration).route(
        ServerHTTPRequest(method: .get, path: "/health")
    )

    #expect(response.statusCode == 200)
}

@Test func routerReturnsLocalVersionWithoutStoreAccess() async throws {
    let response = await ServerRouter().route(ServerHTTPRequest(method: .get, path: "/v1/version"))

    #expect(response.statusCode == 200)
    let version = try MetaBrainJSON.decoder().decode(VersionOutput.self, from: response.body)
    #expect(version.currentTag == MetaBrainVersion.currentSoftwareTag())
    #expect(version.releaseCheck == nil)

    let wrongMethod = await ServerRouter().route(ServerHTTPRequest(method: .post, path: "/v1/version"))
    #expect(wrongMethod.statusCode == 405)
    #expect(wrongMethod.headers["Allow"] == "GET")
}

@Test func routerRequiresStoreForStoreBackedRoutes() async throws {
    let response = await ServerRouter().route(ServerHTTPRequest(method: .post, path: "/v1/init"))

    #expect(response.statusCode == 500)
    #expect(
        try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body)
            == ServerErrorPayload(
                error: "server_not_configured",
                message: "The daemon store is not available."
            )
    )
}

@Test func routerRejectsWrongMethodsForStoreRoutes() async throws {
    let router = ServerRouter()
    let initialize = await router.route(ServerHTTPRequest(method: .get, path: "/v1/init"))
    let put = await router.route(ServerHTTPRequest(method: .get, path: "/v1/put"))
    let patch = await router.route(ServerHTTPRequest(method: .get, path: "/v1/patch"))
    let move = await router.route(ServerHTTPRequest(method: .get, path: "/v1/move"))
    let get = await router.route(ServerHTTPRequest(method: .get, path: "/v1/get"))
    let list = await router.route(ServerHTTPRequest(method: .get, path: "/v1/list"))
    let tree = await router.route(ServerHTTPRequest(method: .get, path: "/v1/tree"))
    let search = await router.route(ServerHTTPRequest(method: .get, path: "/v1/search"))
    let dump = await router.route(ServerHTTPRequest(method: .get, path: "/v1/dump"))
    let versions = await router.route(ServerHTTPRequest(method: .get, path: "/v1/versions"))
    let prune = await router.route(ServerHTTPRequest(method: .get, path: "/v1/prune"))
    let delete = await router.route(ServerHTTPRequest(method: .get, path: "/v1/delete"))
    let removeVersion = await router.route(ServerHTTPRequest(method: .get, path: "/v1/remove-version"))

    #expect(initialize.statusCode == 405)
    #expect(put.statusCode == 405)
    #expect(patch.statusCode == 405)
    #expect(move.statusCode == 405)
    #expect(get.statusCode == 405)
    #expect(list.statusCode == 405)
    #expect(tree.statusCode == 405)
    #expect(search.statusCode == 405)
    #expect(dump.statusCode == 405)
    #expect(versions.statusCode == 405)
    #expect(prune.statusCode == 405)
    #expect(delete.statusCode == 405)
    #expect(removeVersion.statusCode == 405)
    #expect(initialize.headers["Allow"] == "POST")
    #expect(put.headers["Allow"] == "POST")
    #expect(patch.headers["Allow"] == "POST")
    #expect(move.headers["Allow"] == "POST")
    #expect(get.headers["Allow"] == "POST")
    #expect(list.headers["Allow"] == "POST")
    #expect(tree.headers["Allow"] == "POST")
    #expect(search.headers["Allow"] == "POST")
    #expect(dump.headers["Allow"] == "POST")
    #expect(versions.headers["Allow"] == "POST")
    #expect(prune.headers["Allow"] == "POST")
    #expect(delete.headers["Allow"] == "POST")
    #expect(removeVersion.headers["Allow"] == "POST")
}

@Test func routerHandlesStoreBackedInitialPutAndGetRoutes() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)

    let initialize = await router.route(ServerHTTPRequest(method: .post, path: "/v1/init"))
    let put = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"hello","title":"Today","tags":["planning"],"metadata":{"source":"agent"}}"#.utf8)
    ))
    let get = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/today"},"trackingRead":false}"#.utf8)
    ))

    #expect(initialize.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(InitializeOutput.self, from: initialize.body).storePath.hasSuffix("store.leveldb"))
    #expect(put.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(PutOutput.self, from: put.body).status == "created")
    #expect(get.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: get.body).title == "Today")
}

@Test func routerRoutesStoreRequestsByStorePathHeader() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-registry")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = MetaBrainStoreRegistry(idleTimeoutSeconds: 10)
    defer { registry.closeAllBlocking() }
    let firstStore = root.appendingPathComponent("first.leveldb").path
    let secondStore = root.appendingPathComponent("second.leveldb").path
    let router = ServerRouter(storeRegistry: registry, defaultStorePath: firstStore)

    let firstHeader = [MetaBrainStoreRegistry.storePathHeader: MetaBrainStoreRegistry.storePathHeaderValue(for: firstStore)]
    let secondHeader = [MetaBrainStoreRegistry.storePathHeader: MetaBrainStoreRegistry.storePathHeaderValue(for: secondStore)]
    let firstPut = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        headers: firstHeader,
        body: Data(#"{"path":"/notes/shared","body":"first body"}"#.utf8)
    ))
    let secondPut = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        headers: secondHeader,
        body: Data(#"{"path":"/notes/shared","body":"second body"}"#.utf8)
    ))
    let firstGet = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get",
        headers: firstHeader,
        body: Data(#"{"reference":{"kind":"path","value":"/notes/shared"},"trackingRead":false}"#.utf8)
    ))
    let secondGet = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get",
        headers: secondHeader,
        body: Data(#"{"reference":{"kind":"path","value":"/notes/shared"},"trackingRead":false}"#.utf8)
    ))

    #expect(firstPut.statusCode == 200)
    #expect(secondPut.statusCode == 200)
    #expect(firstGet.statusCode == 200)
    #expect(secondGet.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: firstGet.body).body == "first body")
    #expect(try MetaBrainJSON.decoder().decode(GetOutput.self, from: secondGet.body).body == "second body")
    #expect(await registry.openStoreCount == 2)
}

@Test func routerRejectsInvalidStorePathHeader() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-bad-store-header")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = MetaBrainStoreRegistry(idleTimeoutSeconds: 10)
    defer { registry.closeAllBlocking() }
    let router = ServerRouter(
        storeRegistry: registry,
        defaultStorePath: root.appendingPathComponent("store.leveldb").path
    )

    let response = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/init",
        headers: [MetaBrainStoreRegistry.storePathHeader: "not base64"]
    ))

    #expect(response.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body).error == "invalid_request")
    #expect(await registry.openStoreCount == 0)
}

@Test func routerHandlesReadSideStoreRoutes() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-reads")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)

    _ = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"alpha beta","tags":["planning"],"metadata":{"source":"agent"}}"#.utf8)
    ))
    _ = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/archive/yesterday","body":"alpha archive"}"#.utf8)
    ))

    let list = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/list",
        body: Data(#"{"path":"/notes","recursive":true}"#.utf8)
    ))
    let tree = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/tree",
        body: Data(#"{"path":"/notes","maxDepth":2}"#.utf8)
    ))
    let search = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/search",
        body: Data(#"{"query":"alpha","pathPrefix":"/notes","tags":["planning"],"metadata":{"source":"agent"},"limit":5}"#.utf8)
    ))
    let dump = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/dump",
        body: Data(#"{"path":"/notes/today","versions":true}"#.utf8)
    ))
    let versions = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/versions",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/today"}}"#.utf8)
    ))

    #expect(list.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([ListOutput].self, from: list.body).map(\.path).contains("/notes/today"))
    #expect(tree.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([TreeOutput].self, from: tree.body).first?.kind == "root")
    #expect(search.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([SearchOutput].self, from: search.body).map(\.path) == ["/notes/today"])
    #expect(dump.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([DumpOutput].self, from: dump.body).map(\.body) == ["alpha beta"])
    #expect(versions.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([VersionsOutput].self, from: versions.body).map(\.sequence) == [1])
}

@Test func routerHandlesMutationStoreRoutes() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-mutations")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)
    let diff = "--- a/doc\n+++ b/doc\n@@ -1,2 +1,2 @@\n-old\n+new\n line\n"

    let put = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"old\nline\n"}"#.utf8)
    ))
    let documentID = try MetaBrainJSON.decoder().decode(PutOutput.self, from: put.body).documentID
    let check = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/patch",
        body: try MetaBrainJSON.encoder().encode(ServerPatchRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"),
            unifiedDiff: diff,
            check: true
        ))
    ))
    let patch = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/patch",
        body: try MetaBrainJSON.encoder().encode(ServerPatchRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"),
            unifiedDiff: diff
        ))
    ))
    let move = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/move",
        body: Data(#"{"reference":{"kind":"documentID","value":"\#(documentID)"},"destinationPath":"/notes/archive/today"}"#.utf8)
    ))
    let remove = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/remove-version",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/archive/today"},"sequence":1}"#.utf8)
    ))
    let prune = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/prune",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/archive/today"},"retention":{"kind":"keepLast","count":1}}"#.utf8)
    ))
    let delete = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/delete",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/archive/today"}}"#.utf8)
    ))

    #expect(check.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(PatchCheckOutput.self, from: check.body).success)
    #expect(patch.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(PatchOutput.self, from: patch.body).version == 2)
    #expect(move.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(MoveOutput.self, from: move.body).status == "moved")
    #expect(remove.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(RemoveVersionOutput.self, from: remove.body).removed)
    #expect(prune.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(PruneOutput.self, from: prune.body).retainedVersionCount == 1)
    #expect(delete.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(DeleteOutput.self, from: delete.body).deleted)
}

@Test func routerMapsStoreRouteValidationAndMissingDocumentErrors() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-errors")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)

    let badJSON = await router.route(ServerHTTPRequest(method: .post, path: "/v1/put", body: Data("{".utf8)))
    let badReference = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get",
        body: Data(#"{"reference":{"kind":"url","value":"relative/path"}}"#.utf8)
    ))
    let missing = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get",
        body: Data(#"{"reference":{"kind":"path","value":"/missing"}}"#.utf8)
    ))
    let invalidTree = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/tree",
        body: Data(#"{"maxDepth":-1}"#.utf8)
    ))
    let invalidSearch = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/search",
        body: Data(#"{"query":"hello","limit":0}"#.utf8)
    ))
    let invalidDump = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/dump",
        body: Data(#"{"includeBodies":false}"#.utf8)
    ))
    let invalidPrune = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/prune",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/today"}}"#.utf8)
    ))
    let invalidRemoveVersion = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/remove-version",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/today"},"sequence":0}"#.utf8)
    ))

    #expect(badJSON.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: badJSON.body).error == "invalid_request")
    #expect(badReference.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: badReference.body).error == "invalid_request")
    #expect(missing.statusCode == 404)
    #expect(
        try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: missing.body).error
            == "document_not_found"
    )
    #expect(invalidTree.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalidTree.body).error == "invalid_request")
    #expect(invalidSearch.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalidSearch.body).error == "invalid_request")
    #expect(invalidDump.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalidDump.body).error == "invalid_request")
    #expect(invalidPrune.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalidPrune.body).error == "invalid_request")
    #expect(invalidRemoveVersion.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalidRemoveVersion.body).error == "invalid_request")
}

@Test func routerMapsPatchAndConflictErrors() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-mutation-errors")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)

    _ = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"old\nline\n"}"#.utf8)
    ))
    _ = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/occupied","body":"taken"}"#.utf8)
    ))

    let invalidPatch = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/patch",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/today"},"unifiedDiff":"not a diff"}"#.utf8)
    ))
    let missingPatch = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/patch",
        body: Data(#"{"reference":{"kind":"path","value":"/missing"},"unifiedDiff":"not a diff"}"#.utf8)
    ))
    let moveConflict = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/move",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/today"},"destinationPath":"/notes/occupied"}"#.utf8)
    ))
    let currentVersionConflict = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/remove-version",
        body: Data(#"{"reference":{"kind":"path","value":"/notes/today"},"sequence":1}"#.utf8)
    ))

    #expect(invalidPatch.statusCode == 400)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: invalidPatch.body).error == "invalid_patch")
    #expect(missingPatch.statusCode == 404)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: missingPatch.body).error == "document_not_found")
    #expect(moveConflict.statusCode == 409)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: moveConflict.body).error == "conflict")
    #expect(currentVersionConflict.statusCode == 409)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: currentVersionConflict.body).error == "conflict")
}

@Test func routerMapsClosedStoreFailuresToStoreErrors() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-closed")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    storeServer.closeBlocking()
    let response = await ServerRouter(storeServer: storeServer).route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"hello"}"#.utf8)
    ))

    #expect(response.statusCode == 500)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body).error == "store_error")
}

@Test func healthRouteRejectsUnsupportedMethods() async throws {
    let response = await ServerRouter().route(
        ServerHTTPRequest(method: .post, path: "/health")
    )

    #expect(response.statusCode == 405)
    #expect(response.headers["Allow"] == "GET")
    #expect(
        try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body)
            == ServerErrorPayload(
                error: "method_not_allowed",
                message: "POST is not supported for /health."
            )
    )
}

@Test func routerReturnsNotFoundJSONForUnknownRoutes() async throws {
    let response = await ServerRouter().route(
        ServerHTTPRequest(method: .get, path: "/v1/run")
    )

    #expect(response.statusCode == 404)
    #expect(
        try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body)
            == ServerErrorPayload(
                error: "not_found",
                message: "No server route exists for GET /v1/run."
            )
    )
}

@Test func sharedRouterHandlesConcurrentLightweightRoutes() async throws {
    let router = ServerRouter()
    let requests = (0..<64).map { index in
        index.isMultiple(of: 2)
            ? ServerHTTPRequest(method: .get, path: "/health?index=\(index)")
            : ServerHTTPRequest(method: .post, path: "/v1/run", body: Data("{".utf8))
    }

    let responses = await withTaskGroup(of: (Int, ServerHTTPResponse).self) { group in
        for (index, request) in requests.enumerated() {
            group.addTask {
                (index, await router.route(request))
            }
        }

        var responses = Array<ServerHTTPResponse?>(repeating: nil, count: requests.count)
        for await (index, response) in group {
            responses[index] = response
        }
        return responses.map { $0! }
    }

    for (index, response) in responses.enumerated() {
        #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
        #expect(response.headers["Cache-Control"] == "no-store")
        if index.isMultiple(of: 2) {
            #expect(response.statusCode == 200)
            #expect(response.bodyText == #"{"service":"mbd","status":"ok","version":"\#(MetaBrainVersion.currentSoftwareTag())"}"#)
        } else {
            #expect(response.statusCode == 404)
            #expect(response.bodyText == #"{"error":"not_found","message":"No server route exists for POST /v1/run."}"#)
        }
    }
}
