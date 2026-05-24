import Foundation

public enum ServerListenMode: Equatable, Sendable {
    case unixSocket(path: String)
    case loopback(host: String, port: Int)
}

public struct ServerServeConfiguration: Equatable, Sendable {
    public static let defaultStorePath = ".metabrain/store.leveldb"
    public static let defaultSocketPath = "~/.metabrain/mbd.sock"
    public static let defaultLoopbackHost = "127.0.0.1"
    public static let defaultLoopbackPort = 7421
    public static let defaultRequestTimeoutSeconds = 30.0
    public static let defaultMaximumConcurrentRequests = 16
    public static let defaultMaximumQueuedRequests = 1024
    public static let defaultMaxHeaderBytes = 64 * 1024
    public static let defaultMaxRequestBodyBytes = 16 * 1024 * 1024

    public var storePath: String
    public var listenMode: ServerListenMode
    public var requestTimeoutSeconds: Double
    public var maximumConcurrentRequests: Int
    public var maximumQueuedRequests: Int
    public var maxHeaderBytes: Int
    public var maxRequestBodyBytes: Int
    public var authorizationTokenPath: String?
    public var logLevel: String

    public init(
        storePath: String? = nil,
        socketPath: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        requestTimeoutSeconds: Double? = nil,
        maximumConcurrentRequests: Int? = nil,
        maximumQueuedRequests: Int? = nil,
        maxHeaderBytes: Int? = nil,
        maxRequestBodyBytes: Int? = nil,
        authorizationTokenPath: String? = nil,
        logLevel: String? = nil,
        fileConfiguration: ServerFileConfiguration? = nil
    ) throws {
        let explicitLoopback = host != nil || port != nil
        let explicitSocket = socketPath != nil
        let configLoopback = fileConfiguration?.loopbackHost != nil || fileConfiguration?.loopbackPort != nil

        self.storePath = try Self.validatedStorePath(
            storePath ?? fileConfiguration?.storePath ?? Self.defaultStorePath
        )

        if explicitLoopback || (!explicitSocket && configLoopback) {
            self.listenMode = .loopback(
                host: try Self.validatedHost(host ?? fileConfiguration?.loopbackHost ?? Self.defaultLoopbackHost),
                port: try Self.validatedPort(port ?? fileConfiguration?.loopbackPort ?? Self.defaultLoopbackPort)
            )
        } else {
            self.listenMode = .unixSocket(
                path: try Self.validatedSocketPath(socketPath ?? fileConfiguration?.socketPath ?? Self.defaultSocketPath)
            )
        }

        self.requestTimeoutSeconds = try Self.validatedRequestTimeout(
            requestTimeoutSeconds ?? fileConfiguration?.requestTimeoutSeconds ?? Self.defaultRequestTimeoutSeconds
        )
        self.maximumConcurrentRequests = try Self.validatedMaximumConcurrentRequests(
            maximumConcurrentRequests ?? fileConfiguration?.maximumConcurrentRequests ?? Self.defaultMaximumConcurrentRequests
        )
        self.maximumQueuedRequests = try Self.validatedMaximumQueuedRequests(
            maximumQueuedRequests ?? fileConfiguration?.maximumQueuedRequests ?? Self.defaultMaximumQueuedRequests
        )
        self.maxHeaderBytes = try Self.validatedMaxHeaderBytes(
            maxHeaderBytes ?? fileConfiguration?.maxHeaderBytes ?? Self.defaultMaxHeaderBytes
        )
        self.maxRequestBodyBytes = try Self.validatedMaxRequestBodyBytes(
            maxRequestBodyBytes ?? fileConfiguration?.maxRequestBodyBytes ?? Self.defaultMaxRequestBodyBytes
        )
        self.authorizationTokenPath = try Self.validatedOptionalPath(
            authorizationTokenPath ?? fileConfiguration?.authorizationTokenPath,
            emptyError: .emptyAuthorizationTokenPath
        )
        self.logLevel = try Self.validatedLogLevel(
            logLevel ?? fileConfiguration?.logLevel ?? ServerLogLevel.info.rawValue
        )
    }

    public var description: String {
        switch listenMode {
        case .unixSocket(let path):
            return "unix socket \(path)"
        case .loopback(let host, let port):
            return "loopback http \(host):\(port)"
        }
    }

    private static func validatedStorePath(_ storePath: String) throws -> String {
        let trimmed = storePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerServeConfigurationError.emptyStorePath
        }
        return trimmed
    }

    private static func validatedSocketPath(_ socketPath: String) throws -> String {
        let trimmed = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerServeConfigurationError.emptySocketPath
        }
        return trimmed
    }

    private static func validatedHost(_ host: String) throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerServeConfigurationError.emptyHost
        }
        return trimmed
    }

    private static func validatedPort(_ port: Int) throws -> Int {
        guard (0...65_535).contains(port) else {
            throw ServerServeConfigurationError.invalidPort(port)
        }
        return port
    }

    private static func validatedRequestTimeout(_ timeout: Double) throws -> Double {
        guard timeout > 0, timeout.isFinite else {
            throw ServerServeConfigurationError.invalidRequestTimeout(timeout)
        }
        return timeout
    }

    private static func validatedMaximumConcurrentRequests(_ maximum: Int) throws -> Int {
        guard maximum > 0 else {
            throw ServerServeConfigurationError.invalidMaximumConcurrentRequests(maximum)
        }
        return maximum
    }

    private static func validatedMaximumQueuedRequests(_ maximum: Int) throws -> Int {
        guard maximum >= 0 else {
            throw ServerServeConfigurationError.invalidMaximumQueuedRequests(maximum)
        }
        return maximum
    }

    private static func validatedMaxHeaderBytes(_ maximum: Int) throws -> Int {
        guard maximum > 0 else {
            throw ServerServeConfigurationError.invalidMaxHeaderBytes(maximum)
        }
        return maximum
    }

    private static func validatedMaxRequestBodyBytes(_ maximum: Int) throws -> Int {
        guard maximum > 0 else {
            throw ServerServeConfigurationError.invalidMaxRequestBodyBytes(maximum)
        }
        return maximum
    }

    private static func validatedOptionalPath(
        _ path: String?,
        emptyError: ServerServeConfigurationError
    ) throws -> String? {
        guard let path else {
            return nil
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw emptyError
        }
        return trimmed
    }

    private static func validatedLogLevel(_ logLevel: String) throws -> String {
        try ServerLogLevel(validating: logLevel).rawValue
    }
}

public enum ServerServeConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyStorePath
    case emptySocketPath
    case emptyHost
    case invalidPort(Int)
    case invalidRequestTimeout(Double)
    case invalidMaximumConcurrentRequests(Int)
    case invalidMaximumQueuedRequests(Int)
    case invalidMaxHeaderBytes(Int)
    case invalidMaxRequestBodyBytes(Int)
    case emptyAuthorizationTokenPath
    case invalidLogLevel(String)

    public var description: String {
        switch self {
        case .emptyStorePath:
            return "store path cannot be empty"
        case .emptySocketPath:
            return "socket path cannot be empty"
        case .emptyHost:
            return "host cannot be empty"
        case .invalidPort(let port):
            return "port must be between 0 and 65535, got \(port)"
        case .invalidRequestTimeout(let timeout):
            return "requestTimeoutSeconds must be greater than 0, got \(timeout)"
        case .invalidMaximumConcurrentRequests(let maximum):
            return "maximumConcurrentRequests must be greater than 0, got \(maximum)"
        case .invalidMaximumQueuedRequests(let maximum):
            return "maximumQueuedRequests must be zero or greater, got \(maximum)"
        case .invalidMaxHeaderBytes(let maximum):
            return "maxHeaderBytes must be greater than 0, got \(maximum)"
        case .invalidMaxRequestBodyBytes(let maximum):
            return "maxRequestBodyBytes must be greater than 0, got \(maximum)"
        case .emptyAuthorizationTokenPath:
            return "authorizationTokenPath cannot be empty"
        case .invalidLogLevel(let logLevel):
            return "logLevel must be one of debug, info, warn, error, got \(logLevel)"
        }
    }
}
