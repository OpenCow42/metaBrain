import ArgumentParser
import Foundation
import MetaBrainCore

@main
struct MetaBrainCommand: AsyncParsableCommand {
    private static let agentDiscoveryGuide = """
        metaBrain is a local document memory for agents and tools. Use it to keep
        durable notes, source snippets, task context, metadata, tags, and links in a
        searchable store instead of scattering scratch files across a workspace.

        Agent discovery:
          metabrain
          metabrain help
          metabrain --help
          metabrain help list
          metabrain help tree
          metabrain help search
          metabrain help dump
          metabrain help delete
          metabrain help remove-version

        Common workflow:
          metabrain init --store .metabrain/store.leveldb
          metabrain put /notes/today "Important context" --tag planning --meta source=agent
          metabrain patch /notes/today --patch-file change.diff
          metabrain list
          metabrain list /notes --recursive --dates
          metabrain tree --max-depth 2
          metabrain search "Important context" --tag planning
          metabrain get /notes/today
          metabrain dump /notes --output-dir ./metabrain-dump
          metabrain delete /notes/today
          metabrain remove-version /notes/today --sequence 1

        The default store is .metabrain/store.leveldb. Pass --store to any command
        when a workspace uses a different location.
        """

    static let configuration = CommandConfiguration(
        commandName: "metabrain",
        abstract: "Inspect and update a metaBrain document store.",
        discussion: agentDiscoveryGuide,
        subcommands: [
            Help.self,
            Initialize.self,
            Put.self,
            Patch.self,
            Get.self,
            List.self,
            Tree.self,
            Search.self,
            Dump.self,
            Versions.self,
            Prune.self,
            Delete.self,
            RemoveVersion.self
        ]
    )

    func run() async throws {
        print(Self.helpMessage())
    }
}

struct StoreOptions: ParsableArguments {
    @Option(help: "Path to the LevelDB-backed metaBrain store.")
    var store: String = ".metabrain/store.leveldb"

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

        @Argument(help: "Optional command to inspect: init, put, patch, get, list, tree, search, dump, versions, prune, delete, or remove-version.")
        var command: String?

        func validate() throws {
            guard let command else {
                return
            }

            switch command {
            case "init", "put", "patch", "get", "list", "tree", "search", "dump", "versions", "prune", "delete", "remove-version":
                return
            default:
                throw ValidationError("Unknown help topic '\(command)'. Use one of: init, put, patch, get, list, tree, search, dump, versions, prune, delete, remove-version.")
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
            try await storeOptions.withOpenStore { store in
                let result = InitializeOutput(
                    operation: "init",
                    status: "initialized",
                    storePath: store.url.path
                )

                switch output.format {
                case .text:
                    print("Initialized metaBrain store at \(store.url.path)")
                case .json:
                    try printJSON(result)
                case .jsonl:
                    try printJSONLine(result)
                }
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
            let input = DocumentInput(
                path: try DocumentPath(path),
                title: title,
                body: documentBody,
                tags: tags,
                metadata: try parseMetadata(metadataPairs),
                references: try parseReferences(
                    ids: referenceIDs,
                    paths: referencePaths,
                    urls: referenceURLs
                ),
                retention: try retention.optionalPolicy()
            )
            let document = try await storeOptions.withOpenStore { store in
                try await store.putDocument(input)
            }
            let result = PutOutput(
                documentID: document.id.rawValue,
                operation: "put",
                path: document.path.rawValue,
                status: document.currentVersion == 1 ? "created" : "updated",
                version: document.currentVersion
            )

            switch output.format {
            case .text:
                print("id: \(document.id.rawValue)")
                print("path: \(document.path.rawValue)")
                print("version: \(document.currentVersion)")
            case .json:
                try printJSON(result)
            case .jsonl:
                try printJSONLine(result)
            }
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
            let request = DocumentPatchRequest(
                reference: try referenceOptions.reference(),
                unifiedDiff: try readPatch(filePath: patchFile),
                retention: try retention.optionalPolicy()
            )

            try await storeOptions.withOpenStore { store in
                if check {
                    try await store.checkDocumentPatch(request)
                    let result = PatchCheckOutput(
                        check: true,
                        operation: "patch",
                        status: "applies",
                        success: true
                    )

                    switch output.format {
                    case .text:
                        print("patch applies")
                    case .json:
                        try printJSON(result)
                    case .jsonl:
                        try printJSONLine(result)
                    }
                    return
                }

                let document = try await store.patchDocument(request)
                let result = PatchOutput(
                    documentID: document.id.rawValue,
                    operation: "patch",
                    path: document.path.rawValue,
                    status: "patched",
                    version: document.currentVersion
                )

                switch output.format {
                case .text:
                    print("id: \(document.id.rawValue)")
                    print("path: \(document.path.rawValue)")
                    print("version: \(document.currentVersion)")
                case .json:
                    try printJSON(result)
                case .jsonl:
                    try printJSONLine(result)
                }
            }
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
            let document = try await storeOptions.withOpenStore { store in
                try await store.getDocument(referenceOptions.reference())
            }

            guard let document else {
                throw ValidationError("Document not found.")
            }

            switch output.format {
            case .text:
                printDocument(document)
            case .json:
                try printJSON(GetOutput(document))
            case .jsonl:
                try printJSONLine(GetOutput(document))
            }
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
            let entries = try await storeOptions.withOpenStore { store in
                try await store.listDirectory(
                    path: root,
                    recursive: recursive,
                    directoriesOnly: directoriesOnly
                )
            }

            let outputEntries = entries.map(ListOutput.init)

            switch output.format {
            case .text:
                guard !entries.isEmpty else {
                    print("No documents.")
                    return
                }

                for entry in entries {
                    print(formatListEntry(entry, relativeTo: root, recursive: recursive, includeDates: dates))
                }
            case .json:
                try printJSON(outputEntries)
            case .jsonl:
                try printJSONLines(outputEntries)
            }
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
            let entries = try await storeOptions.withOpenStore { store in
                try await store.tree(TreeQuery(
                    path: root,
                    directoriesOnly: directoriesOnly,
                    maxDepth: maxDepth
                ))
            }

            switch output.format {
            case .text:
                if entries.isEmpty, maxDepth != 0 {
                    print("No documents.")
                    return
                }

                printTree(root: root, entries: entries)
            case .json:
                try printJSON(treeOutputs(root: root, entries: entries, maxDepth: maxDepth))
            case .jsonl:
                try printJSONLines(treeOutputs(root: root, entries: entries, maxDepth: maxDepth))
            }
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
            let results = try await storeOptions.withOpenStore { store in
                try await store.search(searchQuery)
            }
            let outputResults = results.map(SearchOutput.init)

            switch output.format {
            case .text:
                printSearchResults(results)
            case .json:
                try printJSON(outputResults)
            case .jsonl:
                try printJSONLines(outputResults)
            }
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
            let entries = try await storeOptions.withOpenStore { store in
                try await store.dump(query)
            }
            let outputEntries: [DocumentDumpEntry]
            if let outputDirectory {
                outputEntries = try DocumentDumpFileWriter().write(
                    entries,
                    to: URL.expandingShellPath(outputDirectory, isDirectory: true)
                )
            } else {
                outputEntries = entries
            }

            let dumpOutputs = outputEntries.map(DumpOutput.init)

            switch output.format {
            case .text, .jsonl:
                try printJSONLines(dumpOutputs)
            case .json:
                try printJSON(dumpOutputs)
            }
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
            let versions = try await storeOptions.withOpenStore { store in
                try await store.listVersions(of: referenceOptions.reference())
            }
            let outputVersions = versions.map(VersionsOutput.init)

            switch output.format {
            case .text:
                if versions.isEmpty {
                    print("No versions.")
                    return
                }

                for version in versions {
                    print("\(version.sequence) \(version.createdAt.ISO8601Format()) path=\(version.snapshot.path.rawValue) pinned=\(version.isPinned)")
                }
            case .json:
                try printJSON(outputVersions)
            case .jsonl:
                try printJSONLines(outputVersions)
            }
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
            let result = try await storeOptions.withOpenStore { store in
                try await store.prune(request)
            }

            let outputResult = PruneOutput(result)
            switch output.format {
            case .text:
                print("pruned: \(result.prunedVersionCount)")
                print("retained: \(result.retainedVersionCount)")
            case .json, .jsonl:
                try printJSONLine(outputResult)
            }
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
            let deleted = try await storeOptions.withOpenStore { store in
                try await store.deleteDocument(reference)
            }
            let result = DeleteOutput(reference: formattedReference, deleted: deleted)

            switch output.format {
            case .text:
                print("deleted: \(deleted)")
                print("reference: \(formattedReference)")
            case .json, .jsonl:
                try printJSONLine(result)
            }
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

            switch output.format {
            case .text:
                print("removed: \(removed)")
                print("sequence: \(sequence)")
                print("reference: \(formattedReference)")
            case .json, .jsonl:
                try printJSONLine(result)
            }
        }
    }
}

private struct InitializeOutput: Encodable {
    let operation: String
    let status: String
    let storePath: String
}

private struct PutOutput: Encodable {
    let documentID: String
    let operation: String
    let path: String
    let status: String
    let version: UInt64
}

private struct PatchOutput: Encodable {
    let documentID: String
    let operation: String
    let path: String
    let status: String
    let version: UInt64
}

private struct PatchCheckOutput: Encodable {
    let check: Bool
    let operation: String
    let status: String
    let success: Bool
}

private struct PruneOutput: Encodable {
    let operation: String
    let prunedVersionCount: Int
    let retainedVersionCount: Int
    let status: String

    init(_ result: PruneResult) {
        operation = "prune"
        prunedVersionCount = result.prunedVersionCount
        retainedVersionCount = result.retainedVersionCount
        status = "completed"
    }
}

private struct DeleteOutput: Encodable {
    let deleted: Bool
    let operation: String
    let reference: String
    let status: String

    init(reference: String, deleted: Bool) {
        self.deleted = deleted
        operation = "delete"
        self.reference = reference
        status = "completed"
    }
}

private struct RemoveVersionOutput: Encodable {
    let operation: String
    let reference: String
    let removed: Bool
    let sequence: UInt64
    let status: String

    init(reference: String, removed: Bool, sequence: UInt64) {
        operation = "remove-version"
        self.reference = reference
        self.removed = removed
        self.sequence = sequence
        status = "completed"
    }
}

private struct GetOutput: Encodable {
    let body: String
    let createdAt: Date
    let documentID: String
    let metadata: [String: String]
    let path: String
    let references: [DocumentDumpReference]
    let tags: [String]
    let title: String?
    let updatedAt: Date
    let version: UInt64

    init(_ document: StoredDocument) {
        body = document.body
        createdAt = document.createdAt
        documentID = document.id.rawValue
        metadata = document.metadata
        path = document.path.rawValue
        references = document.references.map(DocumentDumpReference.init)
        tags = document.tags
        title = document.title
        updatedAt = document.updatedAt
        version = document.currentVersion
    }

    private enum CodingKeys: String, CodingKey {
        case body
        case createdAt
        case documentID
        case metadata
        case path
        case references
        case tags
        case title
        case updatedAt
        case version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body, forKey: .body)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(path, forKey: .path)
        try container.encode(references, forKey: .references)
        try container.encode(tags, forKey: .tags)
        try container.encode(title, forKey: .title)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(version, forKey: .version)
    }
}

private struct ListOutput: Encodable {
    let path: String
    let name: String
    let hasChildren: Bool
    let documentID: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(_ entry: DocumentTreeEntry) {
        path = entry.path.rawValue
        name = entry.name
        hasChildren = entry.hasChildren
        documentID = entry.documentID?.rawValue
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }
}

private struct TreeOutput: Encodable {
    let path: String
    let name: String
    let hasChildren: Bool
    let documentID: String?
    let createdAt: Date?
    let updatedAt: Date?
    let kind: String

    enum CodingKeys: String, CodingKey {
        case createdAt
        case documentID
        case hasChildren
        case kind
        case name
        case path
        case updatedAt
    }

    init(root: DocumentPath, hasChildren: Bool) {
        path = root.rawValue
        name = treeRootName(root)
        self.hasChildren = hasChildren
        documentID = nil
        createdAt = nil
        updatedAt = nil
        kind = "root"
    }

    init(_ entry: DocumentTreeEntry) {
        path = entry.path.rawValue
        name = entry.name
        hasChildren = entry.hasChildren
        documentID = entry.documentID?.rawValue
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        kind = "entry"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(hasChildren, forKey: .hasChildren)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

private struct SearchOutput: Encodable {
    let backlinks: [DocumentDumpReference]
    let chunkOrdinal: UInt32
    let context: [SearchContextChunk]
    let documentID: String
    let linkedDocuments: [DocumentDumpReference]
    let path: String
    let score: Double
    let snippet: String
    let title: String?

    init(_ result: SearchResult) {
        backlinks = result.backlinks.map(DocumentDumpReference.init)
        chunkOrdinal = result.chunkOrdinal
        context = result.context
        documentID = result.documentID.rawValue
        linkedDocuments = result.linkedDocuments.map(DocumentDumpReference.init)
        path = result.path.rawValue
        score = result.score
        snippet = result.snippet
        title = result.title
    }

    private enum CodingKeys: String, CodingKey {
        case backlinks
        case chunkOrdinal
        case context
        case documentID
        case linkedDocuments
        case path
        case score
        case snippet
        case title
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backlinks, forKey: .backlinks)
        try container.encode(chunkOrdinal, forKey: .chunkOrdinal)
        try container.encode(context, forKey: .context)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(linkedDocuments, forKey: .linkedDocuments)
        try container.encode(path, forKey: .path)
        try container.encode(score, forKey: .score)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(title, forKey: .title)
    }
}

private struct DumpOutput: Encodable {
    let body: String
    let bodyCharacterCount: Int
    let bodyUTF8ByteCount: Int
    let documentID: String
    let fileSystemPath: String?
    let isCurrent: Bool
    let metadata: [String: String]
    let path: String
    let references: [DocumentDumpReference]
    let tags: [String]
    let title: String?
    let version: UInt64
    let versionCreatedAt: Date

    init(_ entry: DocumentDumpEntry) {
        body = entry.body
        bodyCharacterCount = entry.bodyCharacterCount
        bodyUTF8ByteCount = entry.bodyUTF8ByteCount
        documentID = entry.documentID.rawValue
        fileSystemPath = entry.fileSystemPath
        isCurrent = entry.isCurrent
        metadata = entry.metadata
        path = entry.path.rawValue
        references = entry.references
        tags = entry.tags
        title = entry.title
        version = entry.version
        versionCreatedAt = entry.versionCreatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case body
        case bodyCharacterCount
        case bodyUTF8ByteCount
        case documentID
        case fileSystemPath
        case isCurrent
        case metadata
        case path
        case references
        case tags
        case title
        case version
        case versionCreatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body, forKey: .body)
        try container.encode(bodyCharacterCount, forKey: .bodyCharacterCount)
        try container.encode(bodyUTF8ByteCount, forKey: .bodyUTF8ByteCount)
        try container.encode(documentID, forKey: .documentID)
        try container.encodeIfPresent(fileSystemPath, forKey: .fileSystemPath)
        try container.encode(isCurrent, forKey: .isCurrent)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(path, forKey: .path)
        try container.encode(references, forKey: .references)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(version, forKey: .version)
        try container.encode(versionCreatedAt, forKey: .versionCreatedAt)
    }
}

private struct VersionsOutput: Encodable {
    let createdAt: Date
    let documentID: String
    let isPinned: Bool
    let path: String
    let sequence: UInt64

    init(_ version: DocumentVersion) {
        createdAt = version.createdAt
        documentID = version.documentID.rawValue
        isPinned = version.isPinned
        path = version.snapshot.path.rawValue
        sequence = version.sequence
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
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
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

private func printDocument(_ document: StoredDocument) {
    print("id: \(document.id.rawValue)")
    print("path: \(document.path.rawValue)")
    if let title = document.title {
        print("title: \(title)")
    }
    print("version: \(document.currentVersion)")
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
        print("references: \(document.references.map(formatReference).joined(separator: ", "))")
    }
    print("")
    print(document.body)
}

private func printSearchResults(_ results: [SearchResult]) {
    if results.isEmpty {
        print("No results.")
        return
    }

    for result in results {
        print("\(result.path.rawValue) [\(result.documentID.rawValue)] score=\(formatScore(result.score)) chunk=\(result.chunkOrdinal)")
        if let title = result.title {
            print("title: \(title)")
        }
        print(trimmedSingleLine(result.snippet))
        if !result.context.isEmpty {
            let ordinals = result.context.map { String($0.ordinal) }.joined(separator: ",")
            print("context: \(ordinals)")
        }
        if !result.linkedDocuments.isEmpty {
            print("linked: \(result.linkedDocuments.map(formatReference).joined(separator: ", "))")
        }
        if !result.backlinks.isEmpty {
            print("backlinks: \(result.backlinks.map(formatReference).joined(separator: ", "))")
        }
        print("")
    }
}

private func formatListEntry(
    _ entry: DocumentTreeEntry,
    relativeTo root: DocumentPath,
    recursive: Bool,
    includeDates: Bool
) -> String {
    var output = recursive ? relativePath(entry.path, from: root) : entry.name
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

private func relativePath(_ path: DocumentPath, from root: DocumentPath) -> String {
    if root.rawValue == "/" {
        return String(path.rawValue.dropFirst())
    }

    let prefix = root.rawValue + "/"
    return String(path.rawValue.dropFirst(prefix.count))
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

private func printTree(root: DocumentPath, entries: [DocumentTreeEntry]) {
    print(root.rawValue == "/" ? "/" : root.name + "/")

    let grouped = Dictionary(grouping: entries) { entry in
        entry.path.parent!.rawValue
    }
    printTreeChildren(
        of: root,
        groupedByParent: grouped,
        prefix: ""
    )
}

private func printTreeChildren(
    of parent: DocumentPath,
    groupedByParent: [String: [DocumentTreeEntry]],
    prefix: String
) {
    let children = (groupedByParent[parent.rawValue] ?? [])
        .sorted { $0.path.rawValue < $1.path.rawValue }

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

private func formatTreeEntry(_ entry: DocumentTreeEntry) -> String {
    entry.name + (entry.hasChildren ? "/" : "")
}

private func treeRootName(_ root: DocumentPath) -> String {
    root.rawValue == "/" ? "/" : root.name
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
    switch reference {
    case .documentID(let id):
        return id.rawValue
    case .path(let path):
        return path.rawValue
    case .externalURL(let url):
        return url.absoluteString
    }
}

private func commandHelpMessage(for command: String?) -> String {
    guard let command else {
        return MetaBrainCommand.helpMessage()
    }

        return [
            "init": MetaBrainCommand.Initialize.helpMessage(),
            "put": MetaBrainCommand.Put.helpMessage(),
            "patch": MetaBrainCommand.Patch.helpMessage(),
            "get": MetaBrainCommand.Get.helpMessage(),
            "list": MetaBrainCommand.List.helpMessage(),
            "tree": MetaBrainCommand.Tree.helpMessage(),
            "search": MetaBrainCommand.Search.helpMessage(),
            "dump": MetaBrainCommand.Dump.helpMessage(),
            "versions": MetaBrainCommand.Versions.helpMessage(),
            "prune": MetaBrainCommand.Prune.helpMessage(),
            "delete": MetaBrainCommand.Delete.helpMessage(),
            "remove-version": MetaBrainCommand.RemoveVersion.helpMessage()
    ][command]!
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
