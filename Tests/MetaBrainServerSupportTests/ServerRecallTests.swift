import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func recallRequestDefaultsAndValidatesLimits() throws {
    let request = try MetaBrainJSON.decoder().decode(
        ServerRecallRequest.self,
        from: Data(#"{"query":"rollback","pathPrefix":"/notes","tags":["release"],"metadata":{"state":"current"}}"#.utf8)
    )
    #expect(try request.validatedMaxBytes() == 8192)
    #expect(try request.searchQuery() == SearchQuery(
        text: "rollback",
        pathPrefix: DocumentPath("/notes"),
        tags: ["release"],
        metadata: ["state": "current"],
        limit: 5
    ))
    #expect(throws: (any Error).self) {
        try ServerRecallRequest(query: "rollback", limit: 0).searchQuery()
    }
    for invalid in [2, 1_048_577] {
        #expect(throws: (any Error).self) {
            try ServerRecallRequest(query: "rollback", maxBytes: invalid).validatedMaxBytes()
        }
    }
}

@Test func recallRouteHonorsCompactByteBudgetAndRequiresAnExistingStore() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-recall")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("absent-parent/store.leveldb")
    let registry = MetaBrainStoreRegistry()
    defer { registry.closeAllBlocking() }
    let router = ServerRouter(storeRegistry: registry, defaultStorePath: path.path)

    let query = #"{"query":"café","maxBytes":256}"#
    func recall(_ json: String) async -> ServerHTTPResponse {
        await router.route(ServerHTTPRequest(method: .post, path: "/v1/recall", body: Data(json.utf8)))
    }
    let missing = await recall(query)
    #expect(missing.statusCode == 404)
    #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    let invalid = await recall(#"{"query":"café","maxBytes":1048577}"#)
    #expect(invalid.statusCode == 400)

    let put = await router.route(ServerHTTPRequest(
        method: .post,
        path: "/v1/put",
        body: Data(#"{"path":"/notes/café","body":"A café quote \"with punctuation\"."}"#.utf8)
    ))
    #expect(put.statusCode == 200)

    let good = await recall(query)
    #expect(good.statusCode == 200)
    #expect(good.body.count + 1 <= 256)
    let hits = try MetaBrainJSON.decoder().decode([RecallResult].self, from: good.body)
    let result = try #require(hits.first)
    #expect(result.path == "/notes/café")
    #expect(result.version == 1)
    #expect(result.passages.first?.text.contains("café") == true)
    #expect(try RecallResult.jsonData(hits) == good.body)

    let smallest = await recall(#"{"query":"café","maxBytes":3}"#)
    #expect(smallest.statusCode == 200)
    #expect(smallest.body == Data("[]".utf8))
}

@Test func recallClientReportsLegacyDaemonSupportError() throws {
    let codec = ServerHTTPCodec()
    let client = MetaBrainServerClient { data in
        let request = try codec.parseRequest(data)
        #expect(request.method == .post)
        #expect(request.path == "/v1/recall")
        let body = try MetaBrainJSON.encoder().encode(ServerErrorPayload(error: "not_found", message: "Unknown route."))
        return codec.serializeResponse(ServerHTTPResponse(statusCode: 404, body: body))
    }
    #expect(throws: ServerClientError.recallUnsupported) {
        try client.recall(ServerRecallRequest(query: "rollback"))
    }
}
