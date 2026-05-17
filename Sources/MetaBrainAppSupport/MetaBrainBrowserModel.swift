import Combine
import Foundation
import MetaBrainCore

public enum MetaBrainAppSupportError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidMetaBrainFolder(String)
    case missingMetaBrainFolder(String)
    case missingStore(String)
    case noOpenStore
    case missingDocument(String)

    public var description: String {
        switch self {
        case .invalidMetaBrainFolder(let path):
            "Choose a .metabrain folder. Selected: \(path)"
        case .missingMetaBrainFolder(let path):
            "The selected .metabrain folder does not exist: \(path)"
        case .missingStore(let path):
            "No store.leveldb folder was found at \(path)"
        case .noOpenStore:
            "Open a metaBrain database before browsing or searching."
        case .missingDocument(let path):
            "No document exists at \(path)."
        }
    }

    public var errorDescription: String? {
        description
    }
}

public struct MetaBrainStoreLocation: Equatable, Sendable {
    public var metaBrainFolderURL: URL
    public var storeURL: URL

    public init(metaBrainFolderURL: URL, storeURL: URL) {
        self.metaBrainFolderURL = metaBrainFolderURL.standardizedFileURL
        self.storeURL = storeURL.standardizedFileURL
    }

    public static func resolve(
        selectedFolder: URL,
        fileManager: FileManager = .default
    ) throws -> MetaBrainStoreLocation {
        let folderURL = selectedFolder.standardizedFileURL
        guard folderURL.lastPathComponent.lowercased() == ".metabrain" else {
            throw MetaBrainAppSupportError.invalidMetaBrainFolder(folderURL.path)
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MetaBrainAppSupportError.missingMetaBrainFolder(folderURL.path)
        }

        let storeURL = folderURL.appendingPathComponent("store.leveldb", isDirectory: true)
        var storeIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: storeURL.path, isDirectory: &storeIsDirectory),
              storeIsDirectory.boolValue else {
            throw MetaBrainAppSupportError.missingStore(storeURL.path)
        }

        return MetaBrainStoreLocation(metaBrainFolderURL: folderURL, storeURL: storeURL)
    }
}

public protocol MetaBrainStoreClient: Sendable {
    var location: MetaBrainStoreLocation { get }

    func loadTree() async throws -> [DocumentTreeEntry]
    func loadDocument(path: DocumentPath) async throws -> StoredDocument?
    func search(text: String, limit: Int) async throws -> [SearchResult]
}

public final class LiveMetaBrainStoreClient: MetaBrainStoreClient {
    public let location: MetaBrainStoreLocation

    private let store: MetaBrainStore

    public static func open(
        selectedMetaBrainFolder folderURL: URL,
        fileManager: FileManager = .default
    ) throws -> LiveMetaBrainStoreClient {
        let location = try MetaBrainStoreLocation.resolve(
            selectedFolder: folderURL,
            fileManager: fileManager
        )
        let options = MetaBrainStoreOptions(
            createIfMissing: false,
            errorIfExists: false,
            paranoidChecks: true,
            zstdCompressionLevel: 3,
            zstdAdaptiveMinimumSavingsRatio: 0.10,
            lruCacheCapacity: 64 * 1024 * 1024,
            bloomFilterBitsPerKey: 10
        )

        return try LiveMetaBrainStoreClient(
            location: location,
            store: MetaBrainStore(url: location.storeURL, options: options)
        )
    }

    public init(location: MetaBrainStoreLocation, store: MetaBrainStore) {
        self.location = location
        self.store = store
    }

    public func loadTree() async throws -> [DocumentTreeEntry] {
        try await store.tree(TreeQuery())
    }

    public func loadDocument(path: DocumentPath) async throws -> StoredDocument? {
        try await store.getDocument(.path(path))
    }

    public func search(text: String, limit: Int) async throws -> [SearchResult] {
        try await store.search(SearchQuery(text: text, limit: limit))
    }
}

public struct MetaBrainTreeNode: Equatable, Sendable, Identifiable {
    public var id: String {
        path.rawValue
    }

    public var path: DocumentPath
    public var name: String
    public var entryHasChildren: Bool
    public var documentID: DocumentID?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var children: [MetaBrainTreeNode]

    public var isDocument: Bool {
        documentID != nil
    }

    public var isDirectoryOnly: Bool {
        documentID == nil && (!children.isEmpty || entryHasChildren)
    }

    public init(
        path: DocumentPath,
        name: String,
        entryHasChildren: Bool,
        documentID: DocumentID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        children: [MetaBrainTreeNode] = []
    ) {
        self.path = path
        self.name = name
        self.entryHasChildren = entryHasChildren
        self.documentID = documentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.children = children
    }

    public func firstNode(matching path: DocumentPath) -> MetaBrainTreeNode? {
        if self.path == path {
            return self
        }

        for child in children {
            if let match = child.firstNode(matching: path) {
                return match
            }
        }

        return nil
    }
}

public enum MetaBrainTreeBuilder {
    public static func forest(from entries: [DocumentTreeEntry]) -> [MetaBrainTreeNode] {
        let root = MutableTreeNode(path: try! DocumentPath("/"), name: "/", entryHasChildren: true)
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            insert(entry, into: root)
        }

        if root.documentID != nil {
            return [root.makeNode()]
        }

        return root.sortedChildren().map { $0.makeNode() }
    }

    public static func ancestorPathIDs(for path: DocumentPath) -> Set<String> {
        var ids = Set<String>()
        var parent = path.parent

        while let current = parent {
            if current.rawValue != "/" {
                ids.insert(current.rawValue)
            }
            parent = current.parent
        }

        return ids
    }

    public static func firstNode(
        matching path: DocumentPath,
        in nodes: [MetaBrainTreeNode]
    ) -> MetaBrainTreeNode? {
        for node in nodes {
            if let match = node.firstNode(matching: path) {
                return match
            }
        }

        return nil
    }

    private static func insert(_ entry: DocumentTreeEntry, into root: MutableTreeNode) {
        if entry.path.rawValue == "/" {
            root.apply(entry)
            return
        }

        var ancestors: [DocumentPath] = []
        var parent = entry.path.parent
        while let current = parent, current.rawValue != "/" {
            ancestors.append(current)
            parent = current.parent
        }

        var cursor = root
        for ancestor in ancestors.reversed() {
            cursor = cursor.child(
                path: ancestor,
                name: ancestor.name,
                entryHasChildren: true
            )
        }

        cursor.child(
            path: entry.path,
            name: entry.name,
            entryHasChildren: entry.hasChildren
        ).apply(entry)
    }
}

private final class MutableTreeNode {
    var path: DocumentPath
    var name: String
    var entryHasChildren: Bool
    var documentID: DocumentID?
    var createdAt: Date?
    var updatedAt: Date?

    private var children: [String: MutableTreeNode] = [:]

    init(
        path: DocumentPath,
        name: String,
        entryHasChildren: Bool,
        documentID: DocumentID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.entryHasChildren = entryHasChildren
        self.documentID = documentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func child(
        path: DocumentPath,
        name: String,
        entryHasChildren: Bool
    ) -> MutableTreeNode {
        if let existing = children[path.rawValue] {
            existing.entryHasChildren = existing.entryHasChildren || entryHasChildren
            return existing
        }

        let node = MutableTreeNode(
            path: path,
            name: name,
            entryHasChildren: entryHasChildren
        )
        children[path.rawValue] = node
        return node
    }

    func apply(_ entry: DocumentTreeEntry) {
        path = entry.path
        name = entry.name
        entryHasChildren = entryHasChildren || entry.hasChildren
        documentID = entry.documentID
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }

    func sortedChildren() -> [MutableTreeNode] {
        children.values.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.path < rhs.path
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func makeNode() -> MetaBrainTreeNode {
        MetaBrainTreeNode(
            path: path,
            name: name,
            entryHasChildren: entryHasChildren,
            documentID: documentID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            children: sortedChildren().map { $0.makeNode() }
        )
    }
}

public struct DocumentPresentation: Equatable, Sendable, Identifiable {
    public var id: DocumentID
    public var path: DocumentPath
    public var title: String?
    public var body: String
    public var tags: [String]
    public var metadata: [String: String]
    public var currentVersion: UInt64
    public var createdAt: Date
    public var updatedAt: Date

    public init(document: StoredDocument) {
        id = document.id
        path = document.path
        title = document.title
        body = document.body
        tags = document.tags
        metadata = document.metadata
        currentVersion = document.currentVersion
        createdAt = document.createdAt
        updatedAt = document.updatedAt
    }
}

public struct SearchResultPresentation: Equatable, Sendable, Identifiable {
    public var id: String
    public var documentID: DocumentID
    public var path: DocumentPath
    public var title: String?
    public var snippet: String
    public var score: Double

    public init(result: SearchResult) {
        id = result.id
        documentID = result.documentID
        path = result.path
        title = result.title
        snippet = result.snippet
        score = result.score
    }
}

public struct MetaBrainBrowserState: Equatable, Sendable {
    public var location: MetaBrainStoreLocation?
    public var tree: [MetaBrainTreeNode]
    public var selectedPath: DocumentPath?
    public var expandedPathIDs: Set<String>
    public var selectedDocument: DocumentPresentation?
    public var selectedDirectory: MetaBrainTreeNode?
    public var searchResults: [SearchResultPresentation]
    public var isOpening: Bool
    public var isLoadingDocument: Bool
    public var isSearching: Bool
    public var errorMessage: String?

    public init(
        location: MetaBrainStoreLocation? = nil,
        tree: [MetaBrainTreeNode] = [],
        selectedPath: DocumentPath? = nil,
        expandedPathIDs: Set<String> = [],
        selectedDocument: DocumentPresentation? = nil,
        selectedDirectory: MetaBrainTreeNode? = nil,
        searchResults: [SearchResultPresentation] = [],
        isOpening: Bool = false,
        isLoadingDocument: Bool = false,
        isSearching: Bool = false,
        errorMessage: String? = nil
    ) {
        self.location = location
        self.tree = tree
        self.selectedPath = selectedPath
        self.expandedPathIDs = expandedPathIDs
        self.selectedDocument = selectedDocument
        self.selectedDirectory = selectedDirectory
        self.searchResults = searchResults
        self.isOpening = isOpening
        self.isLoadingDocument = isLoadingDocument
        self.isSearching = isSearching
        self.errorMessage = errorMessage
    }
}

public typealias MetaBrainStoreOpener = @MainActor @Sendable (URL) async throws -> any MetaBrainStoreClient

@MainActor
public final class MetaBrainBrowserModel: ObservableObject {
    @Published public private(set) var state: MetaBrainBrowserState

    private let openStore: MetaBrainStoreOpener
    private var storeClient: (any MetaBrainStoreClient)?

    public init(
        state: MetaBrainBrowserState = MetaBrainBrowserState(),
        openStore: @escaping MetaBrainStoreOpener = { folderURL in
            try LiveMetaBrainStoreClient.open(selectedMetaBrainFolder: folderURL)
        }
    ) {
        self.state = state
        self.openStore = openStore
    }

    public func openMetaBrainFolder(_ folderURL: URL) async {
        state.isOpening = true
        state.errorMessage = nil

        do {
            let client = try await openStore(folderURL)
            let entries = try await client.loadTree()
            storeClient = client
            state = MetaBrainBrowserState(
                location: client.location,
                tree: MetaBrainTreeBuilder.forest(from: entries)
            )
        } catch {
            state.isOpening = false
            state.errorMessage = Self.errorMessage(for: error)
        }
    }

    public func refreshTree() async {
        guard let storeClient else {
            state.errorMessage = MetaBrainAppSupportError.noOpenStore.description
            return
        }

        do {
            let entries = try await storeClient.loadTree()
            state.tree = MetaBrainTreeBuilder.forest(from: entries)
            state.errorMessage = nil
        } catch {
            state.errorMessage = Self.errorMessage(for: error)
        }
    }

    public func selectPath(_ path: DocumentPath) async {
        guard let storeClient else {
            state.errorMessage = MetaBrainAppSupportError.noOpenStore.description
            return
        }

        state.selectedPath = path
        state.expandedPathIDs.formUnion(MetaBrainTreeBuilder.ancestorPathIDs(for: path))
        state.errorMessage = nil

        let node = MetaBrainTreeBuilder.firstNode(matching: path, in: state.tree)
        if let node, !node.isDocument {
            state.selectedDocument = nil
            state.selectedDirectory = node
            return
        }

        state.isLoadingDocument = true
        state.selectedDirectory = nil

        do {
            guard let document = try await storeClient.loadDocument(path: path) else {
                state.selectedDocument = nil
                state.errorMessage = MetaBrainAppSupportError.missingDocument(path.rawValue).description
                state.isLoadingDocument = false
                return
            }

            state.selectedDocument = DocumentPresentation(document: document)
            state.isLoadingDocument = false
        } catch {
            state.selectedDocument = nil
            state.errorMessage = Self.errorMessage(for: error)
            state.isLoadingDocument = false
        }
    }

    public func setExpanded(_ isExpanded: Bool, for nodeID: String) {
        if isExpanded {
            state.expandedPathIDs.insert(nodeID)
        } else {
            state.expandedPathIDs.remove(nodeID)
        }
    }

    public func search(_ text: String, limit: Int = 50) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            state.searchResults = []
            state.isSearching = false
            state.errorMessage = nil
            return
        }

        guard let storeClient else {
            state.searchResults = []
            state.errorMessage = MetaBrainAppSupportError.noOpenStore.description
            return
        }

        state.isSearching = true
        state.errorMessage = nil

        do {
            state.searchResults = try await storeClient
                .search(text: trimmedText, limit: limit)
                .map(SearchResultPresentation.init)
            state.isSearching = false
        } catch {
            state.searchResults = []
            state.isSearching = false
            state.errorMessage = Self.errorMessage(for: error)
        }
    }

    public func navigate(to result: SearchResultPresentation) async {
        await selectPath(result.path)
    }

    private static func errorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return String(describing: error)
    }
}
