import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

public enum ServerHTTPServerError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedLoopbackHost(String)
    case socketPathTooLong(String)
    case socketPathAlreadyExists(String)
    case socketOperationFailed(String)
    case requestReadTimedOut
    case authorizationTokenReadFailed(String)
    case emptyAuthorizationToken(String)
    case requestHeadersTooLarge(maxBytes: Int)
    case requestBodyTooLarge(maxBytes: Int)

    public var description: String {
        switch self {
        case .unsupportedLoopbackHost(let host):
            return "unsupported loopback host: \(host)"
        case .socketPathTooLong(let path):
            return "unix socket path is too long: \(path)"
        case .socketPathAlreadyExists(let path):
            return "unix socket path already exists and is not a socket: \(path)"
        case .socketOperationFailed(let operation):
            return "socket operation failed: \(operation)"
        case .requestReadTimedOut:
            return "request read timed out"
        case .authorizationTokenReadFailed(let path):
            return "authorization token file could not be read: \(path)"
        case .emptyAuthorizationToken(let path):
            return "authorization token file is empty: \(path)"
        case .requestHeadersTooLarge(let maxBytes):
            return "HTTP request headers exceed maxHeaderBytes: \(maxBytes)"
        case .requestBodyTooLarge(let maxBytes):
            return "HTTP request body exceeds maxRequestBodyBytes: \(maxBytes)"
        }
    }
}

#if canImport(Darwin) || canImport(Glibc)
public final class ServerHTTPServer: @unchecked Sendable {
    private let configuration: ServerServeConfiguration
    private let routeHandler: @Sendable (ServerHTTPRequest) -> ServerHTTPResponse
    private let codec: ServerHTTPCodec
    private let requestLimiter: ServerRequestLimiter
    private let logger: ServerStructuredLogger
    private let listenSocket: @Sendable (Int32, Int32) -> Int32
    private let receiveSocket: @Sendable (Int32, UnsafeMutableRawPointer?, Int, Int32) -> Int
    private let lock = NSLock()
    private var listeningSocket: Int32?
    private var socketPathToRemove: String?
    private var boundMode: ServerListenMode?
    private var isStopping = false

    public init(
        configuration: ServerServeConfiguration,
        router: ServerRouter? = nil,
        codec: ServerHTTPCodec = ServerHTTPCodec(),
        requestLimiter: ServerRequestLimiter? = nil,
        logger: ServerStructuredLogger = .disabled
    ) {
        let router = router ?? ServerRouter(configuration: configuration)
        self.configuration = configuration
        self.routeHandler = { request in
            router.routeBlocking(request)
        }
        self.codec = codec
        self.requestLimiter = requestLimiter ?? ServerRequestLimiter(
            maximumConcurrentRequests: configuration.maximumConcurrentRequests,
            maximumQueuedRequests: configuration.maximumQueuedRequests
        )
        self.logger = logger
        self.listenSocket = systemListen
        self.receiveSocket = systemRecv
    }

    init(
        configuration: ServerServeConfiguration,
        routeHandler: @escaping @Sendable (ServerHTTPRequest) -> ServerHTTPResponse,
        codec: ServerHTTPCodec = ServerHTTPCodec(),
        requestLimiter: ServerRequestLimiter? = nil,
        logger: ServerStructuredLogger = .disabled,
        listenSocket: @escaping @Sendable (Int32, Int32) -> Int32 = systemListen,
        receiveSocket: @escaping @Sendable (Int32, UnsafeMutableRawPointer?, Int, Int32) -> Int = systemRecv
    ) {
        self.configuration = configuration
        self.routeHandler = routeHandler
        self.codec = codec
        self.requestLimiter = requestLimiter ?? ServerRequestLimiter(
            maximumConcurrentRequests: configuration.maximumConcurrentRequests,
            maximumQueuedRequests: configuration.maximumQueuedRequests
        )
        self.logger = logger
        self.listenSocket = listenSocket
        self.receiveSocket = receiveSocket
    }

    public var boundListenMode: ServerListenMode? {
        lock.withLock { boundMode }
    }

    public func run(maxRequests: Int? = nil, onReady: @Sendable (ServerListenMode) -> Void = { _ in }) throws {
        let authorizationToken = try loadAuthorizationToken()
        let listener = try openListeningSocket()
        lock.withLock {
            listeningSocket = listener.fileDescriptor
            socketPathToRemove = listener.socketPathToRemove
            boundMode = listener.boundMode
            isStopping = false
        }
        onReady(listener.boundMode)
        let handlers = DispatchGroup()
        defer {
            handlers.wait()
            closeListeningSocket()
        }

        var handledRequests = 0
        while maxRequests.map({ handledRequests < $0 }) ?? true {
            let client = accept(listener.fileDescriptor, nil, nil)
            if client < 0 {
                if isStopped { return } else { throw ServerHTTPServerError.socketOperationFailed("accept") }
            }
            if isStopped { closeSocket(client); return }
            handlers.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { handlers.leave() }
                handle(clientSocket: client, authorizationToken: authorizationToken)
            }
            handledRequests += 1
        }
    }

    public func stop() {
        let mode = markStopping()
        wakeAcceptLoop(mode)
        closeListeningSocket()
    }

    private var isStopped: Bool {
        lock.withLock { isStopping || listeningSocket == nil }
    }

    private func markStopping() -> ServerListenMode? {
        lock.withLock {
            isStopping = true
            return boundMode
        }
    }

    private func openListeningSocket() throws -> ServerListener {
        switch configuration.listenMode {
        case .unixSocket(let path):
            return try openUnixSocket(path: path)
        case .loopback(let host, let port):
            return try openLoopbackSocket(host: host, port: port)
        }
    }

    private func openLoopbackSocket(host: String, port: Int) throws -> ServerListener {
        guard host == "127.0.0.1" || host == "localhost" else {
            throw ServerHTTPServerError.unsupportedLoopbackHost(host)
        }

        let descriptor = socket(AF_INET, serverSocketStreamType, 0)
        guard descriptor >= 0 else { throw ServerHTTPServerError.socketOperationFailed("socket") }

        do {
            var reuse: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuse,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else { throw ServerHTTPServerError.socketOperationFailed("setsockopt") }

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)

            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard bind(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    ) == 0 else { throw ServerHTTPServerError.socketOperationFailed("bind") }
                }
            }

            guard listenSocket(descriptor, 16) == 0 else {
                throw ServerHTTPServerError.socketOperationFailed("listen")
            }

            let boundPort = try boundLoopbackPort(for: descriptor)
            return ServerListener(
                fileDescriptor: descriptor,
                boundMode: .loopback(host: "127.0.0.1", port: boundPort)
            )
        } catch {
            closeSocket(descriptor)
            throw error
        }
    }

    private func openUnixSocket(path: String) throws -> ServerListener {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var address = sockaddr_un()
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(expandedPath.utf8)
        guard pathBytes.count < maxPathLength else {
            throw ServerHTTPServerError.socketPathTooLong(expandedPath)
        }
        try prepareUnixSocketPath(expandedPath)

        let descriptor = socket(AF_UNIX, serverSocketStreamType, 0)
        guard descriptor >= 0 else { throw ServerHTTPServerError.socketOperationFailed("socket") }

        var didBindSocketPath = false
        do {
            address.sun_family = sa_family_t(AF_UNIX)

            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                for offset in pathBytes.indices {
                    rawBuffer[offset] = pathBytes[offset]
                }
            }

            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard bind(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    ) == 0 else { throw ServerHTTPServerError.socketOperationFailed("bind") }
                    didBindSocketPath = true
                }
            }

            guard listenSocket(descriptor, 16) == 0 else {
                throw ServerHTTPServerError.socketOperationFailed("listen")
            }

            return ServerListener(
                fileDescriptor: descriptor,
                boundMode: .unixSocket(path: expandedPath),
                socketPathToRemove: expandedPath
            )
        } catch {
            closeSocket(descriptor)
            if didBindSocketPath {
                _ = unlink(expandedPath)
            }
            throw error
        }
    }

    private func prepareUnixSocketPath(_ path: String) throws {
        var status = stat()
        guard systemLstat(path, &status) == 0 else {
            if errno != ENOENT { throw ServerHTTPServerError.socketOperationFailed("lstat") }
            return
        }

        guard isSocketFile(status.st_mode) else {
            throw ServerHTTPServerError.socketPathAlreadyExists(path)
        }
        guard unlink(path) == 0 else { throw ServerHTTPServerError.socketOperationFailed("unlink") }
    }

    private func boundLoopbackPort(for descriptor: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard getsockname(descriptor, socketAddress, &length) == 0 else {
                    throw ServerHTTPServerError.socketOperationFailed("getsockname")
                }
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func loadAuthorizationToken() throws -> String? {
        guard let path = configuration.authorizationTokenPath else {
            return nil
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ServerHTTPServerError.authorizationTokenReadFailed(path)
        }

        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ServerHTTPServerError.emptyAuthorizationToken(path)
        }
        return token
    }

    private func handle(clientSocket: Int32, authorizationToken: String?) {
        defer { closeSocket(clientSocket) }
        var parsedRequest: ServerHTTPRequest?

        do {
            try configureRequestTimeout(for: clientSocket)
            let requestData = try readRequest(from: clientSocket)
            let request = try codec.parseRequest(requestData)
            parsedRequest = request
            logger.requestStarted(request)
            let response = route(request, authorizationToken: authorizationToken)
            logger.requestCompleted(request, response: response)
            try write(codec.serializeResponse(response), to: clientSocket)
        } catch ServerHTTPServerError.requestReadTimedOut {
            let response = errorResponse(
                statusCode: 408,
                error: "request_timeout",
                message: "HTTP request was not received before the configured timeout."
            )
            logger.requestFailed(parsedRequest, response: response, error: ServerHTTPServerError.requestReadTimedOut)
            try? write(codec.serializeResponse(response), to: clientSocket)
        } catch let serverError as ServerHTTPServerError {
            let response = payloadTooLargeResponse(for: serverError) ?? malformedRequestResponse()
            logger.requestFailed(parsedRequest, response: response, error: serverError)
            try? write(codec.serializeResponse(response), to: clientSocket)
        } catch {
            let response = malformedRequestResponse()
            logger.requestFailed(parsedRequest, response: response, error: error)
            try? write(codec.serializeResponse(response), to: clientSocket)
        }
    }

    private func payloadTooLargeResponse(for error: ServerHTTPServerError) -> ServerHTTPResponse? {
        switch error {
        case .requestHeadersTooLarge:
            return errorResponse(
                statusCode: 413,
                error: "payload_too_large",
                message: "HTTP request headers exceed the configured maximum size."
            )
        case .requestBodyTooLarge:
            return errorResponse(
                statusCode: 413,
                error: "payload_too_large",
                message: "HTTP request body exceeds the configured maximum size."
            )
        default:
            return nil
        }
    }

    private func route(_ request: ServerHTTPRequest, authorizationToken: String?) -> ServerHTTPResponse {
        guard isAuthorized(request, token: authorizationToken) else {
            return errorResponse(
                statusCode: 401,
                error: "unauthorized",
                message: "Authorization bearer token is missing or invalid."
            )
        }

        guard requestLimiter.tryAcquire() else {
            return errorResponse(
                statusCode: 429,
                error: "too_many_requests",
                message: "Maximum concurrent and queued requests are already in progress."
            )
        }

        defer { requestLimiter.release() }
        return routeHandler(request)
    }

    private func isAuthorized(_ request: ServerHTTPRequest, token expectedToken: String?) -> Bool {
        guard let expectedToken else {
            return true
        }
        guard let header = request.headers.first(where: { $0.key.lowercased() == "authorization" })?.value else {
            return false
        }

        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else {
            return false
        }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) == expectedToken
    }

    private func configureRequestTimeout(for clientSocket: Int32) throws {
        let requestTimeoutSeconds = configuration.requestTimeoutSeconds
        var timeout = timeval()
        let wholeSeconds = Int(requestTimeoutSeconds.rounded(.down))
        let fractionalSeconds = requestTimeoutSeconds - Double(wholeSeconds)
        let microseconds = min(999_999, max(1, Int((fractionalSeconds * 1_000_000).rounded())))
        timeout.tv_sec = .init(wholeSeconds)
        timeout.tv_usec = .init(microseconds)

        guard setsockopt(
            clientSocket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw ServerHTTPServerError.socketOperationFailed("setsockopt(SO_RCVTIMEO)") }
    }

    private func readRequest(from clientSocket: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while try shouldContinueReading(data) {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                receiveSocket(clientSocket, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if count > 0 {
                data.append(buffer, count: count)
                try validateRequestSize(data)
                continue
            }
            if count == 0 {
                throw ServerHTTPCodecError.missingHeaderTerminator
            }
            throw isRequestReadTimeout()
                ? ServerHTTPServerError.requestReadTimedOut
                : ServerHTTPServerError.socketOperationFailed("recv")
        }
        return data
    }

    private func shouldContinueReading(_ data: Data) throws -> Bool {
        guard let expectedCount = try validatedExpectedRequestByteCount(data) else {
            return true
        }
        return data.count < expectedCount
    }

    private func validateRequestSize(_ data: Data) throws {
        _ = try validatedExpectedRequestByteCount(data)
    }

    private func validatedExpectedRequestByteCount(_ data: Data) throws -> Int? {
        guard let headerEnd = optionalHeaderEndIndex(in: data) else {
            if data.count > maxBufferedHeaderBytes {
                throw ServerHTTPServerError.requestHeadersTooLarge(maxBytes: configuration.maxHeaderBytes)
            }
            return nil
        }

        guard headerEnd <= configuration.maxHeaderBytes else {
            throw ServerHTTPServerError.requestHeadersTooLarge(maxBytes: configuration.maxHeaderBytes)
        }

        let declaredBodyLength = try codec.expectedRequestBodyByteCount(data)!
        guard declaredBodyLength <= configuration.maxRequestBodyBytes else {
            throw ServerHTTPServerError.requestBodyTooLarge(maxBytes: configuration.maxRequestBodyBytes)
        }

        let bodyStart = headerEnd + 4
        guard declaredBodyLength <= Int.max - bodyStart else {
            throw ServerHTTPServerError.requestBodyTooLarge(maxBytes: configuration.maxRequestBodyBytes)
        }
        return bodyStart + declaredBodyLength
    }

    private func optionalHeaderEndIndex(in data: Data) -> Int? {
        data.range(of: Data("\r\n\r\n".utf8))?.lowerBound
    }

    private var maxBufferedHeaderBytes: Int {
        if configuration.maxHeaderBytes > Int.max - 3 {
            return Int.max
        }
        return configuration.maxHeaderBytes + 3
    }

    private func write(_ data: Data, to clientSocket: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            var sent = 0
            while sent < rawBuffer.count {
                let count = send(
                    clientSocket,
                    rawBuffer.baseAddress!.advanced(by: sent),
                    rawBuffer.count - sent,
                    0
                )
                guard count > 0 else { throw ServerHTTPServerError.socketOperationFailed("send") }
                sent += count
            }
        }
    }

    private func errorResponse(statusCode: Int, error: String, message: String) -> ServerHTTPResponse {
        ServerHTTPResponse(
            statusCode: statusCode,
            headers: [
                "Cache-Control": "no-store",
                "Content-Type": "application/json; charset=utf-8",
            ],
            body: Data(#"{"error":"\#(error)","message":"\#(message)"}"#.utf8)
        )
    }

    private func malformedRequestResponse() -> ServerHTTPResponse {
        errorResponse(
            statusCode: 400,
            error: "bad_request",
            message: "Malformed HTTP request."
        )
    }

    private func closeListeningSocket() {
        let socketAndPath = lock.withLock {
            let value = (listeningSocket, socketPathToRemove)
            listeningSocket = nil
            socketPathToRemove = nil
            boundMode = nil
            return value
        }
        if let descriptor = socketAndPath.0 {
            closeSocket(descriptor)
        }
        if let path = socketAndPath.1 {
            _ = try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func wakeAcceptLoop(_ mode: ServerListenMode?) {
        guard let mode else {
            return
        }
        let descriptor = socketDescriptor(for: mode)
        if descriptor >= 0 {
            defer { closeSocket(descriptor) }
            try? connectSocket(descriptor, to: mode)
        }
    }

    private func socketDescriptor(for mode: ServerListenMode) -> Int32 {
        switch mode {
        case .loopback:
            socket(AF_INET, serverSocketStreamType, 0)
        case .unixSocket:
            socket(AF_UNIX, serverSocketStreamType, 0)
        }
    }

    private func connectSocket(_ descriptor: Int32, to mode: ServerListenMode) throws {
        switch mode {
        case .loopback(_, let port):
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard connect(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    ) == 0 else { throw ServerHTTPServerError.socketOperationFailed("connect") }
                }
            }
        case .unixSocket(let path):
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                for offset in pathBytes.indices {
                    rawBuffer[offset] = pathBytes[offset]
                }
            }
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard connect(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    ) == 0 else { throw ServerHTTPServerError.socketOperationFailed("connect") }
                }
            }
        }
    }
}

private struct ServerListener {
    var fileDescriptor: Int32
    var boundMode: ServerListenMode
    var socketPathToRemove: String?
}

private let serverSocketStreamType: Int32 = {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}()

private func closeSocket(_ descriptor: Int32) {
    _ = close(descriptor)
}

private func systemListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(descriptor, backlog)
    #else
    Glibc.listen(descriptor, backlog)
    #endif
}

private func systemRecv(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ length: Int, _ flags: Int32) -> Int {
    recv(descriptor, buffer, length, flags)
}

private func systemLstat(_ path: String, _ status: UnsafeMutablePointer<stat>) -> Int32 {
    #if canImport(Darwin)
    Darwin.lstat(path, status)
    #else
    Glibc.lstat(path, status)
    #endif
}

private func isSocketFile(_ mode: mode_t) -> Bool {
    (mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
}

private func isRequestReadTimeout() -> Bool {
    #if canImport(Darwin)
    errno == EAGAIN
    #else
    errno == EAGAIN || errno == EWOULDBLOCK
    #endif
}
#elseif canImport(WinSDK)
public final class ServerHTTPServer: @unchecked Sendable {
    private let configuration: ServerServeConfiguration
    private let routeHandler: @Sendable (ServerHTTPRequest) -> ServerHTTPResponse
    private let codec: ServerHTTPCodec
    private let requestLimiter: ServerRequestLimiter
    private let logger: ServerStructuredLogger
    private let lock = NSLock()
    private var listeningSocket: SOCKET?
    private var boundMode: ServerListenMode?
    private var isStopping = false

    public init(
        configuration: ServerServeConfiguration,
        router: ServerRouter? = nil,
        codec: ServerHTTPCodec = ServerHTTPCodec(),
        requestLimiter: ServerRequestLimiter? = nil,
        logger: ServerStructuredLogger = .disabled
    ) {
        let router = router ?? ServerRouter(configuration: configuration)
        self.configuration = configuration
        self.routeHandler = { request in
            router.routeBlocking(request)
        }
        self.codec = codec
        self.requestLimiter = requestLimiter ?? ServerRequestLimiter(
            maximumConcurrentRequests: configuration.maximumConcurrentRequests,
            maximumQueuedRequests: configuration.maximumQueuedRequests
        )
        self.logger = logger
    }

    public var boundListenMode: ServerListenMode? {
        lock.withLock { boundMode }
    }

    public func run(maxRequests: Int? = nil, onReady: @Sendable (ServerListenMode) -> Void = { _ in }) throws {
        try withWinsock {
            let authorizationToken = try loadAuthorizationToken()
            let listener = try openListeningSocket()
            lock.withLock {
                listeningSocket = listener.fileDescriptor
                boundMode = listener.boundMode
                isStopping = false
            }
            onReady(listener.boundMode)
            let handlers = DispatchGroup()
            defer {
                handlers.wait()
                closeListeningSocket()
            }

            var handledRequests = 0
            while maxRequests.map({ handledRequests < $0 }) ?? true {
                let client = accept(listener.fileDescriptor, nil, nil)
                if client == INVALID_SOCKET {
                    if isStopped { return } else { throw ServerHTTPServerError.socketOperationFailed("accept") }
                }
                if isStopped {
                    closeSocket(client)
                    return
                }
                handlers.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { handlers.leave() }
                    handle(clientSocket: client, authorizationToken: authorizationToken)
                }
                handledRequests += 1
            }
        }
    }

    public func stop() {
        let mode = markStopping()
        wakeAcceptLoop(mode)
        closeListeningSocket()
    }

    private var isStopped: Bool {
        lock.withLock { isStopping || listeningSocket == nil }
    }

    private func markStopping() -> ServerListenMode? {
        lock.withLock {
            isStopping = true
            return boundMode
        }
    }

    private func openListeningSocket() throws -> ServerListener {
        switch configuration.listenMode {
        case .unixSocket:
            throw ServerHTTPServerError.socketOperationFailed("unix sockets are unavailable on this platform")
        case .loopback(let host, let port):
            return try openLoopbackSocket(host: host, port: port)
        }
    }

    private func openLoopbackSocket(host: String, port: Int) throws -> ServerListener {
        guard host == "127.0.0.1" || host == "localhost" else {
            throw ServerHTTPServerError.unsupportedLoopbackHost(host)
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        guard descriptor != INVALID_SOCKET else { throw ServerHTTPServerError.socketOperationFailed("socket") }

        do {
            var reuse: Int32 = 1
            try withUnsafePointer(to: &reuse) { pointer in
                let result = pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) { option in
                    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, option, Int32(MemoryLayout<Int32>.size))
                }
                guard result == 0 else { throw ServerHTTPServerError.socketOperationFailed("setsockopt") }
            }

            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_port = USHORT(UInt16(port).bigEndian)
            address.sin_addr.S_un.S_addr = UInt32(INADDR_LOOPBACK).bigEndian

            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard bind(descriptor, socketAddress, Int32(MemoryLayout<sockaddr_in>.size)) == 0 else {
                        throw ServerHTTPServerError.socketOperationFailed("bind")
                    }
                }
            }

            guard listen(descriptor, 16) == 0 else {
                throw ServerHTTPServerError.socketOperationFailed("listen")
            }

            let boundPort = try boundLoopbackPort(for: descriptor)
            return ServerListener(
                fileDescriptor: descriptor,
                boundMode: .loopback(host: "127.0.0.1", port: boundPort)
            )
        } catch {
            closeSocket(descriptor)
            throw error
        }
    }

    private func boundLoopbackPort(for descriptor: SOCKET) throws -> Int {
        var address = sockaddr_in()
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard getsockname(descriptor, socketAddress, &length) == 0 else {
                    throw ServerHTTPServerError.socketOperationFailed("getsockname")
                }
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func loadAuthorizationToken() throws -> String? {
        guard let path = configuration.authorizationTokenPath else {
            return nil
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ServerHTTPServerError.authorizationTokenReadFailed(path)
        }

        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ServerHTTPServerError.emptyAuthorizationToken(path)
        }
        return token
    }

    private func handle(clientSocket: SOCKET, authorizationToken: String?) {
        defer { closeSocket(clientSocket) }
        var parsedRequest: ServerHTTPRequest?

        do {
            try configureRequestTimeout(for: clientSocket)
            let requestData = try readRequest(from: clientSocket)
            let request = try codec.parseRequest(requestData)
            parsedRequest = request
            logger.requestStarted(request)
            let response = route(request, authorizationToken: authorizationToken)
            logger.requestCompleted(request, response: response)
            try write(codec.serializeResponse(response), to: clientSocket)
        } catch ServerHTTPServerError.requestReadTimedOut {
            let response = errorResponse(
                statusCode: 408,
                error: "request_timeout",
                message: "HTTP request was not received before the configured timeout."
            )
            logger.requestFailed(parsedRequest, response: response, error: ServerHTTPServerError.requestReadTimedOut)
            try? write(codec.serializeResponse(response), to: clientSocket)
        } catch let serverError as ServerHTTPServerError {
            let response = payloadTooLargeResponse(for: serverError) ?? malformedRequestResponse()
            logger.requestFailed(parsedRequest, response: response, error: serverError)
            try? write(codec.serializeResponse(response), to: clientSocket)
        } catch {
            let response = malformedRequestResponse()
            logger.requestFailed(parsedRequest, response: response, error: error)
            try? write(codec.serializeResponse(response), to: clientSocket)
        }
    }

    private func payloadTooLargeResponse(for error: ServerHTTPServerError) -> ServerHTTPResponse? {
        switch error {
        case .requestHeadersTooLarge:
            return errorResponse(
                statusCode: 413,
                error: "payload_too_large",
                message: "HTTP request headers exceed the configured maximum size."
            )
        case .requestBodyTooLarge:
            return errorResponse(
                statusCode: 413,
                error: "payload_too_large",
                message: "HTTP request body exceeds the configured maximum size."
            )
        default:
            return nil
        }
    }

    private func route(_ request: ServerHTTPRequest, authorizationToken: String?) -> ServerHTTPResponse {
        guard isAuthorized(request, token: authorizationToken) else {
            return errorResponse(
                statusCode: 401,
                error: "unauthorized",
                message: "Authorization bearer token is missing or invalid."
            )
        }

        guard requestLimiter.tryAcquire() else {
            return errorResponse(
                statusCode: 429,
                error: "too_many_requests",
                message: "Maximum concurrent and queued requests are already in progress."
            )
        }

        defer { requestLimiter.release() }
        return routeHandler(request)
    }

    private func isAuthorized(_ request: ServerHTTPRequest, token expectedToken: String?) -> Bool {
        guard let expectedToken else {
            return true
        }
        guard let header = request.headers.first(where: { $0.key.lowercased() == "authorization" })?.value else {
            return false
        }

        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else {
            return false
        }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) == expectedToken
    }

    private func configureRequestTimeout(for clientSocket: SOCKET) throws {
        let milliseconds = DWORD(max(1, Int((configuration.requestTimeoutSeconds * 1000).rounded())))
        try withUnsafePointer(to: milliseconds) { pointer in
            let result = pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) { option in
                setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, option, Int32(MemoryLayout<DWORD>.size))
            }
            guard result == 0 else { throw ServerHTTPServerError.socketOperationFailed("setsockopt(SO_RCVTIMEO)") }
        }
    }

    private func readRequest(from clientSocket: SOCKET) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while try shouldContinueReading(data) {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(clientSocket, rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(rawBuffer.count), 0)
            }
            if count > 0 {
                data.append(buffer, count: Int(count))
                try validateRequestSize(data)
                continue
            }
            if count == 0 {
                throw ServerHTTPCodecError.missingHeaderTerminator
            }
            throw isRequestReadTimeout()
                ? ServerHTTPServerError.requestReadTimedOut
                : ServerHTTPServerError.socketOperationFailed("recv")
        }
        return data
    }

    private func shouldContinueReading(_ data: Data) throws -> Bool {
        guard let expectedCount = try validatedExpectedRequestByteCount(data) else {
            return true
        }
        return data.count < expectedCount
    }

    private func validateRequestSize(_ data: Data) throws {
        _ = try validatedExpectedRequestByteCount(data)
    }

    private func validatedExpectedRequestByteCount(_ data: Data) throws -> Int? {
        guard let headerEnd = optionalHeaderEndIndex(in: data) else {
            if data.count > maxBufferedHeaderBytes {
                throw ServerHTTPServerError.requestHeadersTooLarge(maxBytes: configuration.maxHeaderBytes)
            }
            return nil
        }

        guard headerEnd <= configuration.maxHeaderBytes else {
            throw ServerHTTPServerError.requestHeadersTooLarge(maxBytes: configuration.maxHeaderBytes)
        }

        let declaredBodyLength = try codec.expectedRequestBodyByteCount(data)!
        guard declaredBodyLength <= configuration.maxRequestBodyBytes else {
            throw ServerHTTPServerError.requestBodyTooLarge(maxBytes: configuration.maxRequestBodyBytes)
        }

        let bodyStart = headerEnd + 4
        guard declaredBodyLength <= Int.max - bodyStart else {
            throw ServerHTTPServerError.requestBodyTooLarge(maxBytes: configuration.maxRequestBodyBytes)
        }
        return bodyStart + declaredBodyLength
    }

    private func optionalHeaderEndIndex(in data: Data) -> Int? {
        data.range(of: Data("\r\n\r\n".utf8))?.lowerBound
    }

    private var maxBufferedHeaderBytes: Int {
        if configuration.maxHeaderBytes > Int.max - 3 {
            return Int.max
        }
        return configuration.maxHeaderBytes + 3
    }

    private func write(_ data: Data, to clientSocket: SOCKET) throws {
        try data.withUnsafeBytes { rawBuffer in
            var sent = 0
            while sent < rawBuffer.count {
                let count = send(
                    clientSocket,
                    rawBuffer.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self),
                    Int32(rawBuffer.count - sent),
                    0
                )
                guard count > 0 else { throw ServerHTTPServerError.socketOperationFailed("send") }
                sent += Int(count)
            }
        }
    }

    private func errorResponse(statusCode: Int, error: String, message: String) -> ServerHTTPResponse {
        ServerHTTPResponse(
            statusCode: statusCode,
            headers: [
                "Cache-Control": "no-store",
                "Content-Type": "application/json; charset=utf-8",
            ],
            body: Data(#"{"error":"\#(error)","message":"\#(message)"}"#.utf8)
        )
    }

    private func malformedRequestResponse() -> ServerHTTPResponse {
        errorResponse(
            statusCode: 400,
            error: "bad_request",
            message: "Malformed HTTP request."
        )
    }

    private func closeListeningSocket() {
        let descriptor = lock.withLock {
            let value = listeningSocket
            listeningSocket = nil
            boundMode = nil
            return value
        }
        if let descriptor {
            closeSocket(descriptor)
        }
    }

    private func wakeAcceptLoop(_ mode: ServerListenMode?) {
        guard let mode else {
            return
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        if descriptor != INVALID_SOCKET {
            defer { closeSocket(descriptor) }
            try? connectSocket(descriptor, to: mode)
        }
    }

    private func connectSocket(_ descriptor: SOCKET, to mode: ServerListenMode) throws {
        guard case .loopback(_, let port) = mode else {
            return
        }
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = USHORT(UInt16(port).bigEndian)
        address.sin_addr.S_un.S_addr = UInt32(INADDR_LOOPBACK).bigEndian
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard connect(descriptor, socketAddress, Int32(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ServerHTTPServerError.socketOperationFailed("connect")
                }
            }
        }
    }
}

private struct ServerListener {
    var fileDescriptor: SOCKET
    var boundMode: ServerListenMode
}

private func closeSocket(_ descriptor: SOCKET) {
    _ = closesocket(descriptor)
}

private func withWinsock<Result>(_ operation: () throws -> Result) throws -> Result {
    var data = WSADATA()
    guard WSAStartup(WORD(0x0202), &data) == 0 else {
        throw ServerHTTPServerError.socketOperationFailed("WSAStartup")
    }
    defer { WSACleanup() }
    return try operation()
}

private func isRequestReadTimeout() -> Bool {
    WSAGetLastError() == WSAETIMEDOUT || WSAGetLastError() == WSAEWOULDBLOCK
}
#endif
