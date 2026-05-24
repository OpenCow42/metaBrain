import Foundation

public struct ServerFileConfiguration: Codable, Equatable, Sendable {
    public var storePath: String?
    public var socketPath: String?
    public var loopbackHost: String?
    public var loopbackPort: Int?
    public var requestTimeoutSeconds: Double?
    public var maximumConcurrentRequests: Int?
    public var maximumQueuedRequests: Int?
    public var maxHeaderBytes: Int?
    public var maxRequestBodyBytes: Int?
    public var authorizationTokenPath: String?
    public var logLevel: String?

    public init(
        storePath: String? = nil,
        socketPath: String? = nil,
        loopbackHost: String? = nil,
        loopbackPort: Int? = nil,
        requestTimeoutSeconds: Double? = nil,
        maximumConcurrentRequests: Int? = nil,
        maximumQueuedRequests: Int? = nil,
        maxHeaderBytes: Int? = nil,
        maxRequestBodyBytes: Int? = nil,
        authorizationTokenPath: String? = nil,
        logLevel: String? = nil
    ) {
        self.storePath = storePath
        self.socketPath = socketPath
        self.loopbackHost = loopbackHost
        self.loopbackPort = loopbackPort
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumQueuedRequests = maximumQueuedRequests
        self.maxHeaderBytes = maxHeaderBytes
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.authorizationTokenPath = authorizationTokenPath
        self.logLevel = logLevel
    }
}

public enum ServerConfigurationPlatform: Equatable, Sendable {
    case macOS
    case linux

    public static var current: Self {
        #if os(macOS)
        .macOS
        #else
        .linux
        #endif
    }
}

public enum ServerConfigurationPaths {
    public static let systemConfigPath = "/etc/metabrain/mbd.json"

    public static func userConfigPath(
        homeDirectory: String,
        platform: ServerConfigurationPlatform = .current
    ) -> String {
        let home = homeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch platform {
        case .macOS:
            return "/\(home)/Library/Application Support/metaBrain/mbd.json"
        case .linux:
            return "/\(home)/.config/metabrain/mbd.json"
        }
    }

    public static func defaultConfigCandidates(
        homeDirectory: String?,
        platform: ServerConfigurationPlatform = .current
    ) -> [String] {
        var candidates: [String] = []
        if let homeDirectory, !homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(userConfigPath(homeDirectory: homeDirectory, platform: platform))
        }
        candidates.append(systemConfigPath)
        return candidates
    }

    public static func currentDefaultConfigCandidates() -> [String] {
        defaultConfigCandidates(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

public enum ServerConfigurationLoadError: Error, Equatable, CustomStringConvertible, Sendable {
    case explicitConfigMissing(String)
    case unreadableConfig(String)
    case invalidConfigJSON(String)

    public var description: String {
        switch self {
        case .explicitConfigMissing(let path):
            return "config file does not exist: \(path)"
        case .unreadableConfig(let path):
            return "config file could not be read: \(path)"
        case .invalidConfigJSON(let path):
            return "config file is not valid JSON: \(path)"
        }
    }
}

public enum ServerConfigurationLoader {
    public static func loadExplicitConfig(at path: String) throws -> ServerFileConfiguration {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ServerConfigurationLoadError.explicitConfigMissing(path)
        }
        return try loadConfig(at: path)
    }

    public static func loadDefaultConfig(
        candidates: [String] = ServerConfigurationPaths.currentDefaultConfigCandidates()
    ) throws -> ServerFileConfiguration? {
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return try loadConfig(at: candidate)
        }
        return nil
    }

    private static func loadConfig(at path: String) throws -> ServerFileConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ServerConfigurationLoadError.unreadableConfig(path)
        }

        do {
            return try MetaBrainJSON.decoder().decode(ServerFileConfiguration.self, from: data)
        } catch {
            throw ServerConfigurationLoadError.invalidConfigJSON(path)
        }
    }
}
