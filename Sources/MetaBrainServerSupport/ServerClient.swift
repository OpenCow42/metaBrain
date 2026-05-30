import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

public enum ServerClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case socketPathTooLong(String)
    case socketOperationFailed(String)
    case serverError(statusCode: Int, error: String, message: String)
    case unexpectedStatusCode(Int)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path):
            return "unix socket path is too long: \(path)"
        case .socketOperationFailed(let operation):
            return "socket operation failed: \(operation)"
        case .serverError(let statusCode, let error, let message):
            return "server returned HTTP \(statusCode) \(error): \(message)"
        case .unexpectedStatusCode(let statusCode):
            return "server returned unexpected HTTP \(statusCode)"
        }
    }
}

public struct MetaBrainServerClient: Sendable {
    private let codec: ServerHTTPCodec
    private let storePath: String?
    private let transport: @Sendable (Data) throws -> Data

    public init(
        socketPath: String,
        storePath: String? = nil,
        codec: ServerHTTPCodec = ServerHTTPCodec(),
        requestTimeoutMilliseconds: Int? = nil
    ) {
        self.codec = codec
        self.storePath = storePath.map(Self.canonicalStorePath)
        if let endpoint = Self.loopbackHTTPEndpoint(from: socketPath) {
            self.transport = { requestData in
                try Self.loopbackHTTPRoundTrip(
                    endpoint: endpoint,
                    requestData: requestData,
                    requestTimeoutMilliseconds: requestTimeoutMilliseconds
                )
            }
        } else {
            let expandedPath = NSString(string: socketPath).expandingTildeInPath
            self.transport = { requestData in
                try Self.unixSocketRoundTrip(path: expandedPath, requestData: requestData)
            }
        }
    }

    init(
        codec: ServerHTTPCodec = ServerHTTPCodec(),
        storePath: String? = nil,
        transport: @escaping @Sendable (Data) throws -> Data
    ) {
        self.codec = codec
        self.storePath = storePath.map(Self.canonicalStorePath)
        self.transport = transport
    }

    public func post<Response: Decodable & Sendable>(
        _ path: String,
        response: Response.Type = Response.self
    ) throws -> Response {
        try request(method: .post, path: path, body: Data("{}".utf8), response: response)
    }

    public func post<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        request: Request,
        response: Response.Type = Response.self
    ) throws -> Response {
        try self.request(
            method: .post,
            path: path,
            body: MetaBrainJSON.encoder().encode(request),
            response: response
        )
    }

    public func health() throws -> ServerHealthPayload {
        try request(method: .get, path: "/health", body: Data(), response: ServerHealthPayload.self)
    }

    public func version() throws -> VersionOutput {
        try request(method: .get, path: "/v1/version", body: Data(), response: VersionOutput.self)
    }

    private func request<Response: Decodable & Sendable>(
        method: ServerHTTPMethod,
        path: String,
        body: Data,
        response: Response.Type
    ) throws -> Response {
        let responseData = try transport(requestData(method: method, path: path, body: body))
        let httpResponse = try codec.parseResponse(responseData)
        guard httpResponse.statusCode == 200 else {
            if let payload = try? MetaBrainJSON.decoder().decode(ServerErrorPayload.self, from: httpResponse.body) {
                throw ServerClientError.serverError(
                    statusCode: httpResponse.statusCode,
                    error: payload.error,
                    message: payload.message
                )
            }
            throw ServerClientError.unexpectedStatusCode(httpResponse.statusCode)
        }
        return try MetaBrainJSON.decoder().decode(response, from: httpResponse.body)
    }

    func requestData(method: ServerHTTPMethod, path: String, body: Data) -> Data {
        var text = "\(method.rawValue) \(path) HTTP/1.1\r\n"
        text += "Host: localhost\r\n"
        text += "Accept: application/json\r\n"
        text += "Content-Type: application/json\r\n"
        if let storePath {
            text += "\(MetaBrainStoreRegistry.storePathHeader): \(MetaBrainStoreRegistry.storePathHeaderValue(for: storePath))\r\n"
        }
        text += "Content-Length: \(body.count)\r\n"
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    private static func loopbackHTTPEndpoint(from value: String) -> ServerLoopbackHTTPEndpoint? {
        guard value.hasPrefix("http://"), let components = URLComponents(string: value) else {
            return nil
        }
        guard let host = components.host, host == "127.0.0.1" || host == "localhost", let port = components.port else {
            return nil
        }
        return ServerLoopbackHTTPEndpoint(host: host, port: port)
    }

    private static func canonicalStorePath(_ storePath: String) -> String {
        URL(fileURLWithPath: NSString(string: storePath).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .path
    }
}

private struct ServerLoopbackHTTPEndpoint: Sendable {
    var host: String
    var port: Int
}

#if canImport(Darwin) || canImport(Glibc)
extension MetaBrainServerClient {
    private static func loopbackHTTPRoundTrip(
        endpoint: ServerLoopbackHTTPEndpoint,
        requestData: Data,
        requestTimeoutMilliseconds: Int?
    ) throws -> Data {
        let descriptor = socket(AF_INET, clientSocketStreamType, 0)
        guard descriptor >= 0 else { throw ServerClientError.socketOperationFailed("socket") }
        defer { closeSocket(descriptor) }
        try configureTimeout(requestTimeoutMilliseconds, for: descriptor)

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(endpoint.port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)

        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0 else { throw ServerClientError.socketOperationFailed("connect") }
            }
        }

        try writeAll(requestData, to: descriptor)
        _ = shutdown(descriptor, Int32(SHUT_WR))
        return try readAll(from: descriptor)
    }

    private static func unixSocketRoundTrip(path: String, requestData: Data) throws -> Data {
        let descriptor = try openUnixSocket(path: path)
        defer { closeSocket(descriptor) }
        try writeAll(requestData, to: descriptor)
        _ = shutdown(descriptor, Int32(SHUT_WR))
        return try readAll(from: descriptor)
    }

    private static func openUnixSocket(path: String) throws -> Int32 {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ServerClientError.socketPathTooLong(path) }

        let descriptor = socket(AF_UNIX, clientSocketStreamType, 0)
        guard descriptor >= 0 else { throw ServerClientError.socketOperationFailed("socket") }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for offset in pathBytes.indices {
                rawBuffer[offset] = pathBytes[offset]
            }
        }

        do {
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard connect(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    ) == 0 else { throw ServerClientError.socketOperationFailed("connect") }
                }
            }
        } catch {
            closeSocket(descriptor)
            throw error
        }

        return descriptor
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < data.count {
                let sent = send(descriptor, rawBuffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
                guard sent >= 0 else { throw ServerClientError.socketOperationFailed("send") }
                offset += sent
            }
        }
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count >= 0 else { throw ServerClientError.socketOperationFailed("recv") }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func configureTimeout(_ milliseconds: Int?, for descriptor: Int32) throws {
        guard let milliseconds else {
            return
        }
        let clamped = max(1, milliseconds)
        var timeout = timeval()
        timeout.tv_sec = .init(clamped / 1000)
        timeout.tv_usec = .init((clamped % 1000) * 1000)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw ServerClientError.socketOperationFailed("setsockopt(SO_RCVTIMEO)") }
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw ServerClientError.socketOperationFailed("setsockopt(SO_SNDTIMEO)") }
    }
}
#elseif !canImport(Darwin) && !canImport(Glibc)
extension MetaBrainServerClient {
    private static func unixSocketRoundTrip(path: String, requestData: Data) throws -> Data {
        _ = path
        _ = requestData
        throw ServerClientError.socketOperationFailed("unix sockets are unavailable on this platform")
    }
}
#endif

#if canImport(WinSDK)
extension MetaBrainServerClient {
    private static func loopbackHTTPRoundTrip(
        endpoint: ServerLoopbackHTTPEndpoint,
        requestData: Data,
        requestTimeoutMilliseconds: Int?
    ) throws -> Data {
        try withClientWinsock {
            let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
            guard descriptor != INVALID_SOCKET else { throw ServerClientError.socketOperationFailed("socket") }
            defer { closeSocket(descriptor) }
            try configureTimeout(requestTimeoutMilliseconds, for: descriptor)

            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_port = USHORT(UInt16(endpoint.port).bigEndian)
            address.sin_addr.S_un.S_addr = UInt32(INADDR_LOOPBACK).bigEndian

            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard connect(descriptor, socketAddress, Int32(MemoryLayout<sockaddr_in>.size)) == 0 else {
                        throw ServerClientError.socketOperationFailed("connect")
                    }
                }
            }

            try writeAll(requestData, to: descriptor)
            _ = shutdown(descriptor, SD_SEND)
            return try readAll(from: descriptor)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: SOCKET) throws {
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let sent = send(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                    Int32(rawBuffer.count - offset),
                    0
                )
                guard sent > 0 else { throw ServerClientError.socketOperationFailed("send") }
                offset += Int(sent)
            }
        }
    }

    private static func readAll(from descriptor: SOCKET) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(descriptor, rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(rawBuffer.count), 0)
            }
            guard count >= 0 else { throw ServerClientError.socketOperationFailed("recv") }
            guard count > 0 else { break }
            data.append(buffer, count: Int(count))
        }
        return data
    }

    private static func configureTimeout(_ milliseconds: Int?, for descriptor: SOCKET) throws {
        guard let milliseconds else {
            return
        }
        let timeout = DWORD(max(1, milliseconds))
        try withUnsafePointer(to: timeout) { pointer in
            let result = pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) { option in
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, option, Int32(MemoryLayout<DWORD>.size))
            }
            guard result == 0 else { throw ServerClientError.socketOperationFailed("setsockopt(SO_RCVTIMEO)") }
        }
        try withUnsafePointer(to: timeout) { pointer in
            let result = pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) { option in
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, option, Int32(MemoryLayout<DWORD>.size))
            }
            guard result == 0 else { throw ServerClientError.socketOperationFailed("setsockopt(SO_SNDTIMEO)") }
        }
    }
}
#elseif !canImport(Darwin) && !canImport(Glibc)
extension MetaBrainServerClient {
    private static func loopbackHTTPRoundTrip(
        endpoint: ServerLoopbackHTTPEndpoint,
        requestData: Data,
        requestTimeoutMilliseconds: Int?
    ) throws -> Data {
        _ = endpoint
        _ = requestData
        _ = requestTimeoutMilliseconds
        throw ServerClientError.socketOperationFailed("loopback HTTP is unavailable on this platform")
    }
}
#endif

#if canImport(Darwin) || canImport(Glibc)
private let clientSocketStreamType: Int32 = {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}()

private func closeSocket(_ descriptor: Int32) {
    _ = close(descriptor)
}
#elseif canImport(WinSDK)
private func closeSocket(_ descriptor: SOCKET) {
    _ = closesocket(descriptor)
}

private func withClientWinsock<Result>(_ operation: () throws -> Result) throws -> Result {
    var data = WSADATA()
    guard WSAStartup(WORD(0x0202), &data) == 0 else {
        throw ServerClientError.socketOperationFailed("WSAStartup")
    }
    defer { WSACleanup() }
    return try operation()
}
#endif
