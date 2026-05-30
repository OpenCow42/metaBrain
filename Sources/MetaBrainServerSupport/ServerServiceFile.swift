import Foundation

public enum ServerServiceFileError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyExecutablePath
    case emptyConfigPath
    case emptyHomeDirectory

    public var description: String {
        switch self {
        case .emptyExecutablePath:
            return "service executable path cannot be empty"
        case .emptyConfigPath:
            return "service config path cannot be empty"
        case .emptyHomeDirectory:
            return "service home directory cannot be empty"
        }
    }
}

public enum ServerServiceFilePaths {
    public static let launchdUserLabel = "org.metabrain.mbd"
    public static let systemdUserUnitName = "mbd.service"

    public static func userServicePath(
        homeDirectory: String,
        platform: ServerConfigurationPlatform = .current
    ) -> String {
        let home = homeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch platform {
        case .macOS:
            return "/\(home)/Library/LaunchAgents/\(launchdUserLabel).plist"
        case .linux:
            return "/\(home)/.config/systemd/user/\(systemdUserUnitName)"
        }
    }
}

public struct ServerServicePrintConfiguration: Equatable, Sendable {
    public var executablePath: String
    public var configPath: String?
    public var platform: ServerConfigurationPlatform

    public init(
        executablePath: String,
        configPath: String? = nil,
        platform: ServerConfigurationPlatform = .current
    ) throws {
        self.executablePath = try Self.validatedPath(executablePath, emptyError: .emptyExecutablePath)
        if let configPath {
            self.configPath = try Self.validatedPath(configPath, emptyError: .emptyConfigPath)
        } else {
            self.configPath = nil
        }
        self.platform = platform
    }

    public var programArguments: [String] {
        var arguments = [executablePath, "serve"]
        if let configPath {
            arguments.append(contentsOf: ["--config", configPath])
        }
        return arguments
    }

    public func renderUserServiceFile() -> String {
        switch platform {
        case .macOS:
            return renderLaunchdPlist()
        case .linux:
            return renderSystemdUserUnit()
        }
    }

    private static func validatedPath(_ path: String, emptyError: ServerServiceFileError) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw emptyError
        }
        return trimmed
    }

    private func renderLaunchdPlist() -> String {
        let argumentLines = programArguments
            .map { "        <string>\(Self.xmlEscaped($0))</string>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(ServerServiceFilePaths.launchdUserLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(argumentLines)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func renderSystemdUserUnit() -> String {
        let command = programArguments
            .map(Self.systemdQuotedArgument(_:))
            .joined(separator: " ")

        return """
        [Unit]
        Description=metaBrain daemon

        [Service]
        ExecStart=\(command)
        Restart=on-failure

        [Install]
        WantedBy=default.target
        """
    }

    private static func xmlEscaped(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&":
                escaped += "&amp;"
            case "<":
                escaped += "&lt;"
            case ">":
                escaped += "&gt;"
            case "\"":
                escaped += "&quot;"
            case "'":
                escaped += "&apos;"
            default:
                escaped += String(scalar)
            }
        }
        return escaped
    }

    private static func systemdQuotedArgument(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "%":
                escaped += "%%"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped += String(scalar)
            }
        }
        escaped += "\""
        return escaped
    }
}

public struct ServerUserServiceFileConfiguration: Equatable, Sendable {
    public var homeDirectory: String
    public var service: ServerServicePrintConfiguration

    public init(
        homeDirectory: String,
        executablePath: String,
        configPath: String? = nil,
        platform: ServerConfigurationPlatform = .current
    ) throws {
        let trimmedHome = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else {
            throw ServerServiceFileError.emptyHomeDirectory
        }

        self.homeDirectory = trimmedHome
        self.service = try ServerServicePrintConfiguration(
            executablePath: executablePath,
            configPath: configPath,
            platform: platform
        )
    }

    public var platform: ServerConfigurationPlatform {
        service.platform
    }

    public var servicePath: String {
        ServerServiceFilePaths.userServicePath(homeDirectory: homeDirectory, platform: platform)
    }

    public var serviceDirectoryPath: String {
        URL(fileURLWithPath: servicePath).deletingLastPathComponent().path
    }

    public var contents: String {
        service.renderUserServiceFile()
    }
}

public enum ServerUserServiceUninstallResult: Equatable, Sendable {
    case removed(path: String)
    case missing(path: String)

    public var path: String {
        switch self {
        case .removed(let path), .missing(let path):
            return path
        }
    }

    public var message: String {
        switch self {
        case .removed(let path):
            return path
        case .missing(let path):
            return "user service file not installed: \(path)"
        }
    }
}

public enum ServerUserServiceFileManager {
    public static func install(
        _ configuration: ServerUserServiceFileConfiguration,
        fileManager: FileManager = .default
    ) throws -> String {
        let serviceURL = URL(fileURLWithPath: configuration.servicePath)
        try fileManager.createDirectory(
            at: serviceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try configuration.contents.write(to: serviceURL, atomically: true, encoding: .utf8)
        return configuration.servicePath
    }

    public static func uninstall(
        homeDirectory: String,
        platform: ServerConfigurationPlatform = .current,
        fileManager: FileManager = .default
    ) throws -> ServerUserServiceUninstallResult {
        let trimmedHome = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else {
            throw ServerServiceFileError.emptyHomeDirectory
        }

        let path = ServerServiceFilePaths.userServicePath(
            homeDirectory: trimmedHome,
            platform: platform
        )
        guard fileManager.fileExists(atPath: path) else {
            return .missing(path: path)
        }

        try fileManager.removeItem(atPath: path)
        return .removed(path: path)
    }
}
