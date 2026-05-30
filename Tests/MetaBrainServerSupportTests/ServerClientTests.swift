import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func serverClientSerializesPostRequestsAndDecodesResponses() throws {
    let codec = ServerHTTPCodec()
    let putResponse = PutOutput(documentID: "abc123", path: "/notes/today", status: "created", version: 1)
    let initializeResponse = InitializeOutput(storePath: "/tmp/store.leveldb")
    let client = MetaBrainServerClient { requestData in
        let request = try codec.parseRequest(requestData)
        #expect(request.method == .post)
        #expect(request.headers["Host"] == "localhost")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Content-Length"] == "\(request.body.count)")

        let body: Data
        switch request.path {
        case "/v1/put":
            let decoded = try MetaBrainJSON.decoder().decode(ServerPutRequest.self, from: request.body)
            #expect(decoded == ServerPutRequest(path: "/notes/today", body: "hello"))
            body = try MetaBrainJSON.encoder().encode(putResponse)
        case "/v1/init":
            #expect(request.body == Data("{}".utf8))
            body = try MetaBrainJSON.encoder().encode(initializeResponse)
        default:
            Issue.record("unexpected request path \(request.path)")
            body = try MetaBrainJSON.encoder().encode(ServerErrorPayload(error: "not_found", message: "missing"))
        }

        return codec.serializeResponse(ServerHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        ))
    }

    let putOutput: PutOutput = try client.post(
        "/v1/put",
        request: ServerPutRequest(path: "/notes/today", body: "hello"),
        response: PutOutput.self
    )
    let initOutput: InitializeOutput = try client.post("/v1/init", response: InitializeOutput.self)

    #expect(putOutput == putResponse)
    #expect(initOutput == initializeResponse)
}

@Test func serverClientMapsStructuredServerErrors() throws {
    let codec = ServerHTTPCodec()
    let payload = ServerErrorPayload(error: "not_found", message: "Document not found.")
    let client = MetaBrainServerClient { _ in
        codec.serializeResponse(ServerHTTPResponse(
            statusCode: 404,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: try MetaBrainJSON.encoder().encode(payload)
        ))
    }

    #expect(throws: ServerClientError.serverError(statusCode: 404, error: "not_found", message: "Document not found.")) {
        let _: InitializeOutput = try client.post("/v1/init", response: InitializeOutput.self)
    }
}

@Test func serverClientReportsUnexpectedStatusWithoutStructuredPayload() throws {
    let codec = ServerHTTPCodec()
    let client = MetaBrainServerClient { _ in
        codec.serializeResponse(ServerHTTPResponse(statusCode: 418, body: Data("nope".utf8)))
    }

    #expect(throws: ServerClientError.unexpectedStatusCode(418)) {
        let _: InitializeOutput = try client.post("/v1/init", response: InitializeOutput.self)
    }
}

#if canImport(Darwin) || canImport(Glibc)

@Test func serverClientRoundTripsOverUnixSocket() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-client")
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("mbd.sock")
    let response = InitializeOutput(storePath: "/tmp/store.leveldb")
    let responseBody = try MetaBrainJSON.encoder().encode(response)
    let running = try startServer(
        configuration: try ServerServeConfiguration(socketPath: socket.path),
        maxRequests: 1,
        routeHandler: { request in
            #expect(request.method == .post)
            #expect(request.path == "/v1/init")
            #expect(request.body == Data("{}".utf8))
            return ServerHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: responseBody
            )
        }
    )

    let client = MetaBrainServerClient(socketPath: socket.path)
    let output: InitializeOutput = try client.post("/v1/init", response: InitializeOutput.self)

    try running.wait()
    #expect(output == response)
}

@Test func serverClientReportsUnixSocketConnectionFailures() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-client-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = MetaBrainServerClient(socketPath: root.appendingPathComponent("missing.sock").path)

    #expect(throws: ServerClientError.socketOperationFailed("connect")) {
        let _: InitializeOutput = try client.post("/v1/init", response: InitializeOutput.self)
    }
}

@Test func serverClientRejectsOverlongUnixSocketPaths() {
    let path = "/tmp/" + String(repeating: "x", count: 200)
    let client = MetaBrainServerClient(socketPath: path)

    #expect(throws: ServerClientError.socketPathTooLong(path)) {
        let _: InitializeOutput = try client.post("/v1/init", response: InitializeOutput.self)
    }
}

#endif

@Test func serverClientErrorDescriptionsAreStable() {
    #expect(ServerClientError.socketPathTooLong("/tmp/socket").description == "unix socket path is too long: /tmp/socket")
    #expect(ServerClientError.socketOperationFailed("connect").description == "socket operation failed: connect")
    #expect(ServerClientError.serverError(statusCode: 404, error: "not_found", message: "missing").description == "server returned HTTP 404 not_found: missing")
    #expect(ServerClientError.unexpectedStatusCode(418).description == "server returned unexpected HTTP 418")
}
