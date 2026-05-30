import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func serverFileConfigurationDecodesAllStoredSettings() throws {
    let data = Data(
        """
        {
          "storePath": ".metabrain/store.leveldb",
          "socketPath": "/tmp/mbd.sock",
          "loopbackHost": "127.0.0.1",
          "loopbackPort": 6374,
          "requestTimeoutSeconds": 2.5,
          "maximumConcurrentRequests": 4,
          "maximumQueuedRequests": 16,
          "maxHeaderBytes": 32768,
          "maxRequestBodyBytes": 1048576,
          "logLevel": "debug"
        }
        """.utf8
    )

    let configuration = try MetaBrainJSON.decoder().decode(ServerFileConfiguration.self, from: data)

    #expect(configuration.storePath == ".metabrain/store.leveldb")
    #expect(configuration.socketPath == "/tmp/mbd.sock")
    #expect(configuration.loopbackHost == "127.0.0.1")
    #expect(configuration.loopbackPort == 6374)
    #expect(configuration.requestTimeoutSeconds == 2.5)
    #expect(configuration.maximumConcurrentRequests == 4)
    #expect(configuration.maximumQueuedRequests == 16)
    #expect(configuration.maxHeaderBytes == 32_768)
    #expect(configuration.maxRequestBodyBytes == 1_048_576)
    #expect(configuration.logLevel == "debug")
}

@Test func serverConfigurationPathDiscoveryMatchesDocumentedLocations() {
    #expect(
        ServerConfigurationPaths.userConfigPath(homeDirectory: "/Users/alice", platform: .macOS)
            == "/Users/alice/Library/Application Support/metaBrain/mbd.json"
    )
    #expect(
        ServerConfigurationPaths.userConfigPath(homeDirectory: "/home/alice/", platform: .linux)
            == "/home/alice/.config/metabrain/mbd.json"
    )
    #expect(
        ServerConfigurationPaths.defaultConfigCandidates(homeDirectory: "/Users/alice", platform: .macOS)
            == [
                "/Users/alice/Library/Application Support/metaBrain/mbd.json",
                "/etc/metabrain/mbd.json",
            ]
    )
    #expect(ServerConfigurationPaths.defaultConfigCandidates(homeDirectory: nil, platform: .linux) == [
        "/etc/metabrain/mbd.json",
    ])
    #expect(ServerConfigurationPaths.defaultConfigCandidates(homeDirectory: " \n", platform: .linux) == [
        "/etc/metabrain/mbd.json",
    ])
    #expect(ServerConfigurationPaths.currentDefaultConfigCandidates().contains("/etc/metabrain/mbd.json"))

    #if os(macOS)
    #expect(ServerConfigurationPlatform.current == .macOS)
    #else
    #expect(ServerConfigurationPlatform.current == .linux)
    #endif
}

@Test func serverConfigurationLoaderIgnoresMissingOptionalDefaultConfig() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbd-missing-default-\(UUID().uuidString)")
    let missing = root.appendingPathComponent("mbd.json").path

    let configuration = try ServerConfigurationLoader.loadDefaultConfig(candidates: [missing])

    #expect(configuration == nil)
}

@Test func serverConfigurationLoaderReportsExplicitMissingConfig() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbd-explicit-missing-\(UUID().uuidString).json")
        .path

    #expect(throws: ServerConfigurationLoadError.explicitConfigMissing(missing)) {
        _ = try ServerConfigurationLoader.loadExplicitConfig(at: missing)
    }
}

@Test func serverConfigurationLoaderReportsInvalidConfigJSON() throws {
    let file = try temporaryServerConfigFile(contents: "{")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    #expect(throws: ServerConfigurationLoadError.invalidConfigJSON(file.path)) {
        _ = try ServerConfigurationLoader.loadExplicitConfig(at: file.path)
    }
}

@Test func serverConfigurationLoaderLoadsFirstExistingDefaultConfig() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbd-default-missing-\(UUID().uuidString).json")
        .path
    let file = try temporaryServerConfigFile(contents: #"{"socketPath":"/tmp/from-default.sock"}"#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let configuration = try ServerConfigurationLoader.loadDefaultConfig(candidates: [missing, file.path])

    #expect(configuration?.socketPath == "/tmp/from-default.sock")
}

@Test func serverConfigurationLoaderReportsUnreadableConfig() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbd-unreadable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: ServerConfigurationLoadError.unreadableConfig(directory.path)) {
        _ = try ServerConfigurationLoader.loadDefaultConfig(candidates: [directory.path])
    }
}

@Test func serverConfigurationLoadErrorsHaveStableDescriptions() {
    #expect(
        ServerConfigurationLoadError.explicitConfigMissing("/tmp/missing.json").description
            == "config file does not exist: /tmp/missing.json"
    )
    #expect(
        ServerConfigurationLoadError.unreadableConfig("/tmp/config-dir").description
            == "config file could not be read: /tmp/config-dir"
    )
    #expect(
        ServerConfigurationLoadError.invalidConfigJSON("/tmp/bad.json").description
            == "config file is not valid JSON: /tmp/bad.json"
    )
}

private func temporaryServerConfigFile(contents: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbd-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("mbd.json")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file
}
