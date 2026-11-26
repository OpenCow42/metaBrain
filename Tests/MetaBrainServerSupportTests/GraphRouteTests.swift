import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func graphRouteMatchesDirectQuery() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-graph")
    defer { try? FileManager.default.removeItem(at: root) }
    let location = root.appendingPathComponent("store.leveldb")
    let store = try MetaBrainStore(url: location)
    _ = try await store.putDocument(DocumentInput(path: DocumentPath("/project/source.md"), body: "Source."))
    let document = try await store.putDocument(DocumentInput(
        path: DocumentPath("/project/decision.md"), body: "[[source.md]]"
    ))
    let query = DocumentGraphQuery(scope: .note(id: document.id, depth: 1))
    let expected = try await store.graph(query)
    await store.close()
    let server = try MetaBrainStoreServer(storePath: location.path)
    let router = ServerRouter(storeServer: server)
    let request = ServerHTTPRequest(method: .post, path: "/v1/graph", body: try MetaBrainJSON.encoder().encode(query))
    let response = await router.route(request)
    #expect(response.statusCode == 200)
    #expect(try MetaBrainJSON.decoder().decode(DocumentGraph.self, from: response.body) == expected)
    let wrongMethod = await router.route(ServerHTTPRequest(method: .get, path: "/v1/graph"))
    #expect(wrongMethod.statusCode == 405)
    await server.close()
}
