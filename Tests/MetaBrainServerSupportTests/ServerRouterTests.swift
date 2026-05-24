import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func healthRouteReturnsStableJSON() throws {
    let response = ServerRouter().route(
        ServerHTTPRequest(method: .get, path: "/health?verbose=true")
    )

    #expect(response.statusCode == 200)
    #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
    #expect(response.headers["Cache-Control"] == "no-store")
    #expect(response.bodyText == #"{"service":"mbd","status":"ok"}"#)
    #expect(try MetaBrainJSON.decoder().decode(ServerHealthPayload.self, from: response.body) == ServerHealthPayload())
}

@Test func routerCanBeBuiltFromServeConfiguration() throws {
    let configuration = try ServerServeConfiguration()
    let response = ServerRouter(configuration: configuration).route(
        ServerHTTPRequest(method: .get, path: "/health")
    )

    #expect(response.statusCode == 200)
}

@Test func routerReturnsLocalVersionWithoutStoreAccess() throws {
    let response = ServerRouter().route(ServerHTTPRequest(method: .get, path: "/v1/version"))

    #expect(response.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(VersionOutput.self, from: response.body).releaseCheck == nil)

    let wrongMethod = ServerRouter().route(ServerHTTPRequest(method: .post, path: "/v1/version"))
    #expect(wrongMethod.statusCode == 405)
    #expect(wrongMethod.headers["Allow"] == "GET")
}

@Test func routerRequiresStoreForStoreBackedRoutes() throws {
    let response = ServerRouter().route(ServerHTTPRequest(method: .post, path: "/v1/init"))

    #expect(response.statusCode == 500)
    #expect(
        try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body)
            == ServerErrorPayload(
                error: "server_not_configured",
                message: "The daemon store is not available."
            )
    )
}

@Test func routerRejectsWrongMethodsForStoreRoutes() throws {
    let router = ServerRouter()
    let initialize = router.route(ServerHTTPRequest(method: .get, path: "/v1/init"))
    let put = router.route(ServerHTTPRequest(method: .get, path: "/v1/put"))
    let get = router.route(ServerHTTPRequest(method: .get, path: "/v1/get"))
    let list = router.route(ServerHTTPRequest(method: .get, path: "/v1/list"))
    let tree = router.route(ServerHTTPRequest(method: .get, path: "/v1/tree"))
    let search = router.route(ServerHTTPRequest(method: .get, path: "/v1/search"))
    let versions = router.route(ServerHTTPRequest(method: .get, path: "/v1/versions"))

    #expect(initialize.statusCode == 405)
    #expect(put.statusCode == 405)
    #expect(get.statusCode == 405)
    #expect(list.statusCode == 405)
    #expect(tree.statusCode == 405)
    #expect(search.statusCode == 405)
    #expect(versions.statusCode == 405)
    #expect(initialize.headers["Allow"] == "POST")
    #expect(put.headers["Allow"] == "POST")
    #expect(get.headers["Allow"] == "POST")
    #expect(list.headers["Allow"] == "POST")
    #expect(tree.headers["Allow"] == "POST")
    #expect(search.headers["Allow"] == "POST")
    #expect(versions.headers["Allow"] == "POST")
}

@Test func routerHandlesStoreBackedInitialPutAndGetRoutes() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)

    let initialize = router.route(ServerHTTPRequest(method: .post, path: "/v1/init"))
    let put = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"hello","title":"Today","tags":["planning"],"metadata":{"source":"agent"}}"#.utf8)
    ))
    let get = router.route(ServerHTTPRequest(
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

@Test func routerHandlesReadSideStoreRoutes() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-reads")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)

    _ = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"alpha beta","tags":["planning"],"metadata":{"source":"agent"}}"#.utf8)
    ))
    _ = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/archive/yesterday","body":"alpha archive"}"#.utf8)
    ))

    let list = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/list",
        body: Data(#"{"path":"/notes","recursive":true}"#.utf8)
    ))
    let tree = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/tree",
        body: Data(#"{"path":"/notes","maxDepth":2}"#.utf8)
    ))
    let search = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/search",
        body: Data(#"{"query":"alpha","pathPrefix":"/notes","tags":["planning"],"metadata":{"source":"agent"},"limit":5}"#.utf8)
    ))
    let versions = router.route(ServerHTTPRequest(
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
    #expect(versions.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode([VersionsOutput].self, from: versions.body).map(\.sequence) == [1])
}

@Test func routerMapsStoreRouteValidationAndMissingDocumentErrors() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-errors")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { storeServer.closeBlocking() }
    let router = ServerRouter(storeServer: storeServer)

    let badJSON = router.route(ServerHTTPRequest(method: .post, path: "/v1/put", body: Data("{".utf8)))
    let badReference = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get",
        body: Data(#"{"reference":{"kind":"url","value":"relative/path"}}"#.utf8)
    ))
    let missing = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/get",
        body: Data(#"{"reference":{"kind":"path","value":"/missing"}}"#.utf8)
    ))
    let invalidTree = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/tree",
        body: Data(#"{"maxDepth":-1}"#.utf8)
    ))
    let invalidSearch = router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/search",
        body: Data(#"{"query":"hello","limit":0}"#.utf8)
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
}

@Test func routerMapsClosedStoreFailuresToStoreErrors() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-router-closed")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeServer = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    storeServer.closeBlocking()
    let response = ServerRouter(storeServer: storeServer).route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/today","body":"hello"}"#.utf8)
    ))

    #expect(response.statusCode == 500)
    #expect(try MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: response.body).error == "store_error")
}

@Test func healthRouteRejectsUnsupportedMethods() throws {
    let response = ServerRouter().route(
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

@Test func routerReturnsNotFoundJSONForUnknownRoutes() throws {
    let response = ServerRouter().route(
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
                (index, router.route(request))
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
            #expect(response.bodyText == #"{"service":"mbd","status":"ok"}"#)
        } else {
            #expect(response.statusCode == 404)
            #expect(response.bodyText == #"{"error":"not_found","message":"No server route exists for POST /v1/run."}"#)
        }
    }
}
