import Dispatch
import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

#if canImport(Darwin)
import Darwin
#endif

@Test(arguments: [
    "/v1/put-conditional", "/v1/put-markdown", "/v1/get-passage", "/v1/get-ref",
    "/v1/links", "/v1/search-evidence", "/v1/recall"
])
func storeRoutesAdvertiseRequiredPostMethod(path: String) {
    let response = ServerRouter().routeBlocking(ServerHTTPRequest(method: .get, path: path))
    #expect(response.statusCode == 405)
    #expect(response.headers["Allow"] == "POST")
}

@Test func markdownRouteRejectsMalformedRequestBeforeOpeningStore() async {
    let response = await ServerRouter().route(ServerHTTPRequest(
        method: .post, path: "/v1/put-markdown", body: Data("{".utf8)
    ))
    #expect(response.statusCode == 400)
}

@Test func oldDaemonPlain404PreservesCapabilityErrors() throws {
    let codec = ServerHTTPCodec()
    let client = MetaBrainServerClient { _ in
        codec.serializeResponse(ServerHTTPResponse(statusCode: 404, body: Data("Not Found".utf8)))
    }

    let put = ServerConditionalPutRequest(document: ServerPutRequest(path: "/note", body: "Note"), ifVersion: 0)
    #expect(throws: ServerClientError.conditionalPutUnsupported) { try client.putConditional(put) }
    #expect(throws: ServerClientError.recallUnsupported) { try client.recall(ServerRecallRequest(query: "Note")) }
    #expect(throws: ServerClientError.citationOperationUnsupported("links")) {
        try client.links(ServerLinksRequest(reference: DocumentReferenceDTO(kind: .path, value: "/note")))
    }
}

@Test func rangePassageOmitsMarkdownSelectorsAndDaemonVersionRoundTrips() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-range-passage")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MetaBrainStore(url: root.appendingPathComponent("store"))
    let path = try DocumentPath("/note")
    _ = try await store.putDocument(DocumentInput(path: path, body: "Note and other text"))
    let passage = try #require(try await store.readPassage(.path(path), selector: .range(start: 0, end: 4)))
    let output = DocumentPassageOutput(passage)
    #expect(output.block == nil && output.heading == nil)
    #expect(output.text == "Note")
    let version = ServerVersionOutput(currentTag: "1.2.1", endpoint: "local", error: nil, reachable: true)
    #expect(try MetaBrainJSON.decoder().decode(ServerVersionOutput.self, from: MetaBrainJSON.encoder().encode(version)) == version)
    #expect(ServerInitializeRequest(empty: true).empty == true)
    await store.close()
}

@Test func storeRegistryDropsFailedInitializationAndCanRetry() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-bad-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = root.appendingPathComponent("store")
    try Data("not a directory".utf8).write(to: store)
    let registry = MetaBrainStoreRegistry()
    defer { registry.closeAllBlocking() }

    await #expect(throws: (any Error).self) {
        try await registry.withStore(at: store.path, createIfMissing: true, initializingEmpty: true) {
            await $0.initialize()
        }
    }
    #expect(await registry.openStoreCount == 0)
    try FileManager.default.removeItem(at: store)

    let initialized = try await registry.withStore(at: store.path, createIfMissing: true, initializingEmpty: true) {
        await $0.initialize()
    }
    #expect(initialized.storePath == store.path)
    _ = try await registry.withStore(at: store.path) { server in
        await registry.closeAll()
        return await server.initialize()
    }
    #expect(await registry.openStoreCount == 0)
}

@Test func storeRegistryIgnoresAnIdleTimerForAReacquiredStore() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-registry-generation")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = MetaBrainStoreRegistry(idleTimeoutSeconds: 0.05)
    defer { registry.closeAllBlocking() }
    let path = root.appendingPathComponent("store").path
    _ = try await registry.withStore(at: path) { await $0.initialize() }
    _ = try await registry.withStore(at: path) { server in
        try await Task.sleep(for: .milliseconds(100))
        #expect(await registry.openStoreCount == 1)
        return try await server.put(ServerPutRequest(path: "/note", body: "Still open"))
    }
}

#if canImport(Darwin) || canImport(Glibc)
@Test func clientDisallowsHTTPTransportForNonLoopbackEndpoints() {
    let label = String(repeating: "a", count: 55)
    let endpoint = "http://\(label).\(label).example.test:4321"
    let client = MetaBrainServerClient(socketPath: endpoint)
    let socketPath = NSString(string: endpoint).expandingTildeInPath
    #expect(throws: ServerClientError.socketPathTooLong(socketPath)) { try client.health() }
}

@Test func loopbackClientReadsEvidenceAndServerIdentity() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-client-evidence")
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try ServerServeConfiguration(
        storePath: root.appendingPathComponent("store.leveldb").path, host: "127.0.0.1", port: 0
    )
    let running = try startServer(configuration: configuration, maxRequests: nil)
    defer {
        running.server.stop()
        try? running.wait()
    }
    guard case let .loopback(host, port) = running.mode else {
        Issue.record("Expected loopback listener")
        return
    }
    let endpoint = "http://\(host):\(port)"
    let client = MetaBrainServerClient(socketPath: endpoint, requestTimeoutMilliseconds: 2_000)
    let defaultTimeoutClient = MetaBrainServerClient(socketPath: endpoint)
    #expect(try defaultTimeoutClient.health().status == "ok")
    #expect(try client.version().currentTag == MetaBrainVersion.currentSoftwareTag())

    let path = "/note"
    let body = "Needle reference."
    let written = try client.putMarkdown(ServerMarkdownPutRequest(
        document: ServerPutRequest(path: path, body: body + " ^ref")
    ))
    let note = DocumentReferenceDTO(kind: .path, value: path)
    #expect(try client.getPassage(ServerGetPassageRequest(reference: note, block: "ref")).text == body)
    #expect(try client.links(ServerLinksRequest(reference: note)).isEmpty)
    #expect(try client.lint(ServerLintRequest(path: path)).findings.isEmpty)
    let ref = try EvidenceReference("\(written.documentID)@1#^ref")
    #expect(try client.getEvidence(ServerGetEvidenceRequest(ref: ref)).items.first?.text == body)
    let search = ServerEvidenceSearchRequest(query: "Needle", view: .refs)
    #expect(try client.searchEvidence(search).items.first?.ref.documentID.rawValue == written.documentID)
}

@Test func releaseCheckUsesDefaultHTTPFetch() async throws {
    let configuration = try ServerServeConfiguration(host: "127.0.0.1", port: 0)
    let running = try startServer(configuration: configuration, maxRequests: nil, routeHandler: { request in
        #expect(request.method == .get)
        #expect(request.headers["Accept"] == "application/vnd.github+json")
        return ServerHTTPResponse(
            statusCode: 200, body: Data(#"{"tag_name":"v2.0.0","html_url":"https://example.test/releases/v2.0.0"}"#.utf8)
        )
    })
    defer {
        running.server.stop()
        try? running.wait()
    }
    guard case let .loopback(host, port) = running.mode else {
        Issue.record("Expected loopback listener")
        return
    }
    let result = await MetaBrainReleaseChecker.checkLatestRelease(
        currentTag: "1.2.1", releaseAPIURL: "http://\(host):\(port)/latest", timeout: 2
    )
    #expect(result.status == "checked")
    #expect(result.latestTag == "v2.0.0")
    #expect(result.updateAvailable == true)
}
#endif

#if canImport(Darwin)
@Test func httpServerLogsFailedResponseWriteWhenSocketCannotSend() throws {
    let loggedFailure = DispatchSemaphore(value: 0)
    let logger = ServerStructuredLogger(minimumLevel: .warn) { line in
        let record = try? MetaBrainJSON.decoder().decode(ServerLogRecord.self, from: Data(line.utf8))
        #expect(record?.event == "request_error")
        #expect(record?.path == "/health")
        #expect(record?.error == "socket operation failed: send")
        loggedFailure.signal()
    }
    let running = try startServer(
        configuration: ServerServeConfiguration(host: "127.0.0.1", port: 0),
        maxRequests: 1,
        routeHandler: { _ in ServerHTTPResponse(statusCode: 200) },
        receiveSocket: { socket, buffer, size, flags in
            let received = Darwin.recv(socket, buffer, size, flags)
            if received > 0 {
                var enabled: Int32 = 1
                let optionSet = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                #expect(optionSet == 0)
                #expect(shutdown(socket, SHUT_WR) == 0)
            }
            return received
        },
        logger: logger
    )
    let response = try sendHTTPRequest(to: running.mode, request: "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    try running.wait()
    #expect(response.isEmpty)
    #expect(loggedFailure.wait(timeout: .now()) == .success)
}
#endif
