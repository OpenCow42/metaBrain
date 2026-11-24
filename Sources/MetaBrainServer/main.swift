import ArgumentParser
import Dispatch
import Foundation
import MetaBrainServerSupport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct MetaBrainDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mbd",
        abstract: "Run the metaBrain local daemon.",
        discussion: """
            Start the foreground daemon:
              mbd serve --store .metabrain/store.leveldb --socket ~/.metabrain/mbd.sock

            Pass --host 127.0.0.1 --port 6374 to use loopback HTTP instead.
            """,
        subcommands: [
            Serve.self,
            Service.self,
            Version.self,
        ]
    )

    func run() throws {
        print(Self.helpMessage())
    }
}

extension MetaBrainDaemonCommand {
    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "serve",
            abstract: "Run the foreground daemon."
        )

        @Option(name: .long, help: "JSON config file to load before applying command-line overrides.")
        var config: String?

        @Option(name: .long, help: "Default MetaBrain store path when a client does not send one.")
        var store: String?

        @Option(name: .long, help: "Unix domain socket path for local daemon traffic.")
        var socket: String?

        @Option(name: .long, help: "Loopback HTTP host for debugging transport.")
        var host: String?

        @Option(name: .long, help: "Loopback HTTP port for debugging transport.")
        var port: Int?

        @Option(name: .long, help: "Request read timeout in seconds.")
        var requestTimeoutSeconds: Double?

        @Option(name: .long, help: "Seconds to keep an idle store open before releasing its database lock.")
        var storeIdleTimeoutSeconds: Double?

        @Option(name: .long, help: "Maximum concurrent requests.")
        var maximumConcurrentRequests: Int?

        @Option(name: .long, help: "Maximum queued requests.")
        var maximumQueuedRequests: Int?

        @Option(name: .long, help: "Maximum HTTP header bytes.")
        var maxHeaderBytes: Int?

        @Option(name: .long, help: "Maximum HTTP request body bytes.")
        var maxRequestBodyBytes: Int?

        @Option(name: .long, help: "Minimum structured log level.")
        var logLevel: String?

        func run() throws {
            do {
                let fileConfiguration: ServerFileConfiguration?
                if let config {
                    fileConfiguration = try ServerConfigurationLoader.loadExplicitConfig(at: config)
                } else {
                    fileConfiguration = try ServerConfigurationLoader.loadDefaultConfig()
                }

                let configuration = try ServerServeConfiguration(
                    storePath: store,
                    socketPath: socket,
                    host: host,
                    port: port,
                    requestTimeoutSeconds: requestTimeoutSeconds,
                    storeIdleTimeoutSeconds: storeIdleTimeoutSeconds,
                    maximumConcurrentRequests: maximumConcurrentRequests,
                    maximumQueuedRequests: maximumQueuedRequests,
                    maxHeaderBytes: maxHeaderBytes,
                    maxRequestBodyBytes: maxRequestBodyBytes,
                    logLevel: logLevel,
                    fileConfiguration: fileConfiguration
                )
                #if canImport(Darwin) || canImport(Glibc) || canImport(WinSDK)
                let logger = ServerStructuredLogger(
                    minimumLevel: try ServerLogLevel(validating: configuration.logLevel)
                ) { line in
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                }
                let storeRegistry = MetaBrainStoreRegistry(
                    idleTimeoutSeconds: configuration.storeIdleTimeoutSeconds
                )
                defer { storeRegistry.closeAllBlocking() }
                let router = ServerRouter(
                    storeRegistry: storeRegistry,
                    defaultStorePath: configuration.storePath
                )
                let server = ServerHTTPServer(configuration: configuration, router: router, logger: logger)
                let shutdownSignals = ServerShutdownSignalHandler(server: server)
                defer { shutdownSignals.cancel() }

                try server.run { mode in
                    let line: String
                    switch mode {
                    case .unixSocket(let path):
                        line = "mbd serving on unix socket \(path)"
                    case .loopback(let host, let port):
                        line = "mbd serving on loopback http \(host):\(port)"
                    }
                    FileHandle.standardOutput.write(Data((line + "\n").utf8))
                }
                #else
                _ = configuration
                throw ValidationError("mbd serve is unavailable on this platform")
                #endif
            } catch {
                throw ValidationError(String(describing: error))
            }
        }
    }

    struct Service: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "service",
            abstract: "Manage user service manager files.",
            subcommands: [
                Print.self,
                Install.self,
                Uninstall.self,
                Start.self,
                Stop.self,
                Status.self,
            ]
        )

        struct Print: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "print",
                abstract: "Print a user service file."
            )

            @Flag(name: .long, help: "Print a user service file.")
            var user = false

            @Option(name: .long, help: "JSON config file to pass to mbd serve.")
            var config: String?

            func validate() throws {
                guard user else {
                    throw ValidationError("only user service files are supported; pass --user")
                }
            }

            func run() throws {
                let service = try ServerServicePrintConfiguration(
                    executablePath: Service.executablePath(),
                    configPath: config
                )
                print(service.renderUserServiceFile(), terminator: "")
            }
        }

        struct Install: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "install",
                abstract: "Install a user service file."
            )

            @Flag(name: .long, help: "Install a user service file.")
            var user = false

            @Option(name: .long, help: "JSON config file to pass to mbd serve.")
            var config: String?

            @Flag(name: .long, help: "Start and enable the user service after installing it.")
            var now = false

            func validate() throws {
                guard user else {
                    throw ValidationError("only user service files are supported; pass --user")
                }
            }

            func run() throws {
                let configuration = try ServerUserServiceFileConfiguration(
                    homeDirectory: Service.homeDirectory(),
                    executablePath: Service.executablePath(),
                    configPath: config
                )
                let path = try ServerUserServiceFileManager.install(configuration)
                print(path)
                if now {
                    try Service.runUserServiceAction(.start)
                }
            }
        }

        struct Uninstall: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "uninstall",
                abstract: "Uninstall a user service file."
            )

            @Flag(name: .long, help: "Uninstall a user service file.")
            var user = false

            func validate() throws {
                guard user else {
                    throw ValidationError("only user service files are supported; pass --user")
                }
            }

            func run() throws {
                let result = try ServerUserServiceFileManager.uninstall(
                    homeDirectory: Service.homeDirectory()
                )
                print(result.message)
            }
        }

        struct Start: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "start",
                abstract: "Enable and start the installed user service."
            )

            @Flag(name: .long, help: "Start a user service.")
            var user = false

            func validate() throws {
                guard user else {
                    throw ValidationError("only user service files are supported; pass --user")
                }
            }

            func run() throws {
                try Service.runUserServiceAction(.start)
            }
        }

        struct Stop: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "stop",
                abstract: "Disable and stop the installed user service."
            )

            @Flag(name: .long, help: "Stop a user service.")
            var user = false

            func validate() throws {
                guard user else {
                    throw ValidationError("only user service files are supported; pass --user")
                }
            }

            func run() throws {
                try Service.runUserServiceAction(.stop)
            }
        }

        struct Status: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "status",
                abstract: "Print the installed user service status."
            )

            @Flag(name: .long, help: "Inspect a user service.")
            var user = false

            func validate() throws {
                guard user else {
                    throw ValidationError("only user service files are supported; pass --user")
                }
            }

            func run() throws {
                try Service.runUserServiceAction(.status)
            }
        }

        private static func executablePath() -> String {
            Bundle.main.executableURL!.path
        }

        private static func homeDirectory() -> String {
            ProcessInfo.processInfo.environment["HOME", default: ""]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func runUserServiceAction(_ action: ServerUserServiceAction) throws {
            let plan = try ServerUserServiceController.commandPlan(
                action: action,
                homeDirectory: homeDirectory(),
                userID: try currentUserID()
            )
            try runServiceCommands(plan.commands)
            if let message = plan.message {
                print(message)
            }
        }

        private static func currentUserID() throws -> Int {
            #if canImport(Darwin) || canImport(Glibc)
            return Int(getuid())
            #else
            throw ValidationError("user service control is unavailable on this platform")
            #endif
        }

        private static func runServiceCommands(_ commands: [[String]]) throws {
            for command in commands where !command.isEmpty {
                try runServiceCommand(command)
            }
        }

        private static func runServiceCommand(_ command: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            guard waitForServiceCommand(process, timeoutSeconds: 15) else {
                process.terminate()
                throw ValidationError(
                    "\(command.joined(separator: " ")) timed out after 15 seconds"
                )
            }

            guard process.terminationStatus == 0 else {
                throw ValidationError(
                    "\(command.joined(separator: " ")) failed with exit code \(process.terminationStatus)"
                )
            }
        }

        private static func waitForServiceCommand(_ process: Process, timeoutSeconds: Double) -> Bool {
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                semaphore.signal()
            }
            return semaphore.wait(timeout: .now() + timeoutSeconds) == .success
        }
    }

    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Print the metaBrain daemon version."
        )

        func run() throws {
            let output = VersionOutput(
                currentTag: MetaBrainVersion.currentSoftwareTag(),
                releaseCheck: nil
            )
            let data = try MetaBrainJSON.encoder().encode(output)
            print(String(decoding: data, as: UTF8.self))
        }
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(WinSDK)
private final class ServerShutdownSignalHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []

    init(server: ServerHTTPServer) {
        let queue = DispatchQueue(label: "dev.metabrain.mbd.shutdown-signals")
        for signalNumber in [Int32(SIGINT), Int32(SIGTERM)] {
            ignoreSignal(signalNumber)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [server] in
                server.stop()
            }
            sources.append(source)
            source.resume()
        }
    }

    func cancel() {
        lock.withLock {
            sources.forEach { $0.cancel() }
            sources.removeAll()
        }
    }
}

private func ignoreSignal(_ signalNumber: Int32) {
    #if canImport(Darwin)
    _ = Darwin.signal(signalNumber, SIG_IGN)
    #elseif canImport(Glibc)
    _ = Glibc.signal(signalNumber, SIG_IGN)
    #endif
}
#endif
