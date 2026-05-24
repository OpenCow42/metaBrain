import Foundation

public enum ServerHTTPMethod: String, Codable, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case head = "HEAD"
    case options = "OPTIONS"
}

public struct ServerHTTPRequest: Equatable, Sendable {
    public var method: ServerHTTPMethod
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(
        method: ServerHTTPMethod,
        path: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct ServerHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var bodyText: String {
        String(decoding: body, as: UTF8.self)
    }
}

public enum ServerHTTPCodecError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidUTF8
    case missingHeaderTerminator
    case malformedRequestLine
    case malformedStatusLine
    case unsupportedMethod(String)
    case invalidStatusCode(String)
    case malformedHeader(String)
    case invalidContentLength(String)
    case incompleteBody(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .invalidUTF8:
            return "HTTP message must be valid UTF-8"
        case .missingHeaderTerminator:
            return "HTTP headers must end with CRLF CRLF"
        case .malformedRequestLine:
            return "HTTP request line must be METHOD PATH HTTP/1.1"
        case .malformedStatusLine:
            return "HTTP status line must be HTTP/1.1 STATUS REASON"
        case .unsupportedMethod(let method):
            return "unsupported HTTP method: \(method)"
        case .invalidStatusCode(let value):
            return "invalid HTTP status code: \(value)"
        case .malformedHeader(let header):
            return "malformed HTTP header: \(header)"
        case .invalidContentLength(let value):
            return "invalid Content-Length header: \(value)"
        case .incompleteBody(let expected, let actual):
            return "HTTP body is incomplete: expected \(expected) bytes, got \(actual)"
        }
    }
}

public struct ServerHTTPCodec: Sendable {
    public init() {}

    public func parseRequest(_ data: Data) throws -> ServerHTTPRequest {
        let headerEnd = try headerEndIndex(in: data)
        let headerData = data[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ServerHTTPCodecError.invalidUTF8
        }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines[0]
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3, requestParts[2] == "HTTP/1.1" else {
            throw ServerHTTPCodecError.malformedRequestLine
        }

        let methodName = String(requestParts[0])
        guard let method = ServerHTTPMethod(rawValue: methodName) else {
            throw ServerHTTPCodecError.unsupportedMethod(methodName)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ServerHTTPCodecError.malformedHeader(line)
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ServerHTTPCodecError.malformedHeader(line)
            }
            headers[name] = value
        }

        let bodyStart = headerEnd + 4
        let declaredLength = try contentLength(from: headers)
        let actualLength = data.count - bodyStart
        guard actualLength >= declaredLength else {
            throw ServerHTTPCodecError.incompleteBody(expected: declaredLength, actual: actualLength)
        }

        return ServerHTTPRequest(
            method: method,
            path: String(requestParts[1]),
            headers: headers,
            body: data[bodyStart..<(bodyStart + declaredLength)]
        )
    }

    public func parseResponse(_ data: Data) throws -> ServerHTTPResponse {
        let headerEnd = try headerEndIndex(in: data)
        let headerData = data[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else { throw ServerHTTPCodecError.invalidUTF8 }

        let lines = headerText.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count == 3, statusParts[0] == "HTTP/1.1" else { throw ServerHTTPCodecError.malformedStatusLine }
        guard let statusCode = Int(statusParts[1]) else { throw ServerHTTPCodecError.invalidStatusCode(String(statusParts[1])) }

        let headers = try Self.headers(from: lines.dropFirst())
        let bodyStart = headerEnd + 4
        let declaredLength = try contentLength(from: headers)
        let actualLength = data.count - bodyStart
        guard actualLength >= declaredLength else {
            throw ServerHTTPCodecError.incompleteBody(expected: declaredLength, actual: actualLength)
        }

        return ServerHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: data[bodyStart..<(bodyStart + declaredLength)]
        )
    }

    public func serializeResponse(_ response: ServerHTTPResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = headers["Connection"] ?? "close"

        var text = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        for name in headers.keys.sorted() {
            text += "\(name): \(headers[name]!)\r\n"
        }
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(response.body)
        return data
    }

    public func expectedRequestByteCount(_ data: Data) throws -> Int? {
        guard let headerEnd = optionalHeaderEndIndex(in: data) else {
            return nil
        }
        let bodyLength = try expectedRequestBodyByteCount(data)!
        let bodyStart = headerEnd + 4
        guard bodyLength <= Int.max - bodyStart else {
            throw ServerHTTPCodecError.invalidContentLength("\(bodyLength)")
        }
        return bodyStart + bodyLength
    }

    public func expectedRequestBodyByteCount(_ data: Data) throws -> Int? {
        guard let headerEnd = optionalHeaderEndIndex(in: data) else {
            return nil
        }
        let headerData = data[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ServerHTTPCodecError.invalidUTF8
        }

        return try contentLength(from: Self.headers(from: headerText.components(separatedBy: "\r\n").dropFirst()))
    }

    private func headerEndIndex(in data: Data) throws -> Int {
        guard let index = optionalHeaderEndIndex(in: data) else {
            throw ServerHTTPCodecError.missingHeaderTerminator
        }
        return index
    }

    private func optionalHeaderEndIndex(in data: Data) -> Int? {
        data.range(of: Data("\r\n\r\n".utf8))?.lowerBound
    }

    private func contentLength(from headers: [String: String]) throws -> Int {
        guard let value = headers.first(where: { $0.key.lowercased() == "content-length" })?.value else {
            return 0
        }
        guard let length = Int(value), length >= 0 else {
            throw ServerHTTPCodecError.invalidContentLength(value)
        }
        return length
    }

    private static func headers<T: Sequence>(from lines: T) throws -> [String: String] where T.Element == String {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ServerHTTPCodecError.malformedHeader(line)
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ServerHTTPCodecError.malformedHeader(line) }
            headers[name] = value
        }
        return headers
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 403:
            return "Forbidden"
        case 404:
            return "Not Found"
        case 405:
            return "Method Not Allowed"
        case 408:
            return "Request Timeout"
        case 413:
            return "Payload Too Large"
        case 429:
            return "Too Many Requests"
        case 500:
            return "Internal Server Error"
        default:
            return "HTTP Response"
        }
    }
}

public struct ServerHealthPayload: Codable, Equatable, Sendable {
    public var service: String
    public var status: String

    public init(service: String = "mbd", status: String = "ok") {
        self.service = service
        self.status = status
    }
}

public struct ServerErrorPayload: Codable, Equatable, Sendable {
    public var error: String
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}
