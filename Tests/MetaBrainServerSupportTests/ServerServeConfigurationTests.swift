import Testing
@testable import MetaBrainServerSupport

@Test func serveConfigurationDefaultsToUnixSocketAndStorePath() throws {
    let configuration = try ServerServeConfiguration()

    #expect(configuration.storePath == ".metabrain/store.leveldb")
    #expect(configuration.listenMode == .unixSocket(path: "~/.metabrain/mbd.sock"))
    #expect(configuration.description == "unix socket ~/.metabrain/mbd.sock")
    #expect(configuration.requestTimeoutSeconds == ServerServeConfiguration.defaultRequestTimeoutSeconds)
    #expect(configuration.maximumConcurrentRequests == ServerServeConfiguration.defaultMaximumConcurrentRequests)
    #expect(configuration.maximumQueuedRequests == ServerServeConfiguration.defaultMaximumQueuedRequests)
    #expect(configuration.maxHeaderBytes == ServerServeConfiguration.defaultMaxHeaderBytes)
    #expect(configuration.maxRequestBodyBytes == ServerServeConfiguration.defaultMaxRequestBodyBytes)
    #expect(configuration.authorizationTokenPath == nil)
    #expect(configuration.logLevel == "info")
}

@Test func serveConfigurationTrimsStoreAndSocketPaths() throws {
    let configuration = try ServerServeConfiguration(
        storePath: "  .metabrain/store.leveldb\n",
        socketPath: "  /tmp/mbd.sock\n"
    )

    #expect(configuration.storePath == ".metabrain/store.leveldb")
    #expect(configuration.listenMode == .unixSocket(path: "/tmp/mbd.sock"))
}

@Test func serveConfigurationRejectsEmptyStoreAndSocketPaths() {
    #expect(throws: ServerServeConfigurationError.emptyStorePath) {
        _ = try ServerServeConfiguration(storePath: "  ")
    }
    #expect(throws: ServerServeConfigurationError.emptySocketPath) {
        _ = try ServerServeConfiguration(socketPath: "  ")
    }
}

@Test func serveConfigurationUsesLoopbackWhenHostOrPortIsProvided() throws {
    let defaultPort = try ServerServeConfiguration(host: " 127.0.0.1 ")
    let explicitPort = try ServerServeConfiguration(host: "::1", port: 9000)
    let defaultHost = try ServerServeConfiguration(port: 9001)
    let ephemeralPort = try ServerServeConfiguration(port: 0)

    #expect(defaultPort.listenMode == .loopback(host: "127.0.0.1", port: 6374))
    #expect(defaultPort.description == "loopback http 127.0.0.1:6374")
    #expect(explicitPort.listenMode == .loopback(host: "::1", port: 9000))
    #expect(defaultHost.listenMode == .loopback(host: "127.0.0.1", port: 9001))
    #expect(ephemeralPort.listenMode == .loopback(host: "127.0.0.1", port: 0))
}

@Test func serveConfigurationMergesConfigFileSettings() throws {
    let fileConfiguration = ServerFileConfiguration(
        storePath: "/tmp/store.leveldb",
        socketPath: "/tmp/config.sock",
        loopbackHost: "localhost",
        loopbackPort: 8123,
        requestTimeoutSeconds: 3.5,
        maximumConcurrentRequests: 2,
        maximumQueuedRequests: 32,
        maxHeaderBytes: 32_768,
        maxRequestBodyBytes: 1_048_576,
        authorizationTokenPath: "/tokens/mbd",
        logLevel: "debug"
    )

    let configuration = try ServerServeConfiguration(fileConfiguration: fileConfiguration)

    #expect(configuration.storePath == "/tmp/store.leveldb")
    #expect(configuration.listenMode == .loopback(host: "localhost", port: 8123))
    #expect(configuration.requestTimeoutSeconds == 3.5)
    #expect(configuration.maximumConcurrentRequests == 2)
    #expect(configuration.maximumQueuedRequests == 32)
    #expect(configuration.maxHeaderBytes == 32_768)
    #expect(configuration.maxRequestBodyBytes == 1_048_576)
    #expect(configuration.authorizationTokenPath == "/tokens/mbd")
    #expect(configuration.logLevel == "debug")
}

@Test func serveConfigurationNormalizesHardeningSettings() throws {
    let configuration = try ServerServeConfiguration(
        fileConfiguration: ServerFileConfiguration(
            requestTimeoutSeconds: 0.25,
            maximumConcurrentRequests: 1,
            maximumQueuedRequests: 0,
            authorizationTokenPath: " /tokens/mbd ",
            logLevel: " WARN "
        )
    )

    #expect(configuration.requestTimeoutSeconds == 0.25)
    #expect(configuration.maximumConcurrentRequests == 1)
    #expect(configuration.maximumQueuedRequests == 0)
    #expect(configuration.authorizationTokenPath == "/tokens/mbd")
    #expect(configuration.logLevel == "warn")
}

@Test func serveConfigurationLetsFlagsOverrideConfigValues() throws {
    let loopbackConfig = ServerFileConfiguration(
        storePath: "/tmp/config-store.leveldb",
        socketPath: "/tmp/config.sock",
        loopbackHost: "localhost",
        loopbackPort: 8123,
        requestTimeoutSeconds: 10,
        maximumConcurrentRequests: 4,
        maximumQueuedRequests: 8,
        maxHeaderBytes: 100,
        maxRequestBodyBytes: 200,
        authorizationTokenPath: "/tokens/config",
        logLevel: "info"
    )
    let socketOverride = try ServerServeConfiguration(
        storePath: " /tmp/flag-store.leveldb ",
        socketPath: " /tmp/flag.sock ",
        requestTimeoutSeconds: 2,
        maximumConcurrentRequests: 1,
        maximumQueuedRequests: 0,
        maxHeaderBytes: 64,
        maxRequestBodyBytes: 128,
        authorizationTokenPath: " /tokens/flag ",
        logLevel: "error",
        fileConfiguration: loopbackConfig
    )
    let loopbackOverride = try ServerServeConfiguration(
        socketPath: "/tmp/flag.sock",
        host: "127.0.0.1",
        port: 0,
        fileConfiguration: loopbackConfig
    )
    let configSocket = try ServerServeConfiguration(
        fileConfiguration: ServerFileConfiguration(socketPath: " /tmp/config-only.sock ")
    )

    #expect(socketOverride.storePath == "/tmp/flag-store.leveldb")
    #expect(socketOverride.listenMode == .unixSocket(path: "/tmp/flag.sock"))
    #expect(socketOverride.requestTimeoutSeconds == 2)
    #expect(socketOverride.maximumConcurrentRequests == 1)
    #expect(socketOverride.maximumQueuedRequests == 0)
    #expect(socketOverride.maxHeaderBytes == 64)
    #expect(socketOverride.maxRequestBodyBytes == 128)
    #expect(socketOverride.authorizationTokenPath == "/tokens/flag")
    #expect(socketOverride.logLevel == "error")
    #expect(loopbackOverride.listenMode == .loopback(host: "127.0.0.1", port: 0))
    #expect(configSocket.listenMode == .unixSocket(path: "/tmp/config-only.sock"))
}

@Test func serveConfigurationRejectsInvalidLoopbackValues() {
    #expect(throws: ServerServeConfigurationError.emptyHost) {
        _ = try ServerServeConfiguration(host: " \n")
    }

    #expect(throws: ServerServeConfigurationError.invalidPort(65_536)) {
        _ = try ServerServeConfiguration(host: "127.0.0.1", port: 65_536)
    }
}

@Test func serveConfigurationRejectsInvalidHardeningValues() {
    #expect(throws: ServerServeConfigurationError.invalidRequestTimeout(0)) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(requestTimeoutSeconds: 0))
    }
    #expect(throws: ServerServeConfigurationError.invalidRequestTimeout(-1)) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(requestTimeoutSeconds: -1))
    }
    #expect(throws: ServerServeConfigurationError.invalidRequestTimeout(.infinity)) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(requestTimeoutSeconds: .infinity))
    }
    #expect(throws: ServerServeConfigurationError.invalidMaximumConcurrentRequests(0)) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(maximumConcurrentRequests: 0))
    }
    #expect(throws: ServerServeConfigurationError.invalidMaximumQueuedRequests(-1)) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(maximumQueuedRequests: -1))
    }
    #expect(throws: ServerServeConfigurationError.invalidMaxHeaderBytes(0)) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(maxHeaderBytes: 0))
    }
    #expect(throws: ServerServeConfigurationError.invalidMaxRequestBodyBytes(-1)) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(maxRequestBodyBytes: -1))
    }
    #expect(throws: ServerServeConfigurationError.emptyAuthorizationTokenPath) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(authorizationTokenPath: " "))
    }
    #expect(throws: ServerServeConfigurationError.invalidLogLevel("verbose")) {
        _ = try ServerServeConfiguration(fileConfiguration: ServerFileConfiguration(logLevel: "verbose"))
    }
}

@Test func serveConfigurationErrorsHaveStableDescriptions() {
    #expect(ServerServeConfigurationError.emptyStorePath.description == "store path cannot be empty")
    #expect(ServerServeConfigurationError.emptySocketPath.description == "socket path cannot be empty")
    #expect(ServerServeConfigurationError.emptyHost.description == "host cannot be empty")
    #expect(
        ServerServeConfigurationError.invalidPort(80_000).description
            == "port must be between 0 and 65535, got 80000"
    )
    #expect(
        ServerServeConfigurationError.invalidRequestTimeout(0).description
            == "requestTimeoutSeconds must be greater than 0, got 0.0"
    )
    #expect(
        ServerServeConfigurationError.invalidMaximumConcurrentRequests(0).description
            == "maximumConcurrentRequests must be greater than 0, got 0"
    )
    #expect(
        ServerServeConfigurationError.invalidMaximumQueuedRequests(-1).description
            == "maximumQueuedRequests must be zero or greater, got -1"
    )
    #expect(
        ServerServeConfigurationError.invalidMaxHeaderBytes(0).description
            == "maxHeaderBytes must be greater than 0, got 0"
    )
    #expect(
        ServerServeConfigurationError.invalidMaxRequestBodyBytes(-1).description
            == "maxRequestBodyBytes must be greater than 0, got -1"
    )
    #expect(ServerServeConfigurationError.emptyAuthorizationTokenPath.description == "authorizationTokenPath cannot be empty")
    #expect(
        ServerServeConfigurationError.invalidLogLevel("verbose").description
            == "logLevel must be one of debug, info, warn, error, got verbose"
    )
}
