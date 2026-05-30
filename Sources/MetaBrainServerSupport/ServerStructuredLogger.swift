import Foundation

public enum ServerLogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case debug
    case info
    case warn
    case error

    public init(validating value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let level = Self(rawValue: normalized) else {
            throw ServerServeConfigurationError.invalidLogLevel(value)
        }
        self = level
    }

    public static func < (lhs: ServerLogLevel, rhs: ServerLogLevel) -> Bool {
        lhs.priority < rhs.priority
    }

    private var priority: Int {
        switch self {
        case .debug:
            return 0
        case .info:
            return 1
        case .warn:
            return 2
        case .error:
            return 3
        }
    }
}

public struct ServerLogRecord: Codable, Equatable, Sendable {
    public var level: ServerLogLevel
    public var event: String
    public var method: String?
    public var path: String?
    public var statusCode: Int?
    public var error: String?
    public var message: String?

    public init(
        level: ServerLogLevel,
        event: String,
        method: String? = nil,
        path: String? = nil,
        statusCode: Int? = nil,
        error: String? = nil,
        message: String? = nil
    ) {
        self.level = level
        self.event = event
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.error = error
        self.message = message
    }
}

public struct ServerStructuredLogger: Sendable {
    public typealias Sink = @Sendable (String) -> Void

    public static var disabled: ServerStructuredLogger {
        ServerStructuredLogger(minimumLevel: nil, sink: nil)
    }

    private let minimumLevel: ServerLogLevel?
    private let sink: Sink?

    public init(minimumLevel: ServerLogLevel, sink: @escaping Sink) {
        self.minimumLevel = minimumLevel
        self.sink = sink
    }

    private init(minimumLevel: ServerLogLevel?, sink: Sink?) {
        self.minimumLevel = minimumLevel
        self.sink = sink
    }

    public func log(_ record: ServerLogRecord) {
        guard let minimumLevel, let sink, record.level >= minimumLevel else {
            return
        }

        let data = try! MetaBrainJSON.encoder().encode(record)
        sink(String(decoding: data, as: UTF8.self))
    }

    public func requestStarted(_ request: ServerHTTPRequest) {
        log(
            ServerLogRecord(
                level: .info,
                event: "request_started",
                method: request.method.rawValue,
                path: request.path
            )
        )
    }

    public func requestCompleted(_ request: ServerHTTPRequest, response: ServerHTTPResponse) {
        log(
            ServerLogRecord(
                level: .info,
                event: "request_completed",
                method: request.method.rawValue,
                path: request.path,
                statusCode: response.statusCode
            )
        )
    }

    public func requestFailed(
        _ request: ServerHTTPRequest?,
        response: ServerHTTPResponse,
        error: Error
    ) {
        log(
            ServerLogRecord(
                level: .warn,
                event: "request_error",
                method: request?.method.rawValue,
                path: request?.path,
                statusCode: response.statusCode,
                error: String(describing: error),
                message: response.bodyText
            )
        )
    }
}
