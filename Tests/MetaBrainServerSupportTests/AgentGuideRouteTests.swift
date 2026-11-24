import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func ensureGuideRouteIsIdempotentAndPreservesAnExistingGuide() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-ensure-guide")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    let router = ServerRouter(storeServer: server)
    let request = ServerHTTPRequest(method: .post, path: "/v1/ensure-guide")
    let created = await router.route(request)
    #expect(created.statusCode == 200)
    let initial = try MetaBrainJSON.decoder().decode(PutOutput.self, from: created.body)
    #expect(initial.operation == "ensure-guide")
    #expect(initial.status == "created")
    #expect(initial.path == "/AGENTS.md")
    #expect(initial.version == 1)
    let custom = try await server.put(ServerPutRequest(path: initial.path, body: "Team guide"))
    let repeated = await router.route(request)
    let existing = try MetaBrainJSON.decoder().decode(PutOutput.self, from: repeated.body)
    #expect(existing.status == "unchanged")
    #expect(existing.version == custom.version)
    let doc = try await server.get(ServerGetRequest(reference: .init(kind: .path, value: initial.path)))
    #expect(doc.body == "Team guide")
    let wrongMethod = await router.route(ServerHTTPRequest(method: .get, path: "/v1/ensure-guide"))
    #expect(wrongMethod.statusCode == 405)
    await server.close()
}
