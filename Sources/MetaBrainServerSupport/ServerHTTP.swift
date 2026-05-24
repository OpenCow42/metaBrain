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
