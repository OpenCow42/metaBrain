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

struct RunningServer {
    var server: ServerHTTPServer
    var mode: ServerListenMode
    var isFinished: () -> Bool
    var wait: () throws -> Void
}

final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMode: ServerListenMode?
    private var storedError: Error?
    private var storedFinished = false

    var mode: ServerListenMode? {
        get { lock.withLock { storedMode } }
        set { lock.withLock { storedMode = newValue } }
    }

    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }

    var isFinished: Bool {
        get { lock.withLock { storedFinished } }
        set { lock.withLock { storedFinished = newValue } }
    }
}

final class HTTPResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<String, Error>?

    func complete(_ result: Result<String, Error>) {
        lock.withLock {
            storedResult = result
        }
    }

    func response() throws -> String {
        let result = try #require(lock.withLock { storedResult })
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

final class BlockingRouteHandler: @unchecked Sendable {
    private let lock = NSLock()
    private let firstCallStarted = DispatchSemaphore(value: 0)
    private let firstCallCanComplete = DispatchSemaphore(value: 0)
    private var routedCalls = 0

    var callCount: Int {
        lock.withLock { routedCalls }
    }

    func route(_ request: ServerHTTPRequest) -> ServerHTTPResponse {
        lock.withLock {
            routedCalls += 1
        }
        firstCallStarted.signal()
        _ = firstCallCanComplete.wait(timeout: .now() + 5)
        return ServerHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data(#"{"ok":true}"#.utf8)
        )
    }

    func waitForFirstCall(timeout: DispatchTime) -> DispatchTimeoutResult {
        firstCallStarted.wait(timeout: timeout)
    }

    func releaseFirstCall() {
        firstCallCanComplete.signal()
    }
}

final class CountingRouteHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var routedCalls = 0

    var callCount: Int {
        lock.withLock { routedCalls }
    }

    func route(_ request: ServerHTTPRequest) -> ServerHTTPResponse {
        lock.withLock {
            routedCalls += 1
        }
        return ServerHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data(#"{"ok":true}"#.utf8)
        )
    }
}

func startServer(
    configuration: ServerServeConfiguration,
    maxRequests: Int?,
    routeHandler: (@Sendable (ServerHTTPRequest) -> ServerHTTPResponse)? = nil,
    requestLimiter: ServerRequestLimiter? = nil,
    receiveSocket: (@Sendable (Int32, UnsafeMutableRawPointer?, Int, Int32) -> Int)? = nil,
    logger: ServerStructuredLogger = .disabled
) throws -> RunningServer {
    let server: ServerHTTPServer
    if let receiveSocket {
        server = ServerHTTPServer(
            configuration: configuration,
            routeHandler: routeHandler ?? { _ in ServerHTTPResponse(statusCode: 200) },
            requestLimiter: requestLimiter,
            logger: logger,
            receiveSocket: receiveSocket
        )
    } else if let routeHandler {
        server = ServerHTTPServer(
            configuration: configuration,
            routeHandler: routeHandler,
            requestLimiter: requestLimiter,
            logger: logger
        )
    } else {
        server = ServerHTTPServer(configuration: configuration, requestLimiter: requestLimiter, logger: logger)
    }
    let state = ServerState()
    let ready = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)

    Thread {
        do {
            try server.run(maxRequests: maxRequests) { mode in
                state.mode = mode
                ready.signal()
            }
        } catch {
            state.error = error
            ready.signal()
        }
        state.isFinished = true
        done.signal()
    }.start()

    #expect(ready.wait(timeout: .now() + 5) == .success)
    if let error = state.error {
        throw error
    }
    let mode = try #require(state.mode)

    return RunningServer(
        server: server,
        mode: mode,
        isFinished: {
            state.isFinished
        },
        wait: {
            #expect(done.wait(timeout: .now() + 5) == .success)
            if let error = state.error {
                throw error
            }
        }
    )
}

func sendHTTPRequestAsync(
    to mode: ServerListenMode,
    request: String
) -> (state: HTTPResponseState, finished: DispatchSemaphore) {
    let state = HTTPResponseState()
    let finished = DispatchSemaphore(value: 0)
    Thread {
        do {
            state.complete(.success(try sendHTTPRequest(to: mode, request: request)))
        } catch {
            state.complete(.failure(error))
        }
        finished.signal()
    }.start()
    return (state, finished)
}

func sendHTTPRequest(to mode: ServerListenMode, request: String) throws -> String {
    let descriptor = socketDescriptor(for: mode)
    guard descriptor >= 0 else {
        throw ServerHTTPServerError.socketOperationFailed("socket")
    }
    defer { closeTestSocket(descriptor) }

    try connectSocket(descriptor, to: mode)
    try write(Data(request.utf8), to: descriptor)
    shutdown(descriptor, Int32(SHUT_WR))
    return String(decoding: try readAll(from: descriptor), as: UTF8.self)
}

func sendSlowHTTPRequest(to mode: ServerListenMode, partialRequest: String) throws -> String {
    let descriptor = socketDescriptor(for: mode)
    guard descriptor >= 0 else {
        throw ServerHTTPServerError.socketOperationFailed("socket")
    }
    defer { closeTestSocket(descriptor) }

    try connectSocket(descriptor, to: mode)
    try write(Data(partialRequest.utf8), to: descriptor)
    return String(decoding: try readAll(from: descriptor), as: UTF8.self)
}

func socketDescriptor(for mode: ServerListenMode) -> Int32 {
    switch mode {
    case .loopback:
        return socket(AF_INET, testSocketStreamType, 0)
    case .unixSocket:
        return socket(AF_UNIX, testSocketStreamType, 0)
    }
}

func connectSocket(_ descriptor: Int32, to mode: ServerListenMode) throws {
    switch mode {
    case .loopback(_, let port):
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard systemConnect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ServerHTTPServerError.socketOperationFailed("connect")
                }
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
                guard systemConnect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 else {
                    throw ServerHTTPServerError.socketOperationFailed("connect")
                }
            }
        }
    }
}

func write(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        var sent = 0
        while sent < rawBuffer.count {
            let count = send(descriptor, rawBuffer.baseAddress!.advanced(by: sent), rawBuffer.count - sent, 0)
            guard count > 0 else {
                throw ServerHTTPServerError.socketOperationFailed("send")
            }
            sent += count
        }
    }
}

func readAll(from descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count == 0 {
            return data
        }
        guard count > 0 else {
            throw ServerHTTPServerError.socketOperationFailed("recv")
        }
        data.append(buffer, count: count)
    }
}

func closeTestSocket(_ descriptor: Int32) {
    _ = close(descriptor)
}

func temporaryServerDirectory(prefix: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func temporaryShortUnixSocketDirectory(prefix: String) throws -> URL {
    let root = URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func createStaleUnixSocket(at path: String) throws {
    let descriptor = socket(AF_UNIX, testSocketStreamType, 0)
    guard descriptor >= 0 else {
        throw ServerHTTPServerError.socketOperationFailed("socket")
    }
    defer { closeTestSocket(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw ServerHTTPServerError.socketPathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        for offset in pathBytes.indices {
            rawBuffer[offset] = pathBytes[offset]
        }
    }
    try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            guard systemBind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 else {
                throw ServerHTTPServerError.socketOperationFailed("bind")
            }
        }
    }
}

func isSocketPath(_ path: String) -> Bool {
    var status = stat()
    guard systemLstat(path, &status) == 0 else {
        return false
    }
    return (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
}

let testSocketStreamType: Int32 = {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}()

func systemConnect(
    _ descriptor: Int32,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
    #if canImport(Darwin)
    Darwin.connect(descriptor, address, length)
    #else
    Glibc.connect(descriptor, address, length)
    #endif
}

func systemBind(
    _ descriptor: Int32,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
    #if canImport(Darwin)
    Darwin.bind(descriptor, address, length)
    #else
    Glibc.bind(descriptor, address, length)
    #endif
}

func systemLstat(_ path: String, _ status: UnsafeMutablePointer<stat>) -> Int32 {
    #if canImport(Darwin)
    Darwin.lstat(path, status)
    #else
    Glibc.lstat(path, status)
    #endif
}

#endif
