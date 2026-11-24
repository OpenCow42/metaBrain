import ArgumentParser
import Foundation
import MetaBrainCore
import MetaBrainServerSupport

@main
enum MetaBrainCommandMain {
    static func main() async {
        await MetaBrainCommand.main(cliArgumentsWithGlobalOptions(Array(CommandLine.arguments.dropFirst())))
    }
}

struct MetaBrainCommand: AsyncParsableCommand {
    private static let agentDiscoveryGuide = """
        metaBrain is a local document memory for agents and tools. Use it to keep
        durable notes, source snippets, task context, metadata, tags, and links in a
        searchable store instead of scattering scratch files across a workspace.

        Store manual: read the selected store's agent guide with mb get /AGENTS.md.
        Use mb ensure-guide to add the default guide if the store lacks one.

        Agent discovery:
          mb
          mb help
          mb --help
          mb help list
          mb help tree
          mb help search
          mb help get
          mb help links
          mb help lint
          mb help recall
          mb help dump
          mb help move
          mb help delete
          mb help remove-version
          mb help version

        Common workflow:
          mb get /AGENTS.md
          mb search --tag storage --view refs --limit 5
          mb search "nightly backups" --view evidence --max-tokens 512
          mb get --ref "$ref" --context section --max-tokens 1024
          mb put /decisions/backups.md 'Follow [[Retention#^keep-last]].' --if-version 0
          mb links /decisions/backups.md
          mb lint /decisions

        Run mb init to create a store. Set ref to a value returned by search.

        Store selection uses --store, then METABRAIN_STORE, then the nearest
        ancestor .metabrain/store.leveldb, starting in the current directory.
        When no store exists, init and put can create .metabrain/store.leveldb in
        the current directory. Other store-backed commands require an existing
        store. Pass --store before or after the subcommand.
        Store-backed commands auto-use a healthy local daemon at
        http://127.0.0.1:6374 when one is already running.
        Pass --server to force a daemon endpoint, or --no-server to force direct
        LevelDB access.
        """

    static let configuration = CommandConfiguration(
        commandName: "mb",
        abstract: "Inspect and update a metaBrain document store.",
        discussion: agentDiscoveryGuide,
        subcommands: [
            Help.self,
            Initialize.self,
            EnsureGuide.self,
            Put.self,
            Patch.self,
            Operation.self,
            Move.self,
            Get.self,
            Links.self,
            Lint.self,
            List.self,
            Tree.self,
            Search.self,
            Recall.self,
            Dump.self,
            Versions.self,
            Prune.self,
            Delete.self,
            RemoveVersion.self,
            Version.self
        ]
    )

    func run() async throws {
        print(Self.helpMessage())
    }
}

struct StoreOptions: ParsableArguments {
    static let defaultLoopbackServer: String = {
        let defaultPort = ServerServeConfiguration.defaultLoopbackPort
        #if METABRAIN_COVERAGE_SMOKE
        let port = ProcessInfo.processInfo.environment["METABRAIN_COVERAGE_LOOPBACK_PORT"]
            .flatMap(UInt16.init) ?? UInt16(defaultPort)
        return "http://127.0.0.1:\(port)"
        #else
        return "http://127.0.0.1:\(defaultPort)"
        #endif
    }()
    static let autoProbeTimeoutMilliseconds = 50
    static let daemonRequestTimeoutMilliseconds = 30_000

    @Option(help: "Store path. Overrides METABRAIN_STORE and ancestor discovery.")
    var store: String?

    @Option(help: "Unix socket path, loopback HTTP URL such as http://127.0.0.1:6374, or auto for daemon mode.")
    var server: String?

    @Flag(help: "Skip daemon auto-detection and open the LevelDB store directly.")
    var noServer = false

    func serverClient(createIfMissing: Bool = false) throws -> MetaBrainServerClient? {
        guard !noServer else {
            return nil
        }

        let endpoint: String
        if let server, server != "auto" {
            endpoint = server
        } else {
            let probe = MetaBrainServerClient(
                socketPath: Self.defaultLoopbackServer,
                requestTimeoutMilliseconds: Self.autoProbeTimeoutMilliseconds
            )
            guard let health = try? probe.health(), health.service == "mbd", health.status == "ok" else {
                return nil
            }
            endpoint = Self.defaultLoopbackServer
        }

        let url = resolvedStoreURL
        if !createIfMissing {
            // Older daemons can create a store when handling any request.
            try MetaBrainStore.requireExistingStore(at: url)
        }
        return MetaBrainServerClient(
            socketPath: endpoint,
            storePath: url.path,
            requestTimeoutMilliseconds: Self.daemonRequestTimeoutMilliseconds
        )
    }

    var resolvedStoreURL: URL {
        if let store {
            return URL.expandingShellPath(store, isDirectory: true).standardizedFileURL
        }
        if let store = ProcessInfo.processInfo.environment["METABRAIN_STORE"], !store.isEmpty {
            return URL.expandingShellPath(store, isDirectory: true).standardizedFileURL
        }

        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        var directory = currentDirectory
        while true {
            let candidate = Self.workspaceStoreURL(in: directory)
            if MetaBrainStore.exists(at: candidate) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return Self.workspaceStoreURL(in: currentDirectory)
    }

    private static func workspaceStoreURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent(".metabrain", isDirectory: true)
            .appendingPathComponent("store.leveldb", isDirectory: true)
    }

    func withOpenStore<Result: Sendable>(
        createIfMissing: Bool = false,
        _ operation: (MetaBrainStore) async throws -> Result
    ) async throws -> Result {
        let url = resolvedStoreURL
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let store = try MetaBrainStore(url: url, options: MetaBrainStoreOptions(createIfMissing: createIfMissing))

        do {
            let result = try await operation(store)
            await store.close()
            return result
        } catch {
            await store.close()
            throw error
        }
    }
}

enum CLIOutputFormat: String, ExpressibleByArgument {
    case text
    case json
    case jsonl
}

struct OutputFormatOptions: ParsableArguments {
    @Option(help: "Output format: text, json, or jsonl.")
    var format: CLIOutputFormat = .json
}

struct TextOutputFormatOptions: ParsableArguments {
    @Option(help: "Output format: text, json, or jsonl.")
    var format: CLIOutputFormat = .json
}

struct ListOutputFormatOptions: ParsableArguments {
    @Option(help: "Output format: text, json, or jsonl.")
    var format: CLIOutputFormat = .jsonl
}

struct ReferenceOptions: ParsableArguments {
    @Option(help: "Document ID to read.")
    var id: String?

    @Option(name: .customLong("path"), help: "Document path to read.")
    var optionPath: String?

    @Argument(help: "Document path to read.")
    var path: String?

    var hasReference: Bool {
        id != nil || optionPath != nil || path != nil
    }

    func reference() throws -> DocumentReference {
        let provided = [id != nil, optionPath != nil, path != nil].filter { $0 }.count
        guard provided == 1 else {
            throw ValidationError("Provide exactly one of --id, --path, or a positional path.")
        }

        if let rawID = id {
            return .documentID(try DocumentID(rawValue: rawID))
        }

        return .path(try DocumentPath(optionPath ?? path!))
    }
}

struct RetentionOptions: ParsableArguments {
    @Flag(help: "Keep every document version.")
    var keepAll = false

    @Option(help: "Keep only the most recent N versions.")
    var keepLast: Int?

    @Option(help: "Keep versions created within this many seconds.")
    var keepWithin: TimeInterval?

    func optionalPolicy() throws -> VersionRetentionPolicy? {
        let provided = [keepAll, keepLast != nil, keepWithin != nil].filter { $0 }.count
        guard provided <= 1 else {
            throw ValidationError("Use only one retention option.")
        }

        if keepAll {
            return .keepAll
        }

        if let keepLast {
            guard keepLast > 0 else {
                throw ValidationError("--keep-last must be greater than zero.")
            }

            return .keepMostRecent(keepLast)
        }

        if let keepWithin {
            guard keepWithin >= 0 else {
                throw ValidationError("--keep-within must be zero or greater.")
            }

            return .keepWithin(keepWithin)
        }

        return nil
    }

    func requiredPolicy() throws -> VersionRetentionPolicy {
        guard let policy = try optionalPolicy() else {
            throw ValidationError("Provide one of --keep-all, --keep-last, or --keep-within.")
        }

        return policy
    }
}

extension MetaBrainCommand {
    struct Help: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "help",
            abstract: "Show the CLI manual and how to read the store guide.",
            aliases: ["man"]
        )

        @Argument(help: "Command to inspect. Read the store guide with mb get /AGENTS.md.")
        var command: String?

        private var topic: ParsableCommand.Type? {
            guard let command else { return nil }
            return MetaBrainCommand.configuration.subcommands.first {
                $0.configuration.commandName == command || $0.configuration.aliases.contains(command)
            }
        }

        func validate() throws {
            if let command, topic == nil {
                let topics = MetaBrainCommand.configuration.subcommands.compactMap { $0.configuration.commandName }.joined(separator: ", ")
                throw ValidationError("Unknown help topic '\(command)'. Use one of: \(topics).")
            }
        }

        func run() {
            guard let topic else {
                print(MetaBrainCommand.helpMessage())
                return
            }
            print(topic.helpMessage())
            print("\nStore guide: mb get /AGENTS.md")
        }
    }

    struct Initialize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Create or open a metaBrain store.",
            discussion: "New stores start with /AGENTS.md unless you pass --empty. Existing stores keep their documents."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: OutputFormatOptions

        @Flag(help: "Create a new store with no initial documents.")
        var empty = false

        func run() async throws {
            if let client = try storeOptions.serverClient(createIfMissing: true) {
                let result: InitializeOutput = try client.post("/v1/init", request: ServerInitializeRequest(empty: empty))
                try printInitializeOutput(result, format: output.format)
                return
            }

            let store = try await MetaBrainStore.initialize(at: storeOptions.resolvedStoreURL, empty: empty)
            await store.close()
            try printInitializeOutput(InitializeOutput(storePath: store.url.path), format: output.format)
        }
    }

    struct EnsureGuide: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ensure-guide",
            abstract: "Add the default /AGENTS.md to an existing store if absent.",
            discussion: "Preserves existing instructions and their version. Read the guide with mb get /AGENTS.md."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: OutputFormatOptions

        func run() async throws {
            let result: PutOutput
            if let client = try storeOptions.serverClient() {
                result = try client.post("/v1/ensure-guide")
            } else {
                result = try await storeOptions.withOpenStore { store in
                    PutOutput(try await store.ensureAgentGuide(), operation: "ensure-guide")
                }
            }
            try printPutOutput(result, format: output.format)
        }
    }

    struct Put: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "put",
            abstract: "Create or update a document at a path."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: OutputFormatOptions
        @OptionGroup var retention: RetentionOptions

        @Argument(help: "Document path.")
        var path: String

        @Argument(help: "Document body. Use --body-file for larger content.")
        var body: String?

        @Option(help: "Optional document title.")
        var title: String?

        @Option(name: .customLong("body-file"), help: "Read the document body from a UTF-8 text file.")
        var bodyFile: String?

        @Option(name: .customLong("tag"), help: "Tag to attach. Repeat for multiple tags.")
        var tags: [String] = []

        @Option(name: .customLong("meta"), help: "Metadata as key=value. Repeat for multiple values.")
        var metadataPairs: [String] = []

        @Option(name: .customLong("ref-id"), help: "Reference a document ID. Repeat for multiple references.")
        var referenceIDs: [String] = []

        @Option(name: .customLong("ref-path"), help: "Reference a document path. Repeat for multiple references.")
        var referencePaths: [String] = []

        @Option(name: .customLong("ref-url"), help: "Reference an external URL. Repeat for multiple references.")
        var referenceURLs: [String] = []

        @Option(name: .customLong("if-version"), help: "Write only at this current version. Use 0 to create only.")
        var ifVersion: UInt64?

        @Flag(name: .customLong("body-only"), help: "Replace only the body of an existing document.")
        var bodyOnly = false

        @Flag(help: "Index Markdown links and anchors even when the path has no .md extension.")
        var markdown = false

        func validate() throws {
            try validateBodyInputs(argument: body, filePath: bodyFile)
            let retentionPolicy = try retention.optionalPolicy()
            if bodyOnly {
                guard ifVersion != 0 else {
                    throw ValidationError("--body-only requires an existing document and cannot be combined with --if-version 0.")
                }
                guard !markdown else {
                    throw ValidationError("--body-only preserves Markdown opt-in and cannot be combined with --markdown.")
                }
                guard title == nil, tags.isEmpty, metadataPairs.isEmpty, referenceIDs.isEmpty,
                      referencePaths.isEmpty, referenceURLs.isEmpty, retentionPolicy == nil else {
                    throw ValidationError("--body-only preserves title, tags, metadata, references, and retention. Omit those flags.")
                }
            }
            _ = try parseMetadata(metadataPairs)
            _ = try parseReferences(
                ids: referenceIDs,
                paths: referencePaths,
                urls: referenceURLs
            )
        }

        func run() async throws {
            let documentBody = try readBody(argument: body, filePath: bodyFile)
            let documentReferences = try parseReferences(
                ids: referenceIDs,
                paths: referencePaths,
                urls: referenceURLs
            )
            let retentionPolicy = try retention.optionalPolicy()
            let metadata = try parseMetadata(metadataPairs)

            let createIfMissing = !bodyOnly && (ifVersion == nil || ifVersion == 0)
            let result: PutOutput
            if let client = try storeOptions.serverClient(createIfMissing: createIfMissing) {
                let request = ServerPutRequest(
                    path: path,
                    body: documentBody,
                    title: title,
                    tags: tags,
                    metadata: metadata,
                    references: documentReferences.map(DocumentReferenceDTO.init),
                    retention: retentionPolicy.map(DocumentRetentionPolicyDTO.init)
                )
                if markdown {
                    result = try client.putMarkdown(ServerMarkdownPutRequest(document: request, ifVersion: ifVersion))
                } else if ifVersion != nil || bodyOnly {
                    result = try client.putConditional(ServerConditionalPutRequest(
                        document: request,
                        ifVersion: ifVersion,
                        bodyOnly: bodyOnly
                    ))
                } else {
                    result = try client.post("/v1/put", request: request)
                }
            } else {
                let input = DocumentInput(
                    path: try DocumentPath(path),
                    title: title,
                    body: documentBody,
                    tags: tags,
                    metadata: metadata,
                    references: documentReferences,
                    retention: retentionPolicy,
                    markdown: markdown ? true : nil
                )
                result = try await storeOptions.withOpenStore(createIfMissing: createIfMissing) { store in
                    PutOutput(try await store.writeDocument(input, ifVersion: ifVersion, bodyOnly: bodyOnly))
                }
            }
            try printPutOutput(result, format: output.format)
        }
    }

    struct Patch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "patch",
            abstract: "Patch a document body with a unified diff."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions
        @OptionGroup var output: OutputFormatOptions
        @OptionGroup var retention: RetentionOptions

        @Option(name: .customLong("patch-file"), help: "Read a unified diff from a UTF-8 file. Use '-' for stdin.")
        var patchFile: String

        @Flag(name: .customLong("check"), help: "Validate the patch without writing a new version.")
        var check = false

        func validate() throws {
            _ = try referenceOptions.reference()
            _ = try retention.optionalPolicy()
        }

        func run() async throws {
            let reference = try referenceOptions.reference()
            let patchText = try readPatch(filePath: patchFile)
            let retentionPolicy = try retention.optionalPolicy()

            if let client = try storeOptions.serverClient() {
                let request = ServerPatchRequest(
                    reference: DocumentReferenceDTO(reference),
                    unifiedDiff: patchText,
                    check: check,
                    retention: retentionPolicy.map(DocumentRetentionPolicyDTO.init)
                )

                if check {
                    let result: PatchCheckOutput = try client.post(
                        "/v1/patch",
                        request: request,
                        response: PatchCheckOutput.self
                    )
                    try printPatchCheckOutput(result, format: output.format)
                    return
                }

                let result: PatchOutput = try client.post(
                    "/v1/patch",
                    request: request,
                    response: PatchOutput.self
                )
                try printPatchOutput(result, format: output.format)
                return
            }

            let request = DocumentPatchRequest(
                reference: reference,
                unifiedDiff: patchText,
                retention: retentionPolicy
            )

            try await storeOptions.withOpenStore { store in
                if check {
                    try await store.checkDocumentPatch(request)
                    try printPatchCheckOutput(PatchCheckOutput(), format: output.format)
                    return
                }

                let document = try await store.patchDocument(request)
                try printPatchOutput(PatchOutput(document), format: output.format)
            }
        }
    }

    struct Operation: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "operation",
            abstract: "Inspect and apply reviewed project writes.",
            subcommands: [Inspect.self, Apply.self]
        )

        @OptionGroup var storeOptions: StoreOptions

        struct Inspect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "inspect",
                abstract: "Print a JSON preview without writing project documents."
            )

            @OptionGroup var storeOptions: StoreOptions
            @Argument(help: "JSON file describing the project operation.")
            var file: String

            func run() async throws {
                let data = try Data(contentsOf: URL.expandingShellPath(file, isDirectory: false))
                let operation = try MetaBrainJSON.decoder().decode(ProjectOperation.self, from: data)
                let preview: OperationPreview
                if let client = try storeOptions.serverClient() {
                    preview = try client.post("/v1/operation-inspect", request: operation)
                } else {
                    preview = try await storeOptions.withOpenStore { store in
                        try await store.inspectOperation(operation)
                    }
                }
                try printJSON(preview)
            }
        }

        struct Apply: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "apply",
                abstract: "Apply an inspected preview and print its JSON receipt."
            )

            @OptionGroup var storeOptions: StoreOptions
            @Argument(help: "JSON preview returned by mb operation inspect.")
            var file: String

            func run() async throws {
                let data = try Data(contentsOf: URL.expandingShellPath(file, isDirectory: false))
                let preview = try MetaBrainJSON.decoder().decode(OperationPreview.self, from: data)
                let receipt: OperationReceipt
                if let client = try storeOptions.serverClient() {
                    receipt = try client.post("/v1/operation-apply", request: preview)
                } else {
                    receipt = try await storeOptions.withOpenStore { store in
                        try await store.applyOperation(preview)
                    }
                }
                try printJSON(receipt)
            }
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Move an existing document to a new path without changing its ID.",
            discussion: """
            Document identity is stable across moves. Cross-document relationships are
            safest when expressed with --ref-id because document IDs are preserved when
            paths change. Path references are location aliases; they are not rewritten
            automatically when another document moves.
            """
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: OutputFormatOptions

        @Option(help: "Document ID to move. When provided, pass only the destination path as an argument.")
        var id: String?

        @Argument(help: "Source and destination paths, or just the destination path when --id is provided.")
        var paths: [String] = []

        func validate() throws {
            if id == nil {
                guard paths.count == 2 else {
                    throw ValidationError("Provide a source path and a destination path, or use --id with one destination path.")
                }
            } else {
                guard paths.count == 1 else {
                    throw ValidationError("Use --id with exactly one destination path.")
                }
            }

            _ = try sourceReference()
            _ = try destinationPath()
        }

        func run() async throws {
            let reference = try sourceReference()
            let destination = try destinationPath()

            if let client = try storeOptions.serverClient() {
                let result: MoveOutput = try client.post(
                    "/v1/move",
                    request: ServerMoveRequest(
                        reference: DocumentReferenceDTO(reference),
                        destinationPath: destination.rawValue
                    ),
                    response: MoveOutput.self
                )
                try printMoveOutput(result, format: output.format)
                return
            }

            let result = try await storeOptions.withOpenStore { store in
                try await store.moveDocument(reference, to: destination)
            }
            try printMoveOutput(MoveOutput(result), format: output.format)
        }

        private func sourceReference() throws -> DocumentReference {
            if let id {
                return .documentID(try DocumentID(rawValue: id))
            }

            return .path(try DocumentPath(paths[0]))
        }

        private func destinationPath() throws -> DocumentPath {
            try DocumentPath(id == nil ? paths[1] : paths[0])
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Read a document by path or ID, a Markdown passage, or an evidence reference."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions
        @OptionGroup var output: OutputFormatOptions

        @Option(help: "Read a retained version sequence instead of the current document.")
        var version: UInt64?

        @Option(help: "Read the Markdown block with this ID.")
        var block: String?

        @Option(help: "Read the Markdown section with this heading.")
        var heading: String?

        @Option(help: "Read a version-specific reference from search --view evidence or refs.", transform: { try EvidenceReference($0) })
        var ref: EvidenceReference?

        @Option(help: "Expand a reference to its enclosing Markdown section.", transform: { raw in
            guard let context = EvidenceContext(rawValue: raw) else {
                throw ValidationError("Use --context section.")
            }
            return context
        })
        var context: EvidenceContext?

        @Option(help: "Limit compact evidence JSON to this many tokens using its UTF-8 byte count.")
        var maxTokens: Int?

        func validate() throws {
            if version == 0 {
                throw ValidationError("--version must be greater than zero.")
            }
            if ref != nil {
                guard !referenceOptions.hasReference, version == nil, block == nil, heading == nil else {
                    throw ValidationError("--ref cannot be combined with a document path, ID, --version, --block, or --heading.")
                }
                guard output.format == .json else {
                    throw ValidationError("--ref uses compact JSON. Use --format json.")
                }
                try validateEvidenceBudget(maxTokens)
                return
            }
            guard context == nil, maxTokens == nil else {
                throw ValidationError("--context and --max-tokens require --ref.")
            }
            let reference = try referenceOptions.reference()
            if let request = passageRequest(for: reference) {
                _ = try request.passageSelector()
            }
        }

        func run() async throws {
            if let ref {
                try await readEvidence(ref)
                return
            }
            let reference = try referenceOptions.reference()
            if let request = passageRequest(for: reference) {
                try await readPassage(request)
                return
            }
            let outputResult: GetOutput
            if let client = try storeOptions.serverClient() {
                if let version {
                    outputResult = try client.getVersion(ServerGetDocumentVersionRequest(
                        reference: DocumentReferenceDTO(reference), version: version
                    ))
                } else {
                    outputResult = try client.post(
                        "/v1/get", request: ServerGetRequest(reference: DocumentReferenceDTO(reference))
                    )
                }
            } else {
                let document = try await storeOptions.withOpenStore { store in
                    if let version {
                        guard let snapshot = try await store.getDocument(reference, version: version) else {
                            throw MetaBrainStoreError.documentVersionNotFound(
                                reference: DocumentReferenceDTO(reference).value,
                                version: version
                            )
                        }
                        return snapshot
                    }
                    guard let current = try await store.getDocument(reference) else {
                        throw ValidationError("Document not found.")
                    }
                    return current
                }
                outputResult = GetOutput(document)
            }

            try printGetOutput(outputResult, format: output.format)
        }

        private func readEvidence(_ reference: EvidenceReference) async throws {
            let budget = maxTokens ?? EvidenceOutput.defaultMaxTokens
            let result: EvidenceOutput
            if let client = try storeOptions.serverClient() {
                result = try client.getEvidence(ServerGetEvidenceRequest(ref: reference, context: context, maxTokens: budget))
            } else {
                result = try await storeOptions.withOpenStore { store in
                    try await store.getEvidence(reference, context: context, maxTokens: budget)
                }
            }
            try printEvidenceOutput(result, maxTokens: budget)
        }

        private func passageRequest(for reference: DocumentReference) -> ServerGetPassageRequest? {
            guard block != nil || heading != nil else { return nil }
            return ServerGetPassageRequest(
                reference: DocumentReferenceDTO(reference), block: block, heading: heading, version: version
            )
        }

        private func readPassage(_ request: ServerGetPassageRequest) async throws {
            let result: DocumentPassageOutput
            if let client = try storeOptions.serverClient() {
                result = try client.getPassage(request)
            } else {
                result = try await storeOptions.withOpenStore { store in
                    try await request.read(from: store)
                }
            }
            switch output.format {
            case .text:
                print(result.text, terminator: result.text.hasSuffix("\n") ? "" : "\n")
            case .json, .jsonl:
                try printJSON(result)
            }
        }
    }

    struct Links: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "links",
            abstract: "Inspect Markdown link occurrences for a document."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: OutputFormatOptions

        @Argument(help: "Document path.")
        var path: String

        @Flag(help: "List links to this document.")
        var incoming = false

        @Option(help: "Limit links to this source block, or to this target block with --incoming.")
        var block: String?

        func validate() throws {
            _ = try DocumentPath(path)
            if block?.isEmpty == true {
                throw ValidationError("--block requires a nonempty block ID.")
            }
        }

        func run() async throws {
            let reference = DocumentReference.path(try DocumentPath(path))
            let direction: DocumentLinkDirection = incoming ? .incoming : .outgoing
            let links: [DocumentLinkOutput]
            if let client = try storeOptions.serverClient() {
                links = try client.links(ServerLinksRequest(
                    reference: DocumentReferenceDTO(reference), direction: direction, block: block
                ))
            } else {
                links = try await storeOptions.withOpenStore { store in
                    try await store.links(for: reference, direction: direction, block: block).map(DocumentLinkOutput.init)
                }
            }
            switch output.format {
            case .text:
                for link in links {
                    let target = link.targetPath.map { path in
                        path + (link.fragment.map { "#" + $0 } ?? "")
                    } ?? link.destination
                    print("\(link.sourcePath)@\(link.sourceVersion):\(link.start)-\(link.end)\t\(link.status.rawValue)\t\(target)")
                    print("  \(link.snippet)")
                    for candidate in link.candidates ?? [] {
                        print("  candidate: \(candidate.path)")
                    }
                }
            case .json:
                try printJSON(links)
            case .jsonl:
                try printJSONLines(links)
            }
        }
    }

    struct Lint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lint",
            abstract: "Audit current Markdown citations.",
            discussion: """
            Omit the path to audit the whole store. A path selects that document and its descendants.
            Citations resolve against the whole store. JSONL prints one finding per line.
            """
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: OutputFormatOptions

        @Argument(help: "Virtual path to audit, including its descendants.")
        var path: String?

        @Flag(help: "Report Markdown notes with no incoming link from another document.")
        var orphans = false

        @Flag(help: "Exit with status 3 when any selected check reports a finding.")
        var strict = false

        func run() async throws {
            let request = ServerLintRequest(path: path, includeOrphans: orphans)
            let query = try request.lintQuery()
            let report: DocumentLintReport
            if let client = try storeOptions.serverClient() {
                report = try client.lint(request)
            } else {
                report = try await storeOptions.withOpenStore { store in
                    try await store.lint(query)
                }
            }
            switch output.format {
            case .text:
                for finding in report.findings {
                    var location = "\(finding.sourcePath)@\(finding.sourceVersion)"
                    if let start = finding.start, let end = finding.end {
                        location += ":\(start)-\(end)"
                    }
                    var details = finding.destination.map { "\t\($0)" } ?? ""
                    if let target = finding.targetPath { details += "\tresolved document \(target)" }
                    if let candidates = finding.candidatePaths { details += "\t\(candidates.joined(separator: ", "))" }
                    print("\(location)\t\(finding.kind.rawValue)\(details)")
                }
                let noun = report.documentsChecked == 1 ? "document" : "documents"
                print("Checked \(report.documentsChecked) Markdown \(noun) under \(report.path).")
                let counts = DocumentLintKind.allCases.map { "\($0.rawValue)=\(report.counts[$0.rawValue, default: 0])" }
                print(counts.joined(separator: " "))
            case .json:
                try printJSON(report)
            case .jsonl:
                try printJSONLines(report.findings)
            }
            if strict, !report.findings.isEmpty { throw ExitCode(3) }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List stored document paths in a folder."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: ListOutputFormatOptions

        @Argument(help: "Folder path to list.")
        var path = "/"

        @Flag(help: "List all descendants instead of only direct children.")
        var recursive = false

        @Flag(help: "List only virtual directories.")
        var directoriesOnly = false

        @Flag(help: "Print created and updated dates for document entries.")
        var dates = false

        func validate() throws {
            _ = try DocumentPath(path)
        }

        func run() async throws {
            let root = try DocumentPath(path)
            let outputEntries: [ListOutput]

            if let client = try storeOptions.serverClient() {
                outputEntries = try client.post(
                    "/v1/list",
                    request: ServerListRequest(
                        path: root.rawValue,
                        recursive: recursive,
                        directoriesOnly: directoriesOnly
                    ),
                    response: [ListOutput].self
                )
            } else {
                let entries = try await storeOptions.withOpenStore { store in
                    try await store.listDirectory(
                        path: root,
                        recursive: recursive,
                        directoriesOnly: directoriesOnly
                    )
                }
                outputEntries = entries.map(ListOutput.init)
            }

            try printListOutputs(
                outputEntries,
                root: root,
                recursive: recursive,
                includeDates: dates,
                format: output.format
            )
        }
    }

    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tree",
            abstract: "Show the stored document path tree."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: ListOutputFormatOptions

        @Argument(help: "Folder path to use as the tree root.")
        var path = "/"

        @Flag(help: "Show only virtual directories.")
        var directoriesOnly = false

        @Option(help: "Maximum depth below the requested root. Use 0 for only the root.")
        var maxDepth: Int?

        func validate() throws {
            _ = try DocumentPath(path)
            if let maxDepth, maxDepth < 0 {
                throw ValidationError("--max-depth must be zero or greater.")
            }
        }

        func run() async throws {
            let root = try DocumentPath(path)
            let outputEntries: [TreeOutput]

            if let client = try storeOptions.serverClient() {
                outputEntries = try client.post(
                    "/v1/tree",
                    request: ServerTreeRequest(
                        path: root.rawValue,
                        directoriesOnly: directoriesOnly,
                        maxDepth: maxDepth
                    ),
                    response: [TreeOutput].self
                )
            } else {
                let entries = try await storeOptions.withOpenStore { store in
                    try await store.tree(TreeQuery(
                        path: root,
                        directoriesOnly: directoriesOnly,
                        maxDepth: maxDepth
                    ))
                }
                outputEntries = treeOutputs(root: root, entries: entries, maxDepth: maxDepth)
            }

            try printTreeOutputs(outputEntries, root: root, maxDepth: maxDepth, format: output.format)
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search current document content or find version-specific evidence."
        )

        @OptionGroup var storeOptions: StoreOptions

        @Argument(help: "Search text. Omit it with --view refs and a filter.")
        var query: String?

        @Option(help: "Limit results to this path prefix.")
        var pathPrefix: String?

        @Option(name: .customLong("tag"), help: "Require a tag. Repeat to intersect tags.")
        var tags: [String] = []

        @Option(name: .customLong("meta"), help: "Require metadata as key=value. Repeat to intersect filters.")
        var metadataPairs: [String] = []

        @Option(help: "Maximum number of results.")
        var limit = 20

        @Flag(help: "Include linked document hints.")
        var includeLinkedDocuments = false

        @Flag(help: "Include backlink hints.")
        var includeBacklinks = false

        @Option(help: "Compact JSON view: evidence or refs.", transform: { raw in
            guard let view = EvidenceSearchView(rawValue: raw) else {
                throw ValidationError("Use --view evidence or --view refs.")
            }
            return view
        })
        var view: EvidenceSearchView?

        @Option(help: "Limit compact evidence JSON to this many tokens using its UTF-8 byte count.")
        var maxTokens: Int?

        @Option(help: "Output format: text, json, or jsonl. Defaults to jsonl, or json with --view.")
        var format: CLIOutputFormat?

        func validate() throws {
            if limit <= 0 {
                throw ValidationError("--limit must be greater than zero.")
            }
            _ = try pathPrefix.map(DocumentPath.init)
            _ = try parseMetadata(metadataPairs)
            if view != nil {
                guard format == nil || format == .json else {
                    throw ValidationError("--view uses compact JSON. Use --format json.")
                }
                guard !includeLinkedDocuments, !includeBacklinks else {
                    throw ValidationError("--include-linked-documents and --include-backlinks are available with regular search.")
                }
                try validateEvidenceBudget(maxTokens)
            } else {
                guard maxTokens == nil else {
                    throw ValidationError("--max-tokens requires --view.")
                }
                guard query != nil else {
                    throw ValidationError("Provide search text or use --view refs with a filter.")
                }
            }
        }

        func run() async throws {
            let metadata = try parseMetadata(metadataPairs)
            if let view {
                try await searchEvidence(view: view, metadata: metadata)
                return
            }

            let searchQuery = SearchQuery(
                text: query ?? "",
                pathPrefix: try pathPrefix.map(DocumentPath.init),
                tags: tags,
                metadata: metadata,
                includeLinkedDocuments: includeLinkedDocuments,
                includeBacklinks: includeBacklinks,
                limit: limit
            )
            let outputResults: [SearchOutput]

            if let client = try storeOptions.serverClient() {
                outputResults = try client.post(
                    "/v1/search",
                    request: ServerSearchRequest(
                        query: searchQuery.text,
                        pathPrefix: searchQuery.pathPrefix?.rawValue,
                        tags: searchQuery.tags,
                        metadata: searchQuery.metadata,
                        includeLinkedDocuments: searchQuery.includeLinkedDocuments,
                        includeBacklinks: searchQuery.includeBacklinks,
                        limit: searchQuery.limit
                    ),
                    response: [SearchOutput].self
                )
            } else {
                let results = try await storeOptions.withOpenStore { store in
                    try await store.search(searchQuery)
                }
                outputResults = results.map(SearchOutput.init)
            }

            try printSearchOutputs(outputResults, format: format ?? .jsonl)
        }

        private func searchEvidence(view: EvidenceSearchView, metadata: [String: String]) async throws {
            let budget = maxTokens ?? EvidenceOutput.defaultMaxTokens
            let request = ServerEvidenceSearchRequest(
                query: query, pathPrefix: pathPrefix, tags: tags, metadata: metadata, limit: limit,
                view: view, maxTokens: budget
            )
            let result: EvidenceOutput
            if let client = try storeOptions.serverClient() {
                result = try client.searchEvidence(request)
            } else {
                result = try await storeOptions.withOpenStore { store in
                    try await store.searchEvidence(request.searchQuery(), view: view, maxTokens: budget)
                }
            }
            try printEvidenceOutput(result, maxTokens: budget)
        }
    }

    struct Recall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "recall",
            abstract: "Retrieve relevant passages in a byte-budgeted JSON array.",
            discussion: "Each result identifies a document and retained version. Passage offsets count characters in that version's body."
        )

        @OptionGroup var storeOptions: StoreOptions

        @Argument(help: "Search terms to recall.")
        var query: String

        @Option(name: .customLong("path-prefix"), help: "Limit results to this path prefix.")
        var pathPrefix: String?

        @Option(name: .customLong("tag"), help: "Require a tag. Repeat to intersect tags.")
        var tags: [String] = []

        @Option(name: .customLong("meta"), help: "Require metadata as key=value. Repeat to intersect filters.")
        var metadataPairs: [String] = []

        @Option(help: "Maximum number of distinct documents.")
        var limit = ServerRecallRequest.defaultLimit

        @Option(name: .customLong("max-bytes"), help: "Maximum UTF-8 output bytes including the final newline (3–1048576).")
        var maxBytes = RecallResult.defaultMaxBytes

        func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be greater than zero.")
            }
            guard (RecallResult.minimumMaxBytes...ServerRecallRequest.maximumOutputBytes).contains(maxBytes) else {
                throw ValidationError("--max-bytes must be between \(RecallResult.minimumMaxBytes) and \(ServerRecallRequest.maximumOutputBytes).")
            }
            _ = try pathPrefix.map(DocumentPath.init)
            _ = try parseMetadata(metadataPairs)
        }

        func run() async throws {
            let request = ServerRecallRequest(
                query: query,
                pathPrefix: pathPrefix,
                tags: tags,
                metadata: try parseMetadata(metadataPairs),
                limit: limit,
                maxBytes: maxBytes
            )
            let results: [RecallResult]
            if let client = try storeOptions.serverClient() {
                results = try client.recall(request)
            } else {
                let searchQuery = try request.searchQuery()
                results = try await storeOptions.withOpenStore { store in
                    try await store.recall(searchQuery, maxBytes: maxBytes)
                }
            }
            var output = try RecallResult.jsonData(results)
            output.append(10)
            guard output.count <= maxBytes else {
                throw ValidationError("Recall response exceeded --max-bytes \(maxBytes).")
            }
            try FileHandle.standardOutput.write(contentsOf: output)
        }
    }

    struct Dump: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dump",
            abstract: "Dump stored documents as JSONL and optional UTF-8 files."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: ListOutputFormatOptions

        @Argument(help: "Document or folder path to dump.")
        var path: String

        @Flag(help: "Dump every retained version for each selected document.")
        var versions = false

        @Option(name: .customLong("output-dir"), help: "Directory where UTF-8 body copies should be written.")
        var outputDirectory: String?

        func validate() throws {
            _ = try DocumentPath(path)
        }

        func run() async throws {
            let query = DocumentDumpQuery(
                path: try DocumentPath(path),
                versionSelection: versions ? .allRetained : .current
            )
            var dumpOutputs: [DumpOutput]

            if let client = try storeOptions.serverClient() {
                dumpOutputs = try client.post(
                    "/v1/dump",
                    request: ServerDumpRequest(path: query.path.rawValue, versions: versions),
                    response: [DumpOutput].self
                )
            } else {
                let entries = try await storeOptions.withOpenStore { store in
                    try await store.dump(query)
                }
                dumpOutputs = entries.map(DumpOutput.init)
            }

            if let outputDirectory {
                dumpOutputs = try writeDumpOutputs(dumpOutputs, to: outputDirectory)
            }

            try printDumpOutputs(dumpOutputs, format: output.format)
        }
    }

    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "versions",
            abstract: "List stored versions for a document."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions
        @OptionGroup var output: ListOutputFormatOptions

        func validate() throws {
            _ = try referenceOptions.reference()
        }

        func run() async throws {
            let outputVersions: [VersionsOutput]

            if let client = try storeOptions.serverClient() {
                outputVersions = try client.post(
                    "/v1/versions",
                    request: ServerVersionsRequest(reference: DocumentReferenceDTO(try referenceOptions.reference())),
                    response: [VersionsOutput].self
                )
            } else {
                let versions = try await storeOptions.withOpenStore { store in
                    try await store.listVersions(of: referenceOptions.reference())
                }
                outputVersions = versions.map(VersionsOutput.init)
            }

            try printVersionsOutputs(outputVersions, format: output.format)
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Prune document versions using a retention policy."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions
        @OptionGroup var retention: RetentionOptions
        @OptionGroup var output: OutputFormatOptions

        func validate() throws {
            _ = try referenceOptions.reference()
            _ = try retention.requiredPolicy()
        }

        func run() async throws {
            let request = PruneRequest(
                reference: try referenceOptions.reference(),
                policy: try retention.requiredPolicy()
            )

            if let client = try storeOptions.serverClient() {
                let result: PruneOutput = try client.post(
                    "/v1/prune",
                    request: ServerPruneRequest(
                        reference: DocumentReferenceDTO(request.reference),
                        retention: DocumentRetentionPolicyDTO(request.policy)
                    ),
                    response: PruneOutput.self
                )
                try printPruneOutput(result, format: output.format)
                return
            }

            let result = try await storeOptions.withOpenStore { store in
                try await store.prune(request)
            }
            try printPruneOutput(PruneOutput(result), format: output.format)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a document and all retained versions."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions
        @OptionGroup var output: OutputFormatOptions

        func validate() throws {
            _ = try referenceOptions.reference()
        }

        func run() async throws {
            let reference = try referenceOptions.reference()
            let formattedReference = formatReference(reference)

            if let client = try storeOptions.serverClient() {
                let result: DeleteOutput = try client.post(
                    "/v1/delete",
                    request: ServerDeleteRequest(reference: DocumentReferenceDTO(reference)),
                    response: DeleteOutput.self
                )
                try printDeleteOutput(result, format: output.format)
                return
            }

            let deleted = try await storeOptions.withOpenStore { store in
                try await store.deleteDocument(reference)
            }
            let result = DeleteOutput(reference: formattedReference, deleted: deleted)
            try printDeleteOutput(result, format: output.format)
        }
    }

    struct RemoveVersion: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove-version",
            abstract: "Remove one retained historical document version."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions
        @OptionGroup var output: OutputFormatOptions

        @Option(help: "Version sequence to remove.")
        var sequence: UInt64

        func validate() throws {
            _ = try referenceOptions.reference()
            guard sequence > 0 else {
                throw ValidationError("--sequence must be greater than zero.")
            }
        }

        func run() async throws {
            let reference = try referenceOptions.reference()
            let formattedReference = formatReference(reference)

            if let client = try storeOptions.serverClient() {
                let result: RemoveVersionOutput = try client.post(
                    "/v1/remove-version",
                    request: ServerRemoveVersionRequest(
                        reference: DocumentReferenceDTO(reference),
                        sequence: sequence
                    ),
                    response: RemoveVersionOutput.self
                )
                try printRemoveVersionOutput(result, format: output.format)
                return
            }

            let removed = try await storeOptions.withOpenStore { store in
                guard let document = try await store.getDocument(reference, trackingRead: false) else {
                    return false
                }

                return try await store.removeVersion(documentID: document.id, sequence: sequence)
            }
            let result = RemoveVersionOutput(
                reference: formattedReference,
                removed: removed,
                sequence: sequence
            )
            try printRemoveVersionOutput(result, format: output.format)
        }
    }

    struct Version: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Print the metaBrain version, local daemon version, and GitHub release status."
        )

        @OptionGroup var output: TextOutputFormatOptions

        @Option(help: "Unix socket path, loopback HTTP URL such as http://127.0.0.1:6374, or auto for the default local daemon.")
        var server: String?

        @Flag(help: "Skip local daemon version detection.")
        var noServer = false

        @Flag(name: .customLong("no-release-check"), help: "Skip the GitHub latest release check.")
        var noReleaseCheck = false

        @Option(name: .customLong("release-api-url"), help: "GitHub latest release API URL.")
        var releaseAPIURL = "https://api.github.com/repos/OpenCow42/metaBrain/releases/latest"

        @Option(name: .customLong("release-check-timeout"), help: "Seconds to wait for the GitHub release check.")
        var releaseCheckTimeout: TimeInterval = 5

        func validate() throws {
            guard releaseCheckTimeout > 0 else {
                throw ValidationError("--release-check-timeout must be greater than zero.")
            }

            guard URL(string: releaseAPIURL)?.scheme != nil else {
                throw ValidationError("--release-api-url must be an absolute URL.")
            }
        }

        func run() async throws {
            let currentTag = currentSoftwareTag()
            let serverVersion = resolveServerVersion(server: server, noServer: noServer)
            let releaseCheck: ReleaseCheckOutput?

            if noReleaseCheck {
                releaseCheck = nil
            } else {
                releaseCheck = await MetaBrainReleaseChecker.checkLatestRelease(
                    currentTag: currentTag,
                    releaseAPIURL: releaseAPIURL,
                    timeout: releaseCheckTimeout
                )
            }

            let result = VersionOutput(
                currentTag: currentTag,
                releaseCheck: releaseCheck,
                server: serverVersion
            )

            switch output.format {
            case .text:
                print("version: \(currentTag)")
                if let serverVersion {
                    print("server: \(serverVersion.endpoint)")
                    print("serverReachable: \(serverVersion.reachable)")
                    if let currentTag = serverVersion.currentTag {
                        print("serverVersion: \(currentTag)")
                    } else {
                        print("serverVersion: unavailable")
                    }
                    if let error = serverVersion.error {
                        print("serverError: \(error)")
                    }
                } else {
                    print("server: skipped")
                }
                if let releaseCheck {
                    print("latest: \(releaseCheck.latestTag ?? "unknown")")
                    print("updateAvailable: \(releaseCheck.updateAvailable.map(String.init) ?? "unknown")")
                    print("releaseCheck: \(releaseCheck.status)")
                    if let htmlURL = releaseCheck.htmlURL {
                        print("releaseURL: \(htmlURL)")
                    }
                    if let message = releaseCheck.message {
                        print("message: \(message)")
                    }
                } else {
                    print("releaseCheck: skipped")
                }
            case .json:
                try printJSON(result)
            case .jsonl:
                try printJSONLine(result)
            }
        }
    }
}

private func resolveServerVersion(server: String?, noServer: Bool) -> ServerVersionOutput? {
    guard !noServer else {
        return nil
    }

    let endpoint: String
    if let server, server != "auto" {
        endpoint = server
    } else {
        endpoint = StoreOptions.defaultLoopbackServer
    }

    let timeout = server == nil || server == "auto"
        ? StoreOptions.autoProbeTimeoutMilliseconds
        : StoreOptions.daemonRequestTimeoutMilliseconds
    let client = MetaBrainServerClient(
        socketPath: endpoint,
        requestTimeoutMilliseconds: timeout
    )

    do {
        let version = try client.version()
        return ServerVersionOutput(
            currentTag: version.currentTag,
            endpoint: endpoint,
            error: nil,
            reachable: true
        )
    } catch {
        return ServerVersionOutput(
            currentTag: nil,
            endpoint: endpoint,
            error: String(describing: error),
            reachable: false
        )
    }
}

private func readBody(argument: String?, filePath: String?) throws -> String {
    try validateBodyInputs(argument: argument, filePath: filePath)

    if let body = argument {
        return body
    }

    return try String(
        contentsOf: URL.expandingShellPath(filePath!, isDirectory: false),
        encoding: .utf8
    )
}

private func readPatch(filePath: String) throws -> String {
    let data: Data
    if filePath == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        data = try Data(contentsOf: URL.expandingShellPath(filePath, isDirectory: false))
    }

    guard let patch = String(data: data, encoding: .utf8) else {
        throw ValidationError("Patch file must be UTF-8 text.")
    }

    return patch
}

private func validateBodyInputs(argument: String?, filePath: String?) throws {
    switch (argument, filePath) {
    case (.some, nil), (nil, .some):
        return
    case (nil, nil):
        throw ValidationError("Provide a document body argument or --body-file.")
    case (.some, .some):
        throw ValidationError("Use either a body argument or --body-file, not both.")
    }
}

private func parseMetadata(_ pairs: [String]) throws -> [String: String] {
    try pairs.reduce(into: [:]) { metadata, pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw ValidationError("Metadata must use key=value syntax.")
        }

        metadata[String(parts[0])] = String(parts[1])
    }
}

private func makeJSONEncoder() -> JSONEncoder {
    MetaBrainJSON.encoder()
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let data = try makeJSONEncoder().encode(value)
    print(String(decoding: data, as: UTF8.self))
}

private func printJSONLine<T: Encodable>(_ value: T) throws {
    try printJSON(value)
}

private func printJSONLines<T: Encodable>(_ entries: [T]) throws {
    let encoder = makeJSONEncoder()
    for entry in entries {
        let data = try encoder.encode(entry)
        print(String(decoding: data, as: UTF8.self))
    }
}

private func validateEvidenceBudget(_ maxTokens: Int?) throws {
    if let maxTokens, maxTokens < EvidenceOutput.minimumMaxTokens {
        throw ValidationError("--max-tokens must be at least \(EvidenceOutput.minimumMaxTokens).")
    }
}

private func printEvidenceOutput(_ result: EvidenceOutput, maxTokens: Int) throws {
    var output = try result.jsonData()
    output.append(10)
    guard output.count <= maxTokens else {
        throw ValidationError("Evidence output exceeded --max-tokens \(maxTokens).")
    }
    try FileHandle.standardOutput.write(contentsOf: output)
}

private func printInitializeOutput(_ result: InitializeOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("Initialized metaBrain store at \(result.storePath)")
    case .json:
        try printJSON(result)
    case .jsonl:
        try printJSONLine(result)
    }
}

private func printPutOutput(_ result: PutOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("id: \(result.documentID)")
        print("path: \(result.path)")
        print("version: \(result.version)")
        if result.status == "unchanged" {
            print("status: unchanged")
        }
    case .json:
        try printJSON(result)
    case .jsonl:
        try printJSONLine(result)
    }
}

private func printPatchCheckOutput(_ result: PatchCheckOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("patch applies")
    case .json:
        try printJSON(result)
    case .jsonl:
        try printJSONLine(result)
    }
}

private func printPatchOutput(_ result: PatchOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("id: \(result.documentID)")
        print("path: \(result.path)")
        print("version: \(result.version)")
    case .json:
        try printJSON(result)
    case .jsonl:
        try printJSONLine(result)
    }
}

private func printMoveOutput(_ result: MoveOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("id: \(result.documentID)")
        print("from: \(result.from)")
        print("path: \(result.path)")
        print("version: \(result.version)")
        print("status: \(result.status)")
    case .json:
        try printJSON(result)
    case .jsonl:
        try printJSONLine(result)
    }
}

private func printGetOutput(_ result: GetOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        printDocumentOutput(result)
    case .json:
        try printJSON(result)
    case .jsonl:
        try printJSONLine(result)
    }
}

private func printDocumentOutput(_ document: GetOutput) {
    print("id: \(document.documentID)")
    print("path: \(document.path)")
    if let title = document.title {
        print("title: \(title)")
    }
    print("version: \(document.version)")
    if !document.tags.isEmpty {
        print("tags: \(document.tags.joined(separator: ", "))")
    }
    if !document.metadata.isEmpty {
        let metadata = document.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        print("metadata: \(metadata)")
    }
    if !document.references.isEmpty {
        print("references: \(document.references.map(formatDumpReference).joined(separator: ", "))")
    }
    print("")
    print(document.body)
}

private func printListOutputs(
    _ entries: [ListOutput],
    root: DocumentPath,
    recursive: Bool,
    includeDates: Bool,
    format: CLIOutputFormat
) throws {
    switch format {
    case .text:
        guard !entries.isEmpty else {
            print("No documents.")
            return
        }

        for entry in entries {
            print(formatListEntry(entry, relativeTo: root, recursive: recursive, includeDates: includeDates))
        }
    case .json:
        try printJSON(entries)
    case .jsonl:
        try printJSONLines(entries)
    }
}

private func printTreeOutputs(
    _ entries: [TreeOutput],
    root: DocumentPath,
    maxDepth: Int?,
    format: CLIOutputFormat
) throws {
    switch format {
    case .text:
        if entries.isEmpty, maxDepth != 0 {
            print("No documents.")
            return
        }

        printTree(root: root, entries: entries.filter { $0.kind == "entry" })
    case .json:
        try printJSON(entries)
    case .jsonl:
        try printJSONLines(entries)
    }
}

private func printSearchOutputs(_ results: [SearchOutput], format: CLIOutputFormat) throws {
    switch format {
    case .text:
        printSearchText(results)
    case .json:
        try printJSON(results)
    case .jsonl:
        try printJSONLines(results)
    }
}

private func printSearchText(_ results: [SearchOutput]) {
    if results.isEmpty {
        print("No results.")
        return
    }

    for result in results {
        print("\(result.path) [\(result.documentID)] score=\(formatScore(result.score)) chunk=\(result.chunkOrdinal)")
        if let title = result.title {
            print("title: \(title)")
        }
        print(trimmedSingleLine(result.snippet))
        if !result.context.isEmpty {
            let ordinals = result.context.map { String($0.ordinal) }.joined(separator: ",")
            print("context: \(ordinals)")
        }
        if !result.linkedDocuments.isEmpty {
            print("linked: \(result.linkedDocuments.map(formatDumpReference).joined(separator: ", "))")
        }
        if !result.backlinks.isEmpty {
            print("backlinks: \(result.backlinks.map(formatDumpReference).joined(separator: ", "))")
        }
        print("")
    }
}

private func printDumpOutputs(_ entries: [DumpOutput], format: CLIOutputFormat) throws {
    switch format {
    case .text, .jsonl:
        try printJSONLines(entries)
    case .json:
        try printJSON(entries)
    }
}

private func printVersionsOutputs(_ versions: [VersionsOutput], format: CLIOutputFormat) throws {
    switch format {
    case .text:
        if versions.isEmpty {
            print("No versions.")
            return
        }

        for version in versions {
            print("\(version.sequence) \(version.createdAt.ISO8601Format()) path=\(version.path) pinned=\(version.isPinned)")
        }
    case .json:
        try printJSON(versions)
    case .jsonl:
        try printJSONLines(versions)
    }
}

private func printPruneOutput(_ result: PruneOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("pruned: \(result.prunedVersionCount)")
        print("retained: \(result.retainedVersionCount)")
    case .json, .jsonl:
        try printJSONLine(result)
    }
}

private func printDeleteOutput(_ result: DeleteOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("deleted: \(result.deleted)")
        print("reference: \(result.reference)")
    case .json, .jsonl:
        try printJSONLine(result)
    }
}

private func printRemoveVersionOutput(_ result: RemoveVersionOutput, format: CLIOutputFormat) throws {
    switch format {
    case .text:
        print("removed: \(result.removed)")
        print("sequence: \(result.sequence)")
        print("reference: \(result.reference)")
    case .json, .jsonl:
        try printJSONLine(result)
    }
}

private func formatListEntry(
    _ entry: ListOutput,
    relativeTo root: DocumentPath,
    recursive: Bool,
    includeDates: Bool
) -> String {
    var output = recursive ? relativePath(entry.path, from: root.rawValue) : entry.name
    if entry.hasChildren {
        output += "/"
    }

    if includeDates,
       entry.documentID != nil,
       let createdAt = entry.createdAt,
       let updatedAt = entry.updatedAt {
        output += "  created=\(createdAt.ISO8601Format())  updated=\(updatedAt.ISO8601Format())"
    }

    return output
}

private func relativePath(_ path: String, from root: String) -> String {
    if root == "/" {
        return String(path.dropFirst())
    }

    let prefix = root + "/"
    return String(path.dropFirst(prefix.count))
}

private func treeOutputs(
    root: DocumentPath,
    entries: [DocumentTreeEntry],
    maxDepth: Int?
) -> [TreeOutput] {
    guard !entries.isEmpty || maxDepth == 0 else {
        return []
    }

    return [TreeOutput(root: root, hasChildren: !entries.isEmpty)] + entries.map(TreeOutput.init)
}

private func printTree(root: DocumentPath, entries: [TreeOutput]) {
    print(root.rawValue == "/" ? "/" : root.name + "/")

    let grouped = Dictionary(grouping: entries) { entry in
        parentPath(of: entry.path)
    }
    printTreeChildren(
        of: root.rawValue,
        groupedByParent: grouped,
        prefix: ""
    )
}

private func printTreeChildren(
    of parent: String,
    groupedByParent: [String: [TreeOutput]],
    prefix: String
) {
    let children = (groupedByParent[parent] ?? [])
        .sorted { $0.path < $1.path }

    for (index, child) in children.enumerated() {
        let isLast = index == children.index(before: children.endIndex)
        let connector = isLast ? "`-- " : "|-- "
        print(prefix + connector + formatTreeEntry(child))

        if child.hasChildren {
            printTreeChildren(
                of: child.path,
                groupedByParent: groupedByParent,
                prefix: prefix + (isLast ? "    " : "|   ")
            )
        }
    }
}

private func formatTreeEntry(_ entry: TreeOutput) -> String {
    entry.name + (entry.hasChildren ? "/" : "")
}

private func parentPath(of path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().path
}

private func parseReferences(
    ids: [String],
    paths: [String],
    urls: [String]
) throws -> [DocumentReference] {
    try ids.map { .documentID(try DocumentID(rawValue: $0)) }
        + paths.map { .path(try DocumentPath($0)) }
        + urls.map { rawURL in
            guard let url = URL(string: rawURL), url.scheme != nil else {
                throw ValidationError("Reference URLs must be absolute URLs.")
            }

            return .externalURL(url)
        }
}

private func writeDumpOutputs(_ outputs: [DumpOutput], to outputDirectory: String) throws -> [DumpOutput] {
    let entries = try outputs.map(documentDumpEntry)
    return try DocumentDumpFileWriter()
        .write(entries, to: URL.expandingShellPath(outputDirectory, isDirectory: true))
        .map(DumpOutput.init)
}

private func documentDumpEntry(_ output: DumpOutput) throws -> DocumentDumpEntry {
    try DocumentDumpEntry(
        documentID: DocumentID(rawValue: output.documentID),
        path: DocumentPath(output.path),
        title: output.title,
        body: output.body,
        version: output.version,
        versionCreatedAt: output.versionCreatedAt,
        isCurrent: output.isCurrent,
        tags: output.tags,
        metadata: output.metadata,
        references: output.references,
        markdown: output.markdown
    )
}

private func trimmedSingleLine(_ text: String) -> String {
    let trimmed = text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard trimmed.count > 240 else {
        return trimmed
    }

    return String(trimmed.prefix(237)) + "..."
}

private func formatScore(_ score: Double) -> String {
    String(format: "%.2f", score)
}

private func formatReference(_ reference: DocumentReference) -> String {
    DocumentDumpReference(reference).value
}

private func formatDumpReference(_ reference: DocumentDumpReference) -> String {
    reference.value
}

private func currentSoftwareTag() -> String {
    MetaBrainVersion.currentSoftwareTag()
}

private let daemonBackedCommands: Set<String> = [
    "init",
    "ensure-guide",
    "put",
    "patch",
    "operation",
    "move",
    "get",
    "links",
    "lint",
    "list",
    "tree",
    "search",
    "recall",
    "dump",
    "versions",
    "prune",
    "delete",
    "remove-version",
    "version",
]

private func cliArgumentsWithGlobalOptions(_ arguments: [String]) -> [String] {
    var index = 0
    var hasStoreOption = false

    while index < arguments.count {
        let argument = arguments[index]
        let option = argument.prefix(while: { $0 != "=" })
        switch option {
        case "--store", "--server":
            hasStoreOption = hasStoreOption || option == "--store"
            index += option.count == argument.count ? 2 : 1
        case "--no-server":
            index += 1
        default:
            guard index > 0, daemonBackedCommands.contains(argument),
                  !hasStoreOption || argument != "version" else {
                return arguments
            }
            return [argument] + arguments[..<index] + arguments[(index + 1)...]
        }
    }

    return arguments
}

extension URL {
    static func expandingShellPath(_ path: String, isDirectory: Bool) -> URL {
        let homeDirectory = ProcessInfo.processInfo.environment["METABRAIN_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let expandedPath: String
        if path == "~" {
            expandedPath = homeDirectory.path
        } else if path.hasPrefix("~/") {
            expandedPath = homeDirectory
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expandedPath = path
        }

        return URL(fileURLWithPath: expandedPath, isDirectory: isDirectory)
    }
}
