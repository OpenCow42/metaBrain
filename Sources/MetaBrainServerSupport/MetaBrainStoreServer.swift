import Dispatch
import Foundation
import MetaBrainCore

public actor MetaBrainStoreServer {
    public nonisolated let storePath: String

    private let store: MetaBrainStore

    public init(storePath: String, createIfMissing: Bool = true) throws {
        let url = Self.storeURL(for: storePath)
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        self.init(store: try MetaBrainStore(url: url, options: MetaBrainStoreOptions(createIfMissing: createIfMissing)))
    }

    private init(store: MetaBrainStore) {
        self.storePath = store.url.path
        self.store = store
    }

    static func openInitialized(storePath: String, empty: Bool) async throws -> MetaBrainStoreServer {
        let store = try await MetaBrainStore.initialize(at: storeURL(for: storePath), empty: empty)
        return MetaBrainStoreServer(store: store)
    }

    public func initialize() -> InitializeOutput {
        InitializeOutput(storePath: storePath)
    }

    public func ensureAgentGuide() async throws -> PutOutput {
        PutOutput(try await store.ensureAgentGuide(), operation: "ensure-guide")
    }

    public func version() -> VersionOutput {
        VersionOutput(
            currentTag: MetaBrainVersion.currentSoftwareTag(),
            releaseCheck: nil
        )
    }

    public func put(_ request: ServerPutRequest) async throws -> PutOutput {
        try await put(request.documentInput())
    }

    func put(_ input: DocumentInput, ifVersion: UInt64? = nil, bodyOnly: Bool = false) async throws -> PutOutput {
        PutOutput(try await store.writeDocument(input, ifVersion: ifVersion, bodyOnly: bodyOnly))
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

    public func getVersion(_ request: ServerGetDocumentVersionRequest) async throws -> GetOutput {
        let reference = try request.documentReference()
        guard let document = try await store.getDocument(reference, version: request.version) else {
            throw MetaBrainStoreError.documentVersionNotFound(
                reference: Self.referenceDescription(reference),
                version: request.version
            )
        }
        return GetOutput(document)
    }

    public func getPassage(_ request: ServerGetPassageRequest) async throws -> DocumentPassageOutput {
        try await request.read(from: store)
    }

    public func getEvidence(_ request: ServerGetEvidenceRequest) async throws -> EvidenceOutput {
        try await store.getEvidence(
            request.ref,
            context: request.context,
            maxTokens: request.maxTokens ?? EvidenceOutput.defaultMaxTokens
        )
    }

    public func links(_ request: ServerLinksRequest) async throws -> [DocumentLinkOutput] {
        try await store.links(
            for: request.reference.documentReference(),
            direction: request.direction ?? .outgoing,
            block: request.block
        ).map(DocumentLinkOutput.init)
    }

    public func lint(_ request: ServerLintRequest) async throws -> DocumentLintReport {
        try await store.lint(request.lintQuery())
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

    public func searchEvidence(_ request: ServerEvidenceSearchRequest) async throws -> EvidenceOutput {
        try await store.searchEvidence(
            request.searchQuery(),
            view: request.view,
            maxTokens: request.maxTokens ?? EvidenceOutput.defaultMaxTokens
        )
    }

    func recall(_ query: SearchQuery, maxBytes: Int) async throws -> [RecallResult] {
        try await store.recall(query, maxBytes: maxBytes)
    }

    public func versions(_ request: ServerVersionsRequest) async throws -> [VersionsOutput] {
        try await store.listVersions(of: request.documentReference()).map(VersionsOutput.init)
    }

    public func dump(_ request: ServerDumpRequest) async throws -> [DumpOutput] {
        try await store.dump(request.dumpQuery()).map(DumpOutput.init)
    }

    public func patch(_ request: ServerPatchRequest) async throws -> ServerPatchOutput {
        let patchRequest = try request.documentPatchRequest()
        if request.check {
            try await store.checkDocumentPatch(patchRequest)
            return .check(PatchCheckOutput())
        }

        let document = try await store.patchDocument(patchRequest)
        return .patch(PatchOutput(document))
    }

    public func inspectOperation(_ operation: ProjectOperation, checkCitations: Bool = false) async throws -> OperationPreview {
        try await store.inspectOperation(operation, checkCitations: checkCitations)
    }

    public func applyOperation(_ preview: OperationPreview) async throws -> OperationReceipt {
        try await store.applyOperation(preview)
    }

    func stageSourceChunk(_ request: ServerSourceChunk) async throws -> ServerSourceChunkDigest {
        try await ServerSourceChunkDigest(sha256: store.stageSourceChunk(request.bytes))
    }

    func finishSourceBlob(_ request: ServerSourceFinishRequest) async throws -> SourceBlob {
        try await store.finishSourceBlob(chunks: request.chunks)
    }

    func sourceDescriptor(_ request: ServerSourceDescriptorRequest) async throws -> SourceDescriptor {
        try await store.sourceDescriptor(request.reference.documentReference(), version: request.version)
    }

    func sourceChunk(_ request: ServerSourceReadRequest) async throws -> ServerSourceChunk {
        try await ServerSourceChunk(bytes: store.sourceChunk(
            request.reference.documentReference(), version: request.version, index: request.index
        ))
    }

    public func move(_ request: ServerMoveRequest) async throws -> MoveOutput {
        let result = try await store.moveDocument(
            request.documentReference(),
            to: request.documentPath()
        )
        return MoveOutput(result)
    }

    public func prune(_ request: ServerPruneRequest) async throws -> PruneOutput {
        let result = try await store.prune(request.pruneRequest())
        return PruneOutput(result)
    }

    public func delete(_ request: ServerDeleteRequest) async throws -> DeleteOutput {
        let reference = try request.documentReference()
        return DeleteOutput(
            reference: Self.referenceDescription(reference),
            deleted: try await store.deleteDocument(reference)
        )
    }

    public func removeVersion(_ request: ServerRemoveVersionRequest) async throws -> RemoveVersionOutput {
        let reference = try request.documentReference()
        let sequence = try request.validatedSequence()
        let removed: Bool
        if let document = try await store.getDocument(reference, trackingRead: false) {
            removed = try await store.removeVersion(documentID: document.id, sequence: sequence)
        } else {
            removed = false
        }
        return RemoveVersionOutput(
            reference: Self.referenceDescription(reference),
            removed: removed,
            sequence: sequence
        )
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

        Task.detached(priority: .userInitiated) {
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
