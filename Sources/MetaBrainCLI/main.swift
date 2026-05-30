import ArgumentParser
import Foundation
import MetaBrainCore
import MetaBrainServerSupport

@main
enum MetaBrainCommandMain {
    static func main() async {
        await MetaBrainCommand.main(cliArgumentsWithGlobalServer(Array(CommandLine.arguments.dropFirst())))
    }
}

struct MetaBrainCommand: AsyncParsableCommand {
    private static let agentDiscoveryGuide = """
        metaBrain is a local document memory for agents and tools. Use it to keep
        durable notes, source snippets, task context, metadata, tags, and links in a
        searchable store instead of scattering scratch files across a workspace.

        Agent discovery:
          mb
          mb help
          mb --help
          mb help list
          mb help tree
          mb help search
          mb help dump
          mb help move
          mb help delete
          mb help remove-version
          mb help version

        Common workflow:
          mb version
          mb init --store .metabrain/store.leveldb
          mb put /notes/today "Important context" --tag planning --meta source=agent
          mb patch /notes/today --patch-file change.diff
          mb move /notes/today /notes/archive/today
          mb list
          mb list /notes --recursive --dates
          mb tree --max-depth 2
          mb search "Important context" --tag planning
          mb get /notes/today
          mb dump /notes --output-dir ./metabrain-dump
          mb delete /notes/today
          mb remove-version /notes/today --sequence 1

        The default store is .metabrain/store.leveldb. Pass --store to any command
        when a workspace uses a different location. Pass --server to any store-backed
        command, or before the command name, to talk to an explicit local daemon.
        """

    static let configuration = CommandConfiguration(
        commandName: "mb",
        abstract: "Inspect and update a metaBrain document store.",
        discussion: agentDiscoveryGuide,
        subcommands: [
            Help.self,
            Initialize.self,
            Put.self,
            Patch.self,
            Move.self,
            Get.self,
            List.self,
            Tree.self,
            Search.self,
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
    @Option(help: "Path to the LevelDB-backed metaBrain store.")
    var store: String = ".metabrain/store.leveldb"

    @Option(help: "Unix socket path, or loopback HTTP URL such as http://127.0.0.1:6374, for explicit daemon mode.")
    var server: String?

    func serverClient() -> MetaBrainServerClient? {
        server.map { MetaBrainServerClient(socketPath: $0) }
    }

    func openStore() throws -> MetaBrainStore {
        let url = URL.expandingShellPath(store, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try MetaBrainStore(url: url)
    }

    func withOpenStore<Result: Sendable>(
        _ operation: (MetaBrainStore) async throws -> Result
    ) async throws -> Result {
        let store = try openStore()

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

    func validate() throws {
        _ = try reference()
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
            abstract: "Show metaBrain CLI help."
        )

        @Argument(help: "Optional command to inspect: init, put, patch, move, get, list, tree, search, dump, versions, prune, delete, remove-version, or version.")
        var command: String?

        func validate() throws {
            guard let command else {
                return
            }

            switch command {
            case "init", "put", "patch", "move", "get", "list", "tree", "search", "dump", "versions", "prune", "delete", "remove-version", "version":
                return
            default:
                throw ValidationError("Unknown help topic '\(command)'. Use one of: init, put, patch, move, get, list, tree, search, dump, versions, prune, delete, remove-version, version.")
            }
        }

        func run() async throws {
            print(commandHelpMessage(for: command))
        }
    }

    struct Initialize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Create or open a metaBrain store."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var output: OutputFormatOptions

        func run() async throws {
            if let client = storeOptions.serverClient() {
                let result: InitializeOutput = try client.post("/v1/init", response: InitializeOutput.self)
                try printInitializeOutput(result, format: output.format)
                return
            }

            try await storeOptions.withOpenStore { store in
                let result = InitializeOutput(
                    operation: "init",
                    status: "initialized",
                    storePath: store.url.path
                )
                try printInitializeOutput(result, format: output.format)
            }
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

        func validate() throws {
            try validateBodyInputs(argument: body, filePath: bodyFile)
            _ = try retention.optionalPolicy()
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

            if let client = storeOptions.serverClient() {
                let result: PutOutput = try client.post(
                    "/v1/put",
                    request: ServerPutRequest(
                        path: path,
                        body: documentBody,
                        title: title,
                        tags: tags,
                        metadata: metadata,
                        references: documentReferences.map(DocumentReferenceDTO.init),
                        retention: retentionPolicy.map(DocumentRetentionPolicyDTO.init)
                    ),
                    response: PutOutput.self
                )
                try printPutOutput(result, format: output.format)
                return
            }

            let input = DocumentInput(
                path: try DocumentPath(path),
                title: title,
                body: documentBody,
                tags: tags,
                metadata: metadata,
                references: documentReferences,
                retention: retentionPolicy
            )
            let document = try await storeOptions.withOpenStore { store in
                try await store.putDocument(input)
            }
            try printPutOutput(
                PutOutput(
                    documentID: document.id.rawValue,
                    path: document.path.rawValue,
                    status: document.currentVersion == 1 ? "created" : "updated",
                    version: document.currentVersion
                ),
                format: output.format
            )
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
            try referenceOptions.validate()
            _ = try retention.optionalPolicy()
        }

        func run() async throws {
            let reference = try referenceOptions.reference()
            let patchText = try readPatch(filePath: patchFile)
            let retentionPolicy = try retention.optionalPolicy()

            if let client = storeOptions.serverClient() {
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

            if let client = storeOptions.serverClient() {
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
            abstract: "Read a document by path or ID."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions
        @OptionGroup var output: OutputFormatOptions

        func run() async throws {
            if let client = storeOptions.serverClient() {
                let result: GetOutput = try client.post(
                    "/v1/get",
                    request: ServerGetRequest(reference: DocumentReferenceDTO(try referenceOptions.reference())),
                    response: GetOutput.self
                )
                try printGetOutput(result, format: output.format)
                return
            }

            let document = try await storeOptions.withOpenStore { store in
                try await store.getDocument(referenceOptions.reference())
            }

            guard let document else {
                throw ValidationError("Document not found.")
            }

            try printGetOutput(GetOutput(document), format: output.format)
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

            if let client = storeOptions.serverClient() {
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

            if let client = storeOptions.serverClient() {
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
            abstract: "Search current document content."
        )

        @OptionGroup var storeOptions: StoreOptions

        @Argument(help: "Search text.")
        var query: String

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

        @OptionGroup var output: ListOutputFormatOptions

        func validate() throws {
            if limit <= 0 {
                throw ValidationError("--limit must be greater than zero.")
            }
            _ = try pathPrefix.map(DocumentPath.init)
            _ = try parseMetadata(metadataPairs)
        }

        func run() async throws {
            let searchQuery = SearchQuery(
                text: query,
                pathPrefix: try pathPrefix.map(DocumentPath.init),
                tags: tags,
                metadata: try parseMetadata(metadataPairs),
                includeLinkedDocuments: includeLinkedDocuments,
                includeBacklinks: includeBacklinks,
                limit: limit
            )
            let outputResults: [SearchOutput]

            if let client = storeOptions.serverClient() {
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

            try printSearchOutputs(outputResults, format: output.format)
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

            if let client = storeOptions.serverClient() {
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

        func run() async throws {
            let outputVersions: [VersionsOutput]

            if let client = storeOptions.serverClient() {
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
            try referenceOptions.validate()
            _ = try retention.requiredPolicy()
        }

        func run() async throws {
            let request = PruneRequest(
                reference: try referenceOptions.reference(),
                policy: try retention.requiredPolicy()
            )

            if let client = storeOptions.serverClient() {
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
            try referenceOptions.validate()
        }

        func run() async throws {
            let reference = try referenceOptions.reference()
            let formattedReference = formatReference(reference)

            if let client = storeOptions.serverClient() {
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
            try referenceOptions.validate()
            guard sequence > 0 else {
                throw ValidationError("--sequence must be greater than zero.")
            }
        }

        func run() async throws {
            let reference = try referenceOptions.reference()
            let formattedReference = formatReference(reference)

            if let client = storeOptions.serverClient() {
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
            abstract: "Print the metaBrain version and check GitHub releases."
        )

        @OptionGroup var output: TextOutputFormatOptions

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
                releaseCheck: releaseCheck
            )

            switch output.format {
            case .text:
                print("version: \(currentTag)")
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
        references: output.references
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

private func commandHelpMessage(for command: String?) -> String {
    guard let command else {
        return MetaBrainCommand.helpMessage()
    }

        return [
            "init": MetaBrainCommand.Initialize.helpMessage(),
            "put": MetaBrainCommand.Put.helpMessage(),
            "patch": MetaBrainCommand.Patch.helpMessage(),
            "move": MetaBrainCommand.Move.helpMessage(),
            "get": MetaBrainCommand.Get.helpMessage(),
            "list": MetaBrainCommand.List.helpMessage(),
            "tree": MetaBrainCommand.Tree.helpMessage(),
            "search": MetaBrainCommand.Search.helpMessage(),
            "dump": MetaBrainCommand.Dump.helpMessage(),
            "versions": MetaBrainCommand.Versions.helpMessage(),
            "prune": MetaBrainCommand.Prune.helpMessage(),
            "delete": MetaBrainCommand.Delete.helpMessage(),
            "remove-version": MetaBrainCommand.RemoveVersion.helpMessage(),
            "version": MetaBrainCommand.Version.helpMessage()
    ][command]!
}

private func currentSoftwareTag() -> String {
    MetaBrainVersion.currentSoftwareTag()
}

private let daemonBackedCommands: Set<String> = [
    "init",
    "put",
    "patch",
    "move",
    "get",
    "list",
    "tree",
    "search",
    "dump",
    "versions",
    "prune",
    "delete",
    "remove-version",
]

private func cliArgumentsWithGlobalServer(_ arguments: [String]) -> [String] {
    var result = arguments
    guard let optionIndex = result.firstIndex(of: "--server"), optionIndex + 1 < result.endIndex else {
        return result
    }

    let server = result.remove(at: optionIndex + 1)
    result.remove(at: optionIndex)
    guard let commandIndex = result.firstIndex(where: { daemonBackedCommands.contains($0) }) else {
        return result
    }

    result.insert(contentsOf: ["--server", server], at: commandIndex + 1)
    return result
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
