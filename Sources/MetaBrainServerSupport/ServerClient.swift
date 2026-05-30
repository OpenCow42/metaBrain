import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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
    private let transport: @Sendable (Data) throws -> Data

    public init(socketPath: String, codec: ServerHTTPCodec = ServerHTTPCodec()) {
        let expandedPath = NSString(string: socketPath).expandingTildeInPath
        self.codec = codec
        self.transport = { requestData in
            try Self.unixSocketRoundTrip(path: expandedPath, requestData: requestData)
        }
    }

    init(
        codec: ServerHTTPCodec = ServerHTTPCodec(),
        transport: @escaping @Sendable (Data) throws -> Data
    ) {
        self.codec = codec
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
        text += "Content-Length: \(body.count)\r\n"
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

#if canImport(Darwin) || canImport(Glibc)
extension MetaBrainServerClient {
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
#endif
