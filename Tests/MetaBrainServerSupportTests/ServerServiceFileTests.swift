import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func launchdUserServiceFileIncludesExecutableServeAndConfig() throws {
    let service = try ServerServicePrintConfiguration(
        executablePath: "/usr/local/bin/mbd",
        configPath: "/Users/alice/Library/Application Support/metaBrain/mbd.json",
        platform: .macOS
    )

    #expect(service.programArguments == [
        "/usr/local/bin/mbd",
        "serve",
        "--config",
        "/Users/alice/Library/Application Support/metaBrain/mbd.json",
    ])
    #expect(
        service.renderUserServiceFile()
            == """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>org.metabrain.mbd</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/local/bin/mbd</string>
                    <string>serve</string>
                    <string>--config</string>
                    <string>/Users/alice/Library/Application Support/metaBrain/mbd.json</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
            </dict>
            </plist>
            """
    )
}

@Test func launchdUserServiceFileOmitsConfigWhenNotSupplied() throws {
    let service = try ServerServicePrintConfiguration(
        executablePath: " /opt/metabrain/bin/mbd ",
        platform: .macOS
    )

    let output = service.renderUserServiceFile()

    #expect(service.executablePath == "/opt/metabrain/bin/mbd")
    #expect(service.programArguments == ["/opt/metabrain/bin/mbd", "serve"])
    #expect(!output.contains("<string>--config</string>"))
    #expect(!output.contains("mbd.json"))
}

@Test func launchdUserServiceFileEscapesXMLText() throws {
    let service = try ServerServicePrintConfiguration(
        executablePath: #"/opt/metabrain&<>"'/mbd"#,
        configPath: #"/Users/alice/Config&<>"'/mbd.json"#,
        platform: .macOS
    )

    let output = service.renderUserServiceFile()
    let data = try #require(output.data(using: .utf8))
    let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let plist = try #require(parsed as? [String: Any])
    let arguments = try #require(plist["ProgramArguments"] as? [String])

    #expect(arguments == [
        #"/opt/metabrain&<>"'/mbd"#,
        "serve",
        "--config",
        #"/Users/alice/Config&<>"'/mbd.json"#,
    ])
    #expect(output.contains(#"/opt/metabrain&amp;&lt;&gt;&quot;&apos;/mbd"#))
    #expect(output.contains(#"/Users/alice/Config&amp;&lt;&gt;&quot;&apos;/mbd.json"#))
}

@Test func systemdUserServiceFileIncludesExecutableServeAndConfig() throws {
    let service = try ServerServicePrintConfiguration(
        executablePath: "/usr/bin/mbd",
        configPath: "/home/alice/.config/metabrain/mbd.json",
        platform: .linux
    )

    #expect(
        service.renderUserServiceFile()
            == """
            [Unit]
            Description=metaBrain daemon

            [Service]
            ExecStart="/usr/bin/mbd" "serve" "--config" "/home/alice/.config/metabrain/mbd.json"
            Restart=on-failure

            [Install]
            WantedBy=default.target
            """
    )
}

@Test func systemdUserServiceFileEscapesUnitText() throws {
    let service = try ServerServicePrintConfiguration(
        executablePath: #"/opt/meta brain/mbd"#,
        configPath: "/tmp/a\\b\"c%\n\r\td.json",
        platform: .linux
    )

    #expect(
        service.renderUserServiceFile().contains(
            #"ExecStart="/opt/meta brain/mbd" "serve" "--config" "/tmp/a\\b\"c%%\n\r\td.json""#
        )
    )
}

@Test func serviceFilePathsMatchUserServiceManagers() {
    #expect(
        ServerServiceFilePaths.userServicePath(homeDirectory: "/Users/alice", platform: .macOS)
            == "/Users/alice/Library/LaunchAgents/org.metabrain.mbd.plist"
    )
    #expect(
        ServerServiceFilePaths.userServicePath(homeDirectory: "/home/alice/", platform: .linux)
            == "/home/alice/.config/systemd/user/mbd.service"
    )
}

@Test func userServiceConfigurationComputesPathsAndContents() throws {
    let configuration = try ServerUserServiceFileConfiguration(
        homeDirectory: " /home/alice/ ",
        executablePath: "/usr/bin/mbd",
        platform: .linux
    )

    #expect(configuration.homeDirectory == "/home/alice/")
    #expect(configuration.platform == .linux)
    #expect(configuration.servicePath == "/home/alice/.config/systemd/user/mbd.service")
    #expect(configuration.serviceDirectoryPath == "/home/alice/.config/systemd/user")
    #expect(configuration.contents == configuration.service.renderUserServiceFile())
}

@Test func userServiceInstallWritesRenderedContentAndCreatesParentDirectory() throws {
    let root = temporaryDirectory(named: "metabrain-service-install")
    defer { try? FileManager.default.removeItem(at: root) }

    let configuration = try ServerUserServiceFileConfiguration(
        homeDirectory: root.path,
        executablePath: "/usr/local/bin/mbd",
        configPath: "/tmp/mbd.json",
        platform: .macOS
    )

    #expect(!FileManager.default.fileExists(atPath: configuration.serviceDirectoryPath))

    let installedPath = try ServerUserServiceFileManager.install(configuration)
    var isDirectory = ObjCBool(false)
    let directoryExists = FileManager.default.fileExists(
        atPath: configuration.serviceDirectoryPath,
        isDirectory: &isDirectory
    )
    let installedContents = try String(
        contentsOf: URL(fileURLWithPath: installedPath),
        encoding: .utf8
    )

    #expect(installedPath == configuration.servicePath)
    #expect(directoryExists)
    #expect(isDirectory.boolValue)
    #expect(installedContents == configuration.contents)
}

@Test func userServiceUninstallRemovesExistingFile() throws {
    let root = temporaryDirectory(named: "metabrain-service-uninstall")
    defer { try? FileManager.default.removeItem(at: root) }

    let configuration = try ServerUserServiceFileConfiguration(
        homeDirectory: root.path,
        executablePath: "/usr/bin/mbd",
        platform: .linux
    )
    let installedPath = try ServerUserServiceFileManager.install(configuration)

    let result = try ServerUserServiceFileManager.uninstall(
        homeDirectory: root.path,
        platform: .linux
    )

    #expect(result == .removed(path: installedPath))
    #expect(result.path == installedPath)
    #expect(result.message == installedPath)
    #expect(!FileManager.default.fileExists(atPath: installedPath))
}

@Test func userServiceUninstallMissingIsStableNoOp() throws {
    let root = temporaryDirectory(named: "metabrain-service-missing")
    defer { try? FileManager.default.removeItem(at: root) }

    let expectedPath = ServerServiceFilePaths.userServicePath(
        homeDirectory: root.path,
        platform: .macOS
    )
    let result = try ServerUserServiceFileManager.uninstall(
        homeDirectory: root.path,
        platform: .macOS
    )

    #expect(result == .missing(path: expectedPath))
    #expect(result.path == expectedPath)
    #expect(result.message == "user service file not installed: \(expectedPath)")
}

@Test func servicePrintConfigurationRejectsEmptyPaths() {
    #expect(throws: ServerServiceFileError.emptyExecutablePath) {
        _ = try ServerServicePrintConfiguration(executablePath: " \n", platform: .linux)
    }
    #expect(throws: ServerServiceFileError.emptyConfigPath) {
        _ = try ServerServicePrintConfiguration(
            executablePath: "/usr/bin/mbd",
            configPath: "\t",
            platform: .macOS
        )
    }
    #expect(throws: ServerServiceFileError.emptyHomeDirectory) {
        _ = try ServerUserServiceFileConfiguration(
            homeDirectory: "\n ",
            executablePath: "/usr/bin/mbd",
            platform: .linux
        )
    }
    #expect(throws: ServerServiceFileError.emptyHomeDirectory) {
        _ = try ServerUserServiceFileManager.uninstall(
            homeDirectory: "\t",
            platform: .macOS
        )
    }
}

@Test func serviceFileErrorsHaveStableDescriptions() {
    #expect(
        ServerServiceFileError.emptyExecutablePath.description
            == "service executable path cannot be empty"
    )
    #expect(
        ServerServiceFileError.emptyConfigPath.description
            == "service config path cannot be empty"
    )
    #expect(
        ServerServiceFileError.emptyHomeDirectory.description
            == "service home directory cannot be empty"
    )
}

private func temporaryDirectory(named prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}
