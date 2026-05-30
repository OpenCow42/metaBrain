import Dispatch
import Foundation
import Testing
@testable import MetaBrainServerSupport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)

@Test func httpServerServesHealthOverLoopbackPortZero() throws {
    let configuration = try ServerServeConfiguration(host: "127.0.0.1", port: 0)
    let running = try startServer(configuration: configuration, maxRequests: 1)
    guard case let .loopback(host, port) = running.mode else {
        Issue.record("expected loopback listener")
        return
    }

    #expect(running.server.boundListenMode == running.mode)
    let response = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: \(host)\r\n\r\n"
    )

    try running.wait()
    #expect(port > 0)
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.contains("Content-Type: application/json; charset=utf-8\r\n"))
    #expect(response.hasSuffix(#"{"service":"mbd","status":"ok"}"#))
}

@Test func httpServerServesHealthOverUnixSocket() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-health")
    defer { try? FileManager.default.removeItem(at: root) }

    let socket = root.appendingPathComponent("mbd.sock")
    let configuration = try ServerServeConfiguration(socketPath: socket.path)
    let running = try startServer(configuration: configuration, maxRequests: 1)
    guard case let .unixSocket(boundPath) = running.mode else {
        Issue.record("expected unix socket listener")
        return
    }

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )

    try running.wait()
    #expect(boundPath == socket.path)
    #expect(!FileManager.default.fileExists(atPath: socket.path))
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.hasSuffix(#"{"service":"mbd","status":"ok"}"#))
}

@Test func httpServerRejectsExistingRegularFileAtUnixSocketPathWithoutDeletingIt() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-file")
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("mbd.sock")
    try "do not delete me".write(to: socket, atomically: true, encoding: .utf8)

    let server = ServerHTTPServer(configuration: try ServerServeConfiguration(socketPath: socket.path))

    #expect(throws: ServerHTTPServerError.socketPathAlreadyExists(socket.path)) {
        try server.run(maxRequests: 0)
    }
    #expect(try String(contentsOf: socket, encoding: .utf8) == "do not delete me")
}

@Test func httpServerRejectsExistingDirectoryAtUnixSocketPathWithoutDeletingIt() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-dir")
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("mbd.sock", isDirectory: true)
    try FileManager.default.createDirectory(at: socket, withIntermediateDirectories: true)

    let server = ServerHTTPServer(configuration: try ServerServeConfiguration(socketPath: socket.path))

    #expect(throws: ServerHTTPServerError.socketPathAlreadyExists(socket.path)) {
        try server.run(maxRequests: 0)
    }
    var isDirectory = ObjCBool(false)
    #expect(FileManager.default.fileExists(atPath: socket.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func httpServerRejectsExistingSymlinkAtUnixSocketPathWithoutDeletingIt() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-link")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    let socket = root.appendingPathComponent("mbd.sock")
    try "target contents".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: socket.path, withDestinationPath: target.path)

    let server = ServerHTTPServer(configuration: try ServerServeConfiguration(socketPath: socket.path))

    #expect(throws: ServerHTTPServerError.socketPathAlreadyExists(socket.path)) {
        try server.run(maxRequests: 0)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: socket.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == "target contents")
}

@Test func httpServerReplacesStaleUnixSocketPath() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-stale")
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("mbd.sock")
    try createStaleUnixSocket(at: socket.path)
    #expect(isSocketPath(socket.path))

    let server = ServerHTTPServer(configuration: try ServerServeConfiguration(socketPath: socket.path))

    try server.run(maxRequests: 0)
    #expect(!FileManager.default.fileExists(atPath: socket.path))
}

@Test func httpServerRemovesCreatedUnixSocketAfterStop() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-clean")
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("mbd.sock")
    let running = try startServer(
        configuration: try ServerServeConfiguration(socketPath: socket.path),
        maxRequests: nil
    )

    guard case let .unixSocket(boundPath) = running.mode else {
        Issue.record("expected unix socket listener")
        return
    }
    #expect(boundPath == socket.path)
    #expect(isSocketPath(socket.path))

    running.server.stop()
    try running.wait()
    #expect(!FileManager.default.fileExists(atPath: socket.path))
}

@Test func httpServerRejectsOverlappingRequestsWhenLimiterIsFull() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(maximumConcurrentRequests: 1, maximumQueuedRequests: 0)
    )
    let routeHandler = BlockingRouteHandler()
    let running = try startServer(
        configuration: configuration,
        maxRequests: 2,
        routeHandler: routeHandler.route
    )

    let firstCall = sendHTTPRequestAsync(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )

    #expect(routeHandler.waitForFirstCall(timeout: .now() + 5) == .success)

    let secondCall = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health?again=true HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )

    #expect(!running.isFinished())
    routeHandler.releaseFirstCall()
    #expect(firstCall.finished.wait(timeout: .now() + 5) == .success)
    let firstCallResponse = try firstCall.state.response()
    try running.wait()
    #expect(routeHandler.callCount == 1)
    #expect(firstCallResponse.contains("HTTP/1.1 200 OK\r\n"))
    #expect(firstCallResponse.hasSuffix(#"{"ok":true}"#))
    #expect(secondCall.contains("HTTP/1.1 429 Too Many Requests\r\n"))
    #expect(secondCall.hasSuffix(#"{"error":"too_many_requests","message":"Maximum concurrent and queued requests are already in progress."}"#))
}

@Test func httpServerAllowsAuthorizedRequestsWithTrimmedBearerToken() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-auth-ok")
    defer { try? FileManager.default.removeItem(at: root) }
    let token = root.appendingPathComponent("token")
    try "\n  secret-token  \n".write(to: token, atomically: true, encoding: .utf8)

    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(authorizationTokenPath: token.path)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret-token\r\n\r\n"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.hasSuffix(#"{"service":"mbd","status":"ok"}"#))
}

@Test func httpServerRejectsRequestsMissingAuthorizationHeader() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-auth-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    let token = root.appendingPathComponent("token")
    try "secret-token".write(to: token, atomically: true, encoding: .utf8)

    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(authorizationTokenPath: token.path)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 401 Unauthorized\r\n"))
    #expect(response.hasSuffix(#"{"error":"unauthorized","message":"Authorization bearer token is missing or invalid."}"#))
}

@Test func httpServerRejectsMalformedAuthorizationBearerFormBeforeRouting() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-auth-malformed")
    defer { try? FileManager.default.removeItem(at: root) }
    let token = root.appendingPathComponent("token")
    try "secret-token".write(to: token, atomically: true, encoding: .utf8)

    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(authorizationTokenPath: token.path)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Token secret-token\r\n\r\n"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 401 Unauthorized\r\n"))
    #expect(response.hasSuffix(#"{"error":"unauthorized","message":"Authorization bearer token is missing or invalid."}"#))
}

@Test func httpServerRejectsEmptyAuthorizationTokenFileAtStartup() throws {
    let root = try temporaryServerDirectory(prefix: "mbd-auth-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    let token = root.appendingPathComponent("token")
    try " \n\t ".write(to: token, atomically: true, encoding: .utf8)

    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(authorizationTokenPath: token.path)
    )
    let server = ServerHTTPServer(configuration: configuration)

    #expect(throws: ServerHTTPServerError.emptyAuthorizationToken(token.path)) {
        try server.run(maxRequests: 0)
    }
}

@Test func httpServerRejectsMissingAuthorizationTokenFileAtStartup() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbd-auth-missing-\(UUID().uuidString)")
        .appendingPathComponent("token")
        .path
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(authorizationTokenPath: missing)
    )
    let server = ServerHTTPServer(configuration: configuration)

    #expect(throws: ServerHTTPServerError.authorizationTokenReadFailed(missing)) {
        try server.run(maxRequests: 0)
    }
}

@Test func httpServerRejectsUnreadableAuthorizationTokenFileAtStartup() throws {
    let directory = try temporaryServerDirectory(prefix: "mbd-auth-unreadable")
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(authorizationTokenPath: directory.path)
    )
    let server = ServerHTTPServer(configuration: configuration)

    #expect(throws: ServerHTTPServerError.authorizationTokenReadFailed(directory.path)) {
        try server.run(maxRequests: 0)
    }
}

@Test func httpServerAppliesRequestReadTimeout() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(requestTimeoutSeconds: 0.05)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendSlowHTTPRequest(to: running.mode, partialRequest: "GET /health HTTP/1.1\r\nHost: localhost\r\n")

    try running.wait()
    #expect(response.contains("HTTP/1.1 408 Request Timeout\r\n"))
    #expect(response.hasSuffix(#"{"error":"request_timeout","message":"HTTP request was not received before the configured timeout."}"#))
}

@Test func httpServerReturnsBadRequestForMalformedHTTP() throws {
    let configuration = try ServerServeConfiguration(host: "127.0.0.1", port: 0)
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(to: running.mode, request: "BAD REQUEST\r\n\r\n")

    try running.wait()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
    #expect(response.hasSuffix(#"{"error":"bad_request","message":"Malformed HTTP request."}"#))
}

@Test func httpServerReturnsBadRequestWhenClientClosesBeforeSendingHeaders() throws {
    let configuration = try ServerServeConfiguration(host: "127.0.0.1", port: 0)
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(to: running.mode, request: "")

    try running.wait()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
    #expect(response.hasSuffix(#"{"error":"bad_request","message":"Malformed HTTP request."}"#))
}

@Test func httpServerReturnsBadRequestForIncompleteHeadersWithMaxHeaderOverflowConfiguration() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(maxHeaderBytes: Int.max)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(to: running.mode, request: "")

    try running.wait()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
    #expect(response.hasSuffix(#"{"error":"bad_request","message":"Malformed HTTP request."}"#))
}

@Test func httpServerReturnsBadRequestForSocketReceiveFailures() throws {
    let running = try startServer(
        configuration: try ServerServeConfiguration(host: "127.0.0.1", port: 0),
        maxRequests: 1,
        receiveSocket: { _, _, _, _ in
            errno = ECONNRESET
            return -1
        }
    )

    let response = try sendHTTPRequest(to: running.mode, request: "")

    try running.wait()
    #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
    #expect(response.hasSuffix(#"{"error":"bad_request","message":"Malformed HTTP request."}"#))
}

@Test func httpServerRejectsOversizedHeaders() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(maxHeaderBytes: 32)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)
    let headerValue = String(repeating: "x", count: 64)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: localhost\r\nX-Large: \(headerValue)\r\n\r\n"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 413 Payload Too Large\r\n"))
    #expect(response.hasSuffix(#"{"error":"payload_too_large","message":"HTTP request headers exceed the configured maximum size."}"#))
}

@Test func httpServerRejectsHeadersThatGrowTooLargeBeforeDelimiter() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(maxHeaderBytes: 8)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "GET /health HTTP/1.1\r\nHost: localhost"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 413 Payload Too Large\r\n"))
    #expect(response.hasSuffix(#"{"error":"payload_too_large","message":"HTTP request headers exceed the configured maximum size."}"#))
}

@Test func httpServerRejectsOversizedDeclaredBodyBeforeReadingBody() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(maxRequestBodyBytes: 8)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "POST /v1/put HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9\r\n\r\n"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 413 Payload Too Large\r\n"))
    #expect(response.hasSuffix(#"{"error":"payload_too_large","message":"HTTP request body exceeds the configured maximum size."}"#))
}

@Test func httpServerRejectsDeclaredBodiesThatOverflowTotalRequestSize() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(maxRequestBodyBytes: Int.max)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "POST /v1/put HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(Int.max)\r\n\r\n"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 413 Payload Too Large\r\n"))
    #expect(response.hasSuffix(#"{"error":"payload_too_large","message":"HTTP request body exceeds the configured maximum size."}"#))
}

@Test func httpServerRejectsOversizedStreamingBody() throws {
    let configuration = try ServerServeConfiguration(
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: ServerFileConfiguration(maxRequestBodyBytes: 8)
    )
    let running = try startServer(configuration: configuration, maxRequests: 1)

    let response = try sendHTTPRequest(
        to: running.mode,
        request: "POST /v1/put HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9\r\n\r\nabcd"
    )

    try running.wait()
    #expect(response.contains("HTTP/1.1 413 Payload Too Large\r\n"))
    #expect(response.hasSuffix(#"{"error":"payload_too_large","message":"HTTP request body exceeds the configured maximum size."}"#))
}

@Test func httpServerSupportsExplicitRequestLimitersOnBothInitializers() throws {
    let defaultRouterServer = ServerHTTPServer(
        configuration: try ServerServeConfiguration(host: "127.0.0.1", port: 0),
        requestLimiter: ServerRequestLimiter(maximumConcurrentRequests: 1)
    )
    try defaultRouterServer.run(maxRequests: 0)

    let routeHandlerServer = ServerHTTPServer(
        configuration: try ServerServeConfiguration(host: "127.0.0.1", port: 0),
        routeHandler: { _ in ServerHTTPResponse(statusCode: 200) },
        requestLimiter: ServerRequestLimiter(maximumConcurrentRequests: 1)
    )
    try routeHandlerServer.run(maxRequests: 0)
}

@Test func httpServerCoversLocalhostDefaultReadyAndBindFailures() throws {
    let localhostServer = ServerHTTPServer(
        configuration: try ServerServeConfiguration(host: "localhost", port: 0)
    )
    try localhostServer.run(maxRequests: 0)

    let running = try startServer(
        configuration: try ServerServeConfiguration(host: "127.0.0.1", port: 0),
        maxRequests: nil
    )
    guard case let .loopback(_, port) = running.mode else {
        Issue.record("expected loopback listener")
        return
    }

    let duplicate = ServerHTTPServer(
        configuration: try ServerServeConfiguration(host: "127.0.0.1", port: port)
    )
    #expect(throws: ServerHTTPServerError.socketOperationFailed("bind")) {
        try duplicate.run(maxRequests: 0)
    }

    running.server.stop()
    try running.wait()
}

@Test func httpServerStopWakesBlockedAcceptWithoutHandlingSyntheticRequest() throws {
    let configuration = try ServerServeConfiguration(host: "127.0.0.1", port: 0)
    let routeHandler = CountingRouteHandler()
    let running = try startServer(
        configuration: configuration,
        maxRequests: nil,
        routeHandler: routeHandler.route
    )

    running.server.stop()
    try running.wait()
    #expect(routeHandler.callCount == 0)
}

@Test func httpServerStopBeforeBindingIsANoOp() throws {
    let server = ServerHTTPServer(configuration: try ServerServeConfiguration(host: "127.0.0.1", port: 0))

    server.stop()

    #expect(server.boundListenMode == nil)
}

@Test func httpServerCleansUpUnixSocketPathWhenListenFailsAfterBind() throws {
    let root = try temporaryShortUnixSocketDirectory(prefix: "mbd-listen")
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("mbd.sock")
    let server = ServerHTTPServer(
        configuration: try ServerServeConfiguration(socketPath: socket.path),
        routeHandler: { _ in ServerHTTPResponse(statusCode: 200) },
        listenSocket: { _, _ in -1 }
    )

    #expect(throws: ServerHTTPServerError.socketOperationFailed("listen")) {
        try server.run(maxRequests: 0)
    }
    #expect(!FileManager.default.fileExists(atPath: socket.path))
}

@Test func httpServerReportsLoopbackListenAndBoundPortFailures() throws {
    let listenFailure = ServerHTTPServer(
        configuration: try ServerServeConfiguration(host: "127.0.0.1", port: 0),
        routeHandler: { _ in ServerHTTPResponse(statusCode: 200) },
        listenSocket: { _, _ in -1 }
    )
    #expect(throws: ServerHTTPServerError.socketOperationFailed("listen")) {
        try listenFailure.run(maxRequests: 0)
    }

    let boundPortFailure = ServerHTTPServer(
        configuration: try ServerServeConfiguration(host: "127.0.0.1", port: 0),
        routeHandler: { _ in ServerHTTPResponse(statusCode: 200) },
        listenSocket: { descriptor, _ in
            closeTestSocket(descriptor)
            return 0
        }
    )
    #expect(throws: ServerHTTPServerError.socketOperationFailed("getsockname")) {
        try boundPortFailure.run(maxRequests: 0)
    }
}

@Test func httpServerReportsStableConfigurationErrors() throws {
    let unsupportedHost = try ServerServeConfiguration(host: "::1", port: 0)
    let unsupportedServer = ServerHTTPServer(configuration: unsupportedHost)
    #expect(throws: ServerHTTPServerError.unsupportedLoopbackHost("::1")) {
        try unsupportedServer.run(maxRequests: 0)
    }

    let longName = String(repeating: "x", count: 200)
    let longPath = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(longName)
        .path
    let longSocketServer = ServerHTTPServer(configuration: try ServerServeConfiguration(socketPath: longPath))
    #expect(throws: ServerHTTPServerError.socketPathTooLong(longPath)) {
        try longSocketServer.run(maxRequests: 0)
    }

    #expect(ServerHTTPServerError.unsupportedLoopbackHost("::1").description == "unsupported loopback host: ::1")
    #expect(ServerHTTPServerError.socketPathTooLong("/tmp/socket").description == "unix socket path is too long: /tmp/socket")
    #expect(
        ServerHTTPServerError.socketPathAlreadyExists("/tmp/socket").description
            == "unix socket path already exists and is not a socket: /tmp/socket"
    )
    #expect(ServerHTTPServerError.socketOperationFailed("bind").description == "socket operation failed: bind")
    #expect(ServerHTTPServerError.requestReadTimedOut.description == "request read timed out")
    #expect(
        ServerHTTPServerError.authorizationTokenReadFailed("/tmp/token").description
            == "authorization token file could not be read: /tmp/token"
    )
    #expect(
        ServerHTTPServerError.emptyAuthorizationToken("/tmp/token").description
            == "authorization token file is empty: /tmp/token"
    )
    #expect(
        ServerHTTPServerError.requestHeadersTooLarge(maxBytes: 32).description
            == "HTTP request headers exceed maxHeaderBytes: 32"
    )
    #expect(
        ServerHTTPServerError.requestBodyTooLarge(maxBytes: 8).description
            == "HTTP request body exceeds maxRequestBodyBytes: 8"
    )
}

#endif
