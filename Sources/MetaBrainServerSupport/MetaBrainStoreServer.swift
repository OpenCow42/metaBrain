import Dispatch
import Foundation
import MetaBrainCore

public actor MetaBrainStoreServer {
    public nonisolated let storePath: String

    private let store: MetaBrainStore

    public init(storePath: String) throws {
        let url = Self.storeURL(for: storePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.storePath = url.path
        self.store = try MetaBrainStore(url: url)
    }

    public func initialize() -> InitializeOutput {
        InitializeOutput(storePath: storePath)
    }

    public func version() -> VersionOutput {
        VersionOutput(
            currentTag: MetaBrainVersion.currentSoftwareTag(),
            releaseCheck: nil
        )
    }

    public func put(_ request: ServerPutRequest) async throws -> PutOutput {
        let document = try await store.putDocument(request.documentInput())
        return PutOutput(
            documentID: document.id.rawValue,
            path: document.path.rawValue,
            status: document.currentVersion == 1 ? "created" : "updated",
            version: document.currentVersion
        )
    }

    public func get(_ request: ServerGetRequest) async throws -> GetOutput {
        let reference = try request.documentReference()
        guard let document = try await store.getDocument(
            reference,
            trackingRead: request.trackingRead
        ) else {
            throw MetaBrainStoreError.documentNotFound(Self.referenceDescription(reference))
        }
        return GetOutput(document)
    }

    public func list(_ request: ServerListRequest) async throws -> [ListOutput] {
        try await store.listDirectory(
            path: request.documentPath(),
            recursive: request.recursive,
            directoriesOnly: request.directoriesOnly
        ).map(ListOutput.init)
    }

    public func tree(_ request: ServerTreeRequest) async throws -> [TreeOutput] {
        let query = try request.treeQuery()
        let entries = try await store.tree(query)
        return Self.treeOutputs(root: query.path, entries: entries, maxDepth: query.maxDepth)
    }

    public func search(_ request: ServerSearchRequest) async throws -> [SearchOutput] {
        try await store.search(request.searchQuery()).map(SearchOutput.init)
    }

    public func versions(_ request: ServerVersionsRequest) async throws -> [VersionsOutput] {
        try await store.listVersions(of: request.documentReference()).map(VersionsOutput.init)
    }

    public func close() async {
        await store.close()
    }

    public nonisolated func closeBlocking() {
        try! ServerAsyncBridge.run {
            await self.close()
        }
    }

    private static func storeURL(for storePath: String) -> URL {
        URL(
            fileURLWithPath: NSString(string: storePath).expandingTildeInPath,
            isDirectory: true
        )
    }

    private static func treeOutputs(
        root: DocumentPath,
        entries: [DocumentTreeEntry],
        maxDepth: Int?
    ) -> [TreeOutput] {
        guard !entries.isEmpty || maxDepth == 0 else {
            return []
        }
        return [TreeOutput(root: root, hasChildren: !entries.isEmpty)] + entries.map(TreeOutput.init)
    }

    private static func referenceDescription(_ reference: DocumentReference) -> String {
        switch reference {
        case .documentID(let id):
            return id.rawValue
        case .path(let path):
            return path.rawValue
        case .externalURL(let url):
            return url.absoluteString
        }
    }
}

enum ServerAsyncBridge {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ServerAsyncResultBox<T>()

        Task {
            do {
                box.set(.success(try await operation()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        semaphore.wait()
        switch box.value! {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class ServerAsyncResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Result<T, Error>?

    var value: Result<T, Error>? {
        lock.withLock { storedValue }
    }

    func set(_ value: Result<T, Error>) {
        lock.withLock {
            storedValue = value
        }
    }
}
