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
          metabrain help search

        Common workflow:
          metabrain init --store .metabrain/store.leveldb
          metabrain put /notes/today "Important context" --tag planning --meta source=agent
          metabrain search "Important context" --tag planning
          metabrain get --path /notes/today

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
            Get.self,
            Search.self,
            Versions.self,
            Prune.self
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
}
struct ReferenceOptions: ParsableArguments {
    @Option(help: "Document ID to read.")
    var id: String?

    @Option(help: "Document path to read.")
    var path: String?

    func reference() throws -> DocumentReference {
        switch (id, path) {
        case (.some(let rawID), nil):
            return .documentID(try DocumentID(rawValue: rawID))
        case (nil, .some(let rawPath)):
            return .path(try DocumentPath(rawPath))
        case (nil, nil):
            throw ValidationError("Provide either --id or --path.")
        case (.some, .some):
            throw ValidationError("Use only one of --id or --path.")
        }
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

        @Argument(help: "Optional command to inspect: init, put, get, search, versions, or prune.")
        var command: String?

        func validate() throws {
            guard let command else {
                return
            }

            switch command {
            case "init", "put", "get", "search", "versions", "prune":
                return
            default:
                throw ValidationError("Unknown help topic '\(command)'. Use one of: init, put, get, search, versions, prune.")
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

        func run() async throws {
            let store = try storeOptions.openStore()
            print("Initialized metaBrain store at \(store.url.path)")
        }
    }

    struct Put: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "put",
            abstract: "Create or update a document at a path."
        )

        @OptionGroup var storeOptions: StoreOptions
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
            let document = try await storeOptions.openStore().putDocument(input)

            print("id: \(document.id.rawValue)")
            print("path: \(document.path.rawValue)")
            print("version: \(document.currentVersion)")
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Read a document by path or ID."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions

        func run() async throws {
            guard let document = try await storeOptions.openStore().getDocument(referenceOptions.reference()) else {
                throw ValidationError("Document not found.")
            }

            printDocument(document)
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

        func validate() throws {
            if limit <= 0 {
                throw ValidationError("--limit must be greater than zero.")
            }
            _ = try pathPrefix.map(DocumentPath.init)
            _ = try parseMetadata(metadataPairs)
        }

        func run() async throws {
            let results = try await storeOptions.openStore().search(SearchQuery(
                text: query,
                pathPrefix: try pathPrefix.map(DocumentPath.init),
                tags: tags,
                metadata: try parseMetadata(metadataPairs),
                includeLinkedDocuments: includeLinkedDocuments,
                includeBacklinks: includeBacklinks,
                limit: limit
            ))

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
    }

    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "versions",
            abstract: "List stored versions for a document."
        )

        @OptionGroup var storeOptions: StoreOptions
        @OptionGroup var referenceOptions: ReferenceOptions

        func run() async throws {
            let versions = try await storeOptions.openStore().listVersions(of: referenceOptions.reference())

            if versions.isEmpty {
                print("No versions.")
                return
            }

            for version in versions {
                print("\(version.sequence) \(version.createdAt.ISO8601Format()) path=\(version.snapshot.path.rawValue) pinned=\(version.isPinned)")
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

        func validate() throws {
            try referenceOptions.validate()
            _ = try retention.requiredPolicy()
        }

        func run() async throws {
            let result = try await storeOptions.openStore().prune(PruneRequest(
                reference: try referenceOptions.reference(),
                policy: try retention.requiredPolicy()
            ))

            print("pruned: \(result.prunedVersionCount)")
            print("retained: \(result.retainedVersionCount)")
        }
    }
}

private func readBody(argument: String?, filePath: String?) throws -> String {
    try validateBodyInputs(argument: argument, filePath: filePath)

    switch (argument, filePath) {
    case (.some(let body), nil):
        return body
    case (nil, .some(let filePath)):
        return try String(contentsOf: URL.expandingShellPath(filePath, isDirectory: false), encoding: .utf8)
    case (nil, nil), (.some, .some):
        preconditionFailure("Body input validation should reject missing or duplicate body sources.")
    }
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
    switch command {
    case nil:
        return MetaBrainCommand.helpMessage()
    case "init":
        return MetaBrainCommand.Initialize.helpMessage()
    case "put":
        return MetaBrainCommand.Put.helpMessage()
    case "get":
        return MetaBrainCommand.Get.helpMessage()
    case "search":
        return MetaBrainCommand.Search.helpMessage()
    case "versions":
        return MetaBrainCommand.Versions.helpMessage()
    case "prune":
        return MetaBrainCommand.Prune.helpMessage()
    case .some(let unknown):
        preconditionFailure("Unknown help topic '\(unknown)' should be rejected during validation.")
    }
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
