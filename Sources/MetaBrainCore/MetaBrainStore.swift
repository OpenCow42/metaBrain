import Foundation
import LevelDBTyped
import LevelDBZstd
import swift_leveldb

public struct MetaBrainStoreOptions: Equatable, Sendable {
    public static let `default` = MetaBrainStoreOptions()

    public var createIfMissing: Bool
    public var errorIfExists: Bool
    public var paranoidChecks: Bool
    public var zstdCompressionLevel: Int32
    public var zstdAdaptiveMinimumSavingsRatio: Double
    public var lruCacheCapacity: Int?
    public var bloomFilterBitsPerKey: Int?

    public init(
        createIfMissing: Bool = true,
        errorIfExists: Bool = false,
        paranoidChecks: Bool = true,
        zstdCompressionLevel: Int32 = 9,
        zstdAdaptiveMinimumSavingsRatio: Double = 0.10,
        lruCacheCapacity: Int? = 64 * 1024 * 1024,
        bloomFilterBitsPerKey: Int? = 10
    ) {
        self.createIfMissing = createIfMissing
        self.errorIfExists = errorIfExists
        self.paranoidChecks = paranoidChecks
        self.zstdCompressionLevel = zstdCompressionLevel
        self.zstdAdaptiveMinimumSavingsRatio = zstdAdaptiveMinimumSavingsRatio
        self.lruCacheCapacity = lruCacheCapacity
        self.bloomFilterBitsPerKey = bloomFilterBitsPerKey
    }

    var levelDBOptions: LevelDBStoreOptions {
        LevelDBStoreOptions(
            createIfMissing: createIfMissing,
            errorIfExists: errorIfExists,
            paranoidChecks: paranoidChecks,
            compression: Database.OpenOptions.Compression.none,
            lruCacheCapacity: lruCacheCapacity,
            bloomFilterBitsPerKey: bloomFilterBitsPerKey
        )
    }
}

public enum MetaBrainStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case storeNotFound(path: String)
    case openFailed(path: String, message: String)
    case operationFailed(message: String)
    case documentNotFound(String)
    case lintScopeNotFound(DocumentPath)
    case documentVersionNotFound(reference: String, version: UInt64)
    case invalidDocumentVersion(UInt64)
    case pathAlreadyExists(DocumentPath, existingID: DocumentID)
    case documentVersionConflict(DocumentPath, expected: UInt64, actual: UInt64?)
    case documentVersionExhausted(DocumentPath)
    case bodyOnlyCannotCreate
    case currentVersionCannotBeRemoved(DocumentID, sequence: UInt64)
    case unsupportedRecordSchemaVersion(UInt8)
    case newerRecordSchemaVersion(UInt8, operation: String)

    public var description: String {
        switch self {
        case .storeNotFound(let path):
            "No metaBrain store found at \(path)."
        case .openFailed(let path, let message):
            "Could not open metaBrain store at \(path): \(message)"
        case .operationFailed(let message):
            "LevelDB operation failed: \(message)"
        case .documentNotFound(let reference):
            "Document not found: \(reference)."
        case .lintScopeNotFound(let path):
            "No document or descendants found at lint path \(path)."
        case .documentVersionNotFound(let reference, let version):
            "Document version \(version) not found for \(reference). Check the document reference and retained versions."
        case .invalidDocumentVersion(let version):
            "Document version must be greater than zero, got \(version)."
        case .pathAlreadyExists(let path, let existingID):
            "Document path \(path.rawValue) already points to document \(existingID.rawValue)."
        case .documentVersionConflict(let path, let expected, let actual):
            if let actual {
                "Version conflict at \(path.rawValue): expected version \(expected), found version \(actual)."
            } else {
                "Version conflict at \(path.rawValue): expected version \(expected), document does not exist."
            }
        case .documentVersionExhausted(let path):
            "Document \(path.rawValue) has reached the maximum version number."
        case .bodyOnlyCannotCreate:
            "A body-only write cannot be combined with create-only version 0."
        case .currentVersionCannotBeRemoved(let id, let sequence):
            "Cannot remove current version \(sequence) of document \(id.rawValue)."
        case .unsupportedRecordSchemaVersion(let version):
            "Unsupported metaBrain record schema version: \(version)."
        case .newerRecordSchemaVersion(let version, let operation):
            "This metaBrain store contains record schema version \(version), which is newer than this tool can safely modify during \(operation). Upgrade metaBrain to modify these records."
        }
    }
}

public final class MetaBrainStore: Sendable {
    public let url: URL
    public let options: MetaBrainStoreOptions

    private let records: MetaBrainStoreDatabase
    private let writes = MetaBrainWriteCoordinator()
    private let treeIndex = MetaBrainIndexPreparation()
    private let searchFieldIndex = MetaBrainIndexPreparation()
    private let citationIndex = MetaBrainIndexPreparation()
    private static let chunkTargetCharacterCount = 4_000
    private static let chunkOverlapCharacterCount = 400
    private static let emptyIndexValue = Data()
    private static let bulkReadOptions = Database.ReadOptions(fillCache: false)
    private static let caseSensitiveTreeLayout = Data([1])
    private static let currentSearchFieldLayout = Data([2])

    public convenience init(path: String, options: MetaBrainStoreOptions = .default) throws {
        try self.init(url: URL(fileURLWithPath: path, isDirectory: true), options: options)
    }

    /// Returns whether the path contains LevelDB's marker for an initialized store.
    /// Opening the store still validates its manifest and records.
    public static func exists(at url: URL) -> Bool {
        let marker = url.appendingPathComponent("CURRENT", isDirectory: false)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Checks for an existing store without opening LevelDB or creating any files.
    public static func requireExistingStore(at url: URL) throws {
        guard exists(at: url) else {
            throw MetaBrainStoreError.storeNotFound(path: url.path)
        }
    }

    public convenience init(url: URL, options: MetaBrainStoreOptions = .default) throws {
        try self.init(url: url, options: options, openOptions: options.levelDBOptions)
    }

    private init(url: URL, options: MetaBrainStoreOptions, openOptions: LevelDBStoreOptions) throws {
        if !openOptions.createIfMissing {
            // LevelDB creates the database directory and lock before checking its manifest.
            try Self.requireExistingStore(at: url)
        }
        self.url = url
        self.options = options

        do {
            let openedRecords = try LevelDBStore(
                path: url.path,
                keyCodec: StringCodec(),
                valueCodec: DataCodec(),
                options: openOptions
            )
            records = MetaBrainStoreDatabase(openedRecords)
        } catch let error as LevelDBError {
            throw Self.storeError(from: error, path: url.path)
        }
    }

    /// Opens a store, writing the agent guide only when creating a new database.
    /// Pass `empty: true` to create a database with no initial documents.
    public static func initialize(at url: URL, empty: Bool = false) async throws -> MetaBrainStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if empty {
            return try MetaBrainStore(url: url)
        }

        // LevelDB checks for a database under its lock, including in an existing directory.
        let options = MetaBrainStoreOptions.default
        var openOptions = options.levelDBOptions
        openOptions.errorIfExists = true
        let store: MetaBrainStore
        do {
            store = try MetaBrainStore(url: url, options: options, openOptions: openOptions)
        } catch MetaBrainStoreError.openFailed(_, let message)
            where message.hasSuffix(": exists (error_if_exists is true)") {
            // Require the existing database on the second open to avoid creating an unseeded store.
            openOptions.errorIfExists = false
            openOptions.createIfMissing = false
            return try MetaBrainStore(url: url, options: options, openOptions: openOptions)
        }

        do {
            try await store.writeNewDocument(MetaBrainAgentGuide.document, writeOptions: .init(sync: true))
            return store
        } catch {
            await store.close()
            throw error
        }
    }

    public func close() async {
        await records.close()
    }

    private func currentRecords() async throws -> LevelDBStore<StringCodec, DataCodec> {
        try await records.store()
    }

    @discardableResult
    public func putDocument(_ input: DocumentInput) async throws -> StoredDocument {
        try await writeDocument(input).document
    }

    /// Installs the bundled /AGENTS.md once. An existing guide, including a
    /// locally edited one, is returned without changing its content or version.
    public func ensureAgentGuide() async throws -> DocumentWriteResult {
        try await writes.run {
            let guide = MetaBrainAgentGuide.document
            if let existing = try await self.getDocument(.path(guide.path), trackingRead: false) {
                return DocumentWriteResult(document: existing, status: .unchanged)
            }
            let created = try await self.writeNewDocument(guide)
            return DocumentWriteResult(document: created, status: .created)
        }
    }

    /// Writes a full replacement or updates only the body of an existing document.
    /// Version zero allows creation. A matching write at the current version or its immediate
    /// predecessor returns `.unchanged` without creating a version.
    @discardableResult
    public func writeDocument(
        _ input: DocumentInput,
        ifVersion: UInt64? = nil,
        bodyOnly: Bool = false
    ) async throws -> DocumentWriteResult {
        if bodyOnly, ifVersion == 0 {
            throw MetaBrainStoreError.bodyOnlyCannotCreate
        }

        return try await writes.run {
            guard let id = try await self.documentID(forPath: input.path),
                  let record = try await self.currentDocumentRecord(id: id, operation: "update document") else {
                if let ifVersion, ifVersion != 0 {
                    throw MetaBrainStoreError.documentVersionConflict(input.path, expected: ifVersion, actual: nil)
                }
                if bodyOnly {
                    throw MetaBrainStoreError.documentNotFound(input.path.rawValue)
                }

                let document = try await self.writeNewDocument(input)
                return DocumentWriteResult(document: document, status: .created)
            }

            let current = record.document
            let version = current.currentVersion
            let effectiveInput = bodyOnly ? record.bodyReplacement(input.body) : input

            let unchanged: Bool
            if let ifVersion, ifVersion != version {
                guard version > ifVersion, version - ifVersion == 1, record.matches(effectiveInput) else {
                    throw MetaBrainStoreError.documentVersionConflict(input.path, expected: ifVersion, actual: version)
                }
                unchanged = true
            } else {
                unchanged = record.matches(effectiveInput)
            }
            if unchanged {
                try await self.refreshPathReferenceIndexes(for: current)
                return DocumentWriteResult(document: current, status: .unchanged)
            }

            let document = try await self.writeDocumentUpdate(id: id, existingRecord: record, input: effectiveInput)
            return DocumentWriteResult(document: document, status: .updated)
        }
    }

    @discardableResult
    public func updateDocument(
        _ reference: DocumentReference,
        with input: DocumentInput
    ) async throws -> StoredDocument {
        try await writes.run {
            guard let id = try await self.documentID(for: reference) else {
                return try await self.writeNewDocument(input)
            }

            return try await self.writeDocumentUpdate(id: id, input: input)
        }
    }

    @discardableResult
    public func moveDocument(
        _ reference: DocumentReference,
        to destinationPath: DocumentPath
    ) async throws -> DocumentMoveResult {
        try await writes.run {
            guard let id = try await self.documentID(for: reference),
                  let existingRecord = try await self.documentRecord(id: id) else {
                throw MetaBrainStoreError.documentNotFound(Self.referenceDescription(reference))
            }

            let existing = existingRecord.document
            guard existing.path != destinationPath else {
                return DocumentMoveResult(
                    document: existing,
                    sourcePath: existing.path,
                    destinationPath: destinationPath,
                    moved: false
                )
            }

            let moved = try await self.writeDocumentUpdate(
                id: id,
                input: DocumentInput(
                    path: destinationPath,
                    title: existing.title,
                    body: existing.body,
                    tags: existing.tags,
                    metadata: existing.metadata,
                    references: existing.references
                )
            )

            return DocumentMoveResult(
                document: moved,
                sourcePath: existing.path,
                destinationPath: destinationPath,
                moved: true
            )
        }
    }

    public func getDocument(
        _ reference: DocumentReference,
        trackingRead: Bool = true
    ) async throws -> StoredDocument? {
        let entry = try await getDocumentEntry(reference, trackingRead: trackingRead)
        return entry?.document
    }

    /// Reads a retained revision without incrementing the document's read count.
    /// A path resolves through the current index. Use the document ID to read revisions after a move.
    /// The result uses the revision path, content, version, and update date. It preserves the original creation date.
    /// An unavailable revision returns nil. A version of zero throws `MetaBrainStoreError.invalidDocumentVersion`.
    public func getDocument(
        _ reference: DocumentReference,
        version: UInt64
    ) async throws -> StoredDocument? {
        guard version > 0 else { throw MetaBrainStoreError.invalidDocumentVersion(version) }

        return try await writes.run {
            guard let id = try await self.documentID(for: reference),
                  let revision = try await self.compressedRecord(
                      forKey: MetaBrainKeyspace.version(id: id, sequence: version),
                      as: DocumentVersion.self
                  ),
                  let current = try await self.documentRecord(id: id) else {
                return nil as StoredDocument?
            }

            let snapshot = revision.snapshot
            return StoredDocument(
                id: id,
                path: snapshot.path,
                title: snapshot.title,
                body: snapshot.body,
                tags: snapshot.tags,
                metadata: snapshot.metadata,
                references: snapshot.references,
                currentVersion: revision.sequence,
                createdAt: current.document.createdAt,
                updatedAt: revision.createdAt,
                markdown: snapshot.markdown
            )
        }
    }

    public func getDocumentEntry(
        _ reference: DocumentReference,
        trackingRead: Bool = true
    ) async throws -> StoredDocumentEntry? {
        guard trackingRead else {
            guard let id = try await documentID(for: reference),
                  let record = try await documentRecord(id: id) else {
                return nil
            }

            return StoredDocumentEntry(
                document: record.document,
                entryMetadata: try await entryMetadataRecord(for: record.document)
            )
        }

        return try await writes.run {
            guard let id = try await self.documentID(for: reference),
                  let storedRecord = try await self.documentStoredRecord(id: id) else {
                return nil as StoredDocumentEntry?
            }

            let record = storedRecord.payload
            let metadata: DocumentEntryMetadata
            if storedRecord.schemaVersion.isCurrent {
                metadata = try await self.writeEntryMetadata(
                    for: record.document,
                    readDelta: 1
                )
            } else {
                metadata = try await self.entryMetadataRecord(for: record.document)
            }

            return StoredDocumentEntry(
                document: record.document,
                entryMetadata: metadata
            )
        }
    }

    public func entryMetadata(for reference: DocumentReference) async throws -> DocumentEntryMetadata? {
        guard let id = try await documentID(for: reference),
              let record = try await documentRecord(id: id) else {
            return nil
        }

        return try await entryMetadataRecord(for: record.document)
    }

    public func listVersions(of reference: DocumentReference) async throws -> [DocumentVersion] {
        guard let id = try await documentID(for: reference) else {
            return []
        }

        return try await versionRecords(for: id)
    }

    public func dump(_ query: DocumentDumpQuery) async throws -> [DocumentDumpEntry] {
        let documents = try await dumpDocuments(under: query.path)

        switch query.versionSelection {
        case .current:
            return documents.map(Self.dumpEntry(for:))
        case .allRetained:
            var entries: [DocumentDumpEntry] = []
            for document in documents {
                let versions = try await versionRecords(for: document.id)
                entries += versions.map { version in
                    Self.dumpEntry(
                        documentID: document.id,
                        currentVersion: document.currentVersion,
                        version: version
                    )
                }
            }
            return entries
        }
    }

    public func checkDocumentPatch(_ request: DocumentPatchRequest) async throws {
        _ = try await patchedDocumentInput(for: request)
    }

    @discardableResult
    public func patchDocument(_ request: DocumentPatchRequest) async throws -> StoredDocument {
        try await writes.run {
            let patched = try await self.patchedDocumentInput(for: request)
            return try await self.writeDocumentUpdate(
                id: patched.id,
                input: patched.input,
                accessMutation: .patch
            )
        }
    }

    public func listDirectory(
        path: DocumentPath = try! DocumentPath("/"),
        recursive: Bool = false,
        directoriesOnly: Bool = false
    ) async throws -> [DocumentTreeEntry] {
        try await ensureTreeIndex()
        guard recursive else {
            let children = try await childTreeEntries(of: path)
            var entries: [DocumentTreeEntry] = []
            for child in children {
                if !directoriesOnly {
                    entries.append(child)
                } else if child.hasChildren {
                    entries.append(child)
                }
            }
            return entries
        }

        return try await flattenedTreeEntries(
            under: path,
            directoriesOnly: directoriesOnly,
            maxDepth: nil,
            currentDepth: 0
        )
    }

    public func tree(_ query: TreeQuery = TreeQuery()) async throws -> [DocumentTreeEntry] {
        if let maxDepth = query.maxDepth, maxDepth <= 0 {
            return []
        }

        try await ensureTreeIndex()
        return try await flattenedTreeEntries(
            under: query.path,
            directoriesOnly: query.directoriesOnly,
            maxDepth: query.maxDepth,
            currentDepth: 0
        )
    }

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        let queryTerms = Set(Self.tokenize(query.text)).sorted()
        guard !queryTerms.isEmpty, query.limit > 0 else {
            return []
        }

        var topCandidates = MetaBrainSearchTopCandidates(limit: query.limit)
        try await forEachRankedSearchDocument(query, terms: queryTerms) { document, chunks, passages, _ in
            for passage in passages {
                let chunk = passage.chunk
                topCandidates.insert(MetaBrainRankedSearchCandidate(
                    documentID: document.id,
                    path: document.path,
                    title: document.title,
                    chunkOrdinal: chunk.ordinal,
                    snippet: chunk.text.isEmpty ? document.title ?? document.path.rawValue : chunk.text,
                    context: Self.contextChunks(around: chunk.ordinal, in: chunks),
                    score: passage.score
                ))
            }
        }
        return try await searchResults(from: topCandidates.sortedCandidates(), query: query)
    }

    /// Returns current document citations and compact body passages within a JSON UTF-8 byte budget.
    /// The budget includes a trailing newline and the query limit counts distinct documents.
    public func recall(_ query: SearchQuery, maxBytes: Int = RecallResult.defaultMaxBytes) async throws -> [RecallResult] {
        guard maxBytes >= RecallResult.minimumMaxBytes else {
            throw RecallError.invalidByteBudget(maxBytes)
        }
        guard query.limit > 0 else {
            throw RecallError.invalidDocumentLimit(query.limit)
        }
        let terms = Set(Self.tokenize(query.text)).sorted()
        guard !terms.isEmpty, maxBytes > RecallResult.minimumMaxBytes else {
            return []
        }

        let candidates = try await writes.run {
            var candidates: [MetaBrainRecallCandidate] = []
            try await self.forEachRankedSearchDocument(query, terms: terms) { document, _, passages, weights in
                if let candidate = try MetaBrainRecallCandidate(
                    document: document,
                    passages: passages,
                    weights: weights,
                    maxBytes: maxBytes
                ) {
                    candidates.append(candidate)
                }
            }
            return candidates
        }
        return try MetaBrainRecallCandidate.select(candidates, limit: query.limit, maxBytes: maxBytes)
    }

    /// Returns versioned references and optional verbatim excerpts under a serialized output budget.
    /// The budget includes the final line feed. The query limit counts distinct documents.
    /// A refs query with only filters returns one whole-body reference for each matching document.
    public func searchEvidence(
        _ query: SearchQuery,
        view: EvidenceSearchView,
        maxTokens: Int = EvidenceOutput.defaultMaxTokens
    ) async throws -> EvidenceOutput {
        guard maxTokens >= EvidenceOutput.minimumMaxTokens else { throw EvidenceError.invalidTokenBudget(maxTokens) }
        guard query.limit > 0 else { throw EvidenceError.invalidDocumentLimit(query.limit) }

        let terms = Set(Self.tokenize(query.text)).sorted()
        let candidates: [EvidenceSearchCandidate]
        if query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard query.pathPrefix != nil || !query.tags.isEmpty || !query.metadata.isEmpty else {
                throw EvidenceError.missingTextOrFilters
            }
            guard view == .refs else { throw EvidenceError.filterOnlyRequiresRefs }
            candidates = try await writes.run { try await self.filterOnlyEvidenceCandidates(for: query) }
        } else if terms.isEmpty {
            candidates = []
        } else {
            candidates = try await writes.run {
                var candidates: [EvidenceSearchCandidate] = []
                try await self.forEachRankedSearchDocument(query, terms: terms) { document, _, passages, weights in
                    candidates.append(EvidenceSearchCandidate(document: document, passages: passages, weights: weights, view: view))
                }
                return candidates
            }
        }
        return try EvidenceSearchCandidate.select(candidates, limit: query.limit, maxTokens: maxTokens)
    }

    private func filterOnlyEvidenceCandidates(for query: SearchQuery) async throws -> [EvidenceSearchCandidate] {
        var ids: Set<DocumentID>
        if let indexed = try await filteredDocumentIDs(for: query) {
            ids = indexed
        } else if let path = query.pathPrefix {
            let descendants = try await listDirectory(path: path, recursive: true)
            ids = Set(descendants.compactMap(\.documentID))
            if let id = try await documentID(forPath: path) { ids.insert(id) }
        } else {
            return []
        }

        var candidates: [EvidenceSearchCandidate] = []
        for id in ids {
            guard let document = try await documentRecord(id: id)?.document,
                  Self.path(document.path, matchesPrefix: query.pathPrefix) else { continue }
            let ref = EvidenceReference(document: document, location: .range(0..<document.body.count))
            candidates.append(EvidenceSearchCandidate(document: document, reference: ref))
        }
        return candidates
    }

    private func forEachRankedSearchDocument(
        _ query: SearchQuery,
        terms queryTerms: [String],
        visit: (StoredDocument, [UInt32: MetaBrainChunkRecord], [MetaBrainRankedPassage], [String: Double]) throws -> Void
    ) async throws {
        let allowedIDs = try await filteredDocumentIDs(for: query)
        if allowedIDs?.isEmpty == true {
            return
        }

        let corpusSize = try await searchCorpusDocumentCount()
        var weights: [String: Double] = [:]
        var bodyOrdinalsByDocument: [DocumentID: Set<UInt32>] = [:]

        for term in queryTerms {
            var documentIDs = try await searchFieldDocumentIDs(matching: term)
            for id in documentIDs where allowedIDs?.contains(id) != false {
                bodyOrdinalsByDocument[id] = bodyOrdinalsByDocument[id] ?? []
            }

            for posting in try await termPostings(for: term) {
                documentIDs.insert(posting.documentID)
                if allowedIDs?.contains(posting.documentID) != false {
                    bodyOrdinalsByDocument[posting.documentID, default: []].insert(posting.chunkOrdinal)
                }
            }

            weights[term] = MetaBrainSearchRanking.inverseDocumentFrequency(
                corpusSize: corpusSize,
                documentFrequency: documentIDs.count
            )
        }

        let ranking = MetaBrainSearchRanking(terms: queryTerms, weights: weights)
        for (id, bodyOrdinals) in bodyOrdinalsByDocument {
            guard let document = try await documentRecord(id: id)?.document,
                  Self.path(document.path, matchesPrefix: query.pathPrefix) else {
                continue
            }
            let chunks = try await searchChunks(for: document, includeBodyMatches: !bodyOrdinals.isEmpty)
            let fields = ranking.fieldFrequencies(title: document.title, path: document.path)
            var passageFrequencies: [UInt32: [String: Int]] = [:]
            var documentFrequencies: [String: Int] = [:]
            for ordinal in bodyOrdinals {
                guard let chunk = chunks[ordinal] else {
                    continue
                }

                let frequencies = ranking.termFrequencies(in: chunk.text)
                if !frequencies.isEmpty {
                    passageFrequencies[ordinal] = frequencies
                    for (term, count) in frequencies {
                        documentFrequencies[term] = max(documentFrequencies[term, default: 0], count)
                    }
                }
            }

            if passageFrequencies.isEmpty, !fields.isEmpty, chunks[0] != nil {
                passageFrequencies[0] = [:]
            }

            guard !passageFrequencies.isEmpty else {
                continue
            }
            let documentScore = ranking.score(fields: fields, body: documentFrequencies)
            var passages: [MetaBrainRankedPassage] = []
            for (ordinal, frequencies) in passageFrequencies {
                guard let chunk = chunks[ordinal] else {
                    continue
                }

                let passageScore = ranking.score(fields: fields, body: frequencies)
                passages.append(MetaBrainRankedPassage(
                    chunk: chunk,
                    hasBodyMatch: !frequencies.isEmpty,
                    score: documentScore + 0.1 * passageScore
                ))
            }
            try visit(document, chunks, passages, weights)
        }
    }

    private func searchChunks(
        for document: StoredDocument,
        includeBodyMatches: Bool
    ) async throws -> [UInt32: MetaBrainChunkRecord] {
        let records: [MetaBrainChunkRecord]
        if includeBodyMatches {
            records = try await currentChunkRecords(for: document.id)
        } else {
            var firstChunks: [MetaBrainChunkRecord] = []
            for ordinal: UInt32 in [0, 1] {
                if let chunk = try await compressedRecord(
                    forKey: MetaBrainKeyspace.currentChunk(id: document.id, ordinal: ordinal),
                    as: MetaBrainChunkRecord.self
                ) {
                    firstChunks.append(chunk)
                }
            }
            records = firstChunks
        }
        return Dictionary(uniqueKeysWithValues: records
            .filter { $0.versionSequence == document.currentVersion }
            .map { ($0.ordinal, $0) })
    }

    @discardableResult
    public func prune(_ request: PruneRequest) async throws -> PruneResult {
        try await writes.run {
            guard let id = try await self.documentID(for: request.reference) else {
                return PruneResult(prunedVersionCount: 0, retainedVersionCount: 0)
            }

            if let record = try await self.documentStoredRecord(id: id) {
                try record.requireCurrentSchemaVersion(operation: "prune versions")
            }

            return try await self.pruneVersions(id: id, policy: request.policy)
        }
    }

    @discardableResult
    public func deleteDocument(_ reference: DocumentReference) async throws -> Bool {
        try await writes.run {
            guard let id = try await self.documentID(for: reference),
                  let storedRecord = try await self.documentStoredRecord(id: id) else {
                return false
            }

            try storedRecord.requireCurrentSchemaVersion(operation: "delete document")
            let record = storedRecord.payload
            try await self.deleteDocumentRecord(record)
            return true
        }
    }

    @discardableResult
    public func removeVersion(documentID: DocumentID, sequence: UInt64) async throws -> Bool {
        try await writes.run {
            guard let storedRecord = try await self.documentStoredRecord(id: documentID) else {
                return false
            }

            try storedRecord.requireCurrentSchemaVersion(operation: "remove version")
            let record = storedRecord.payload
            guard record.document.currentVersion != sequence else {
                throw MetaBrainStoreError.currentVersionCannotBeRemoved(documentID, sequence: sequence)
            }

            let versionKey = MetaBrainKeyspace.version(id: documentID, sequence: sequence)
            guard let versionRecord = try await self.compressedStoredRecord(
                forKey: versionKey,
                as: DocumentVersion.self
            ) else {
                return false
            }

            try versionRecord.requireCurrentSchemaVersion(operation: "remove version")
            try await self.deleteRawValue(forKey: versionKey)
            return true
        }
    }

    func putCompressedRecord<Value: Codable & Sendable>(
        _ value: Value,
        forKey key: String
    ) async throws {
        let encoded = try codec(for: Value.self).encode(
            MetaBrainRecordEnvelope(payload: value)
        )
        try await writeRawValue(encoded, forKey: key)
    }

    func compressedRecord<Value: Codable & Sendable>(
        forKey key: String,
        as type: Value.Type = Value.self
    ) async throws -> Value? {
        try await compressedStoredRecord(forKey: key, as: type)?.payload
    }

    private func compressedStoredRecord<Value: Codable & Sendable>(
        forKey key: String,
        as type: Value.Type = Value.self
    ) async throws -> MetaBrainStoredRecord<Value>? {
        guard let data = try await rawValue(forKey: key) else {
            return nil
        }

        return try decodeCompressedRecord(data, as: type)
    }

    func writeRawValue(_ value: Data, forKey key: String) async throws {
        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            try await records.put(value, forKey: key)
        }
    }

    func deleteRawValue(forKey key: String) async throws {
        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            try await records.write { batch in
                try batch.deleteValue(forKey: key)
            }
        }
    }

    func rawValue(forKey key: String) async throws -> Data? {
        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            return try await records.value(forKey: key)
        }
    }

    func currentChunks(for id: DocumentID) async throws -> [MetaBrainChunkRecord] {
        try await currentChunkRecords(for: id)
    }

    func documentIDs(matchingTerm term: String) async throws -> [DocumentID] {
        try await documentIDs(forIndexPrefix: MetaBrainKeyspace.termPrefix(Self.normalizedTerm(term)))
    }

    func searchCorpusDocumentCount() async throws -> Int {
        try await ensureSearchFieldIndex()
        return try await indexedSearchDocumentCount()
    }

    func searchFieldDocumentIDs(matching term: String) async throws -> Set<DocumentID> {
        try await ensureSearchFieldIndex()
        let prefix = MetaBrainKeyspace.searchFieldTermPrefix(Self.normalizedTerm(term))
        let keys = try await scanKeys(withPrefix: prefix)
        return try Set(keys.map { key in
            try DocumentID(rawValue: String(key.dropFirst(prefix.count)))
        })
    }

    func documentIDs(tagged tag: String) async throws -> [DocumentID] {
        try await documentIDs(forIndexPrefix: MetaBrainKeyspace.tagPrefix(tag))
    }

    func documentIDs(metadataKey key: String, value: String) async throws -> [DocumentID] {
        try await documentIDs(forIndexPrefix: MetaBrainKeyspace.metadataPrefix(key: key, value: value))
    }

    func outboundReferences(from sourceID: DocumentID) async throws -> [DocumentID] {
        try await ensureCitationIndex()
        let native = try await nativeOutboundReferences(from: sourceID)
        let citations = try await outgoingCitationRecords(from: sourceID)
        return Set(native + citations.compactMap { $0.status == .resolved ? $0.targetID : nil }).sorted()
    }

    private func nativeOutboundReferences(from sourceID: DocumentID) async throws -> [DocumentID] {
        let prefix = MetaBrainKeyspace.outboundReferencePrefix(sourceID: sourceID)
        return try await scanKeys(withPrefix: prefix)
            .compactMap { key in
                try DocumentID(rawValue: String(key.dropFirst(prefix.count)))
            }
            .sorted()
    }

    func inboundReferences(to targetID: DocumentID) async throws -> [DocumentID] {
        try await ensureCitationIndex()
        let prefix = MetaBrainKeyspace.inboundReferencePrefix(targetID: targetID)
        let native = try await scanKeys(withPrefix: prefix).map { key in
            try DocumentID(rawValue: String(key.dropFirst(prefix.count)))
        }
        let citationPrefix = MetaBrainKeyspace.citationInPrefix(targetID)
        let citationSources = try await scanKeys(withPrefix: citationPrefix).map { key in
            try Self.citationOccurrenceKey(key, prefix: citationPrefix).source
        }
        return Set(native + citationSources).sorted()
    }

    private func dumpDocuments(under path: DocumentPath) async throws -> [StoredDocument] {
        var documentIDs: Set<DocumentID> = []
        var documents: [StoredDocument] = []

        if let id = try await documentID(forPath: path),
           let record = try await documentRecord(id: id) {
            documents.append(record.document)
            documentIDs.insert(record.document.id)
        }

        for entry in try await listDirectory(path: path, recursive: true) {
            if let id = entry.documentID,
               !documentIDs.contains(id),
               let record = try await documentRecord(id: id) {
                documents.append(record.document)
                documentIDs.insert(id)
            }
        }

        return documents.sorted { $0.path < $1.path }
    }

    private static func dumpEntry(for document: StoredDocument) -> DocumentDumpEntry {
        DocumentDumpEntry(
            documentID: document.id,
            path: document.path,
            title: document.title,
            body: document.body,
            version: document.currentVersion,
            versionCreatedAt: document.updatedAt,
            isCurrent: true,
            tags: document.tags,
            metadata: document.metadata,
            references: document.references.map(DocumentDumpReference.init),
            markdown: document.markdown
        )
    }

    private static func dumpEntry(
        documentID: DocumentID,
        currentVersion: UInt64,
        version: DocumentVersion
    ) -> DocumentDumpEntry {
        DocumentDumpEntry(
            documentID: documentID,
            path: version.snapshot.path,
            title: version.snapshot.title,
            body: version.snapshot.body,
            version: version.sequence,
            versionCreatedAt: version.createdAt,
            isCurrent: version.sequence == currentVersion,
            tags: version.snapshot.tags,
            metadata: version.snapshot.metadata,
            references: version.snapshot.references.map(DocumentDumpReference.init),
            markdown: version.snapshot.markdown
        )
    }

    @discardableResult
    private func writeNewDocument(
        _ input: DocumentInput,
        writeOptions: Database.WriteOptions = .default
    ) async throws -> StoredDocument {
        let now = Date()
        let id = DocumentID.generate()
        let document = StoredDocument(
            id: id,
            path: input.path,
            title: input.title,
            body: input.body,
            tags: input.tags,
            metadata: input.metadata,
            references: input.references,
            currentVersion: 1,
            createdAt: now,
            updatedAt: now,
            markdown: input.markdown
        )
        let record = MetaBrainDocumentRecord(
            document: document,
            retention: input.retention ?? .keepAll
        )
        let version = DocumentVersion(
            documentID: id,
            sequence: document.currentVersion,
            snapshot: input,
            createdAt: now
        )

        try await writeDocumentBatch(
            record: record,
            version: version,
            entryMetadata: Self.defaultEntryMetadata(
                for: document,
                access: DocumentAccessCounts(fullWriteCount: 1)
            ),
            previousRecord: nil,
            removedPath: nil,
            prunedVersions: [],
            writeOptions: writeOptions
        )

        return document
    }

    private func writeDocumentUpdate(
        id: DocumentID,
        input: DocumentInput,
        accessMutation: EntryAccessMutation = .fullWrite
    ) async throws -> StoredDocument {
        guard let existingRecord = try await currentDocumentRecord(
            id: id,
            operation: "update document"
        ) else {
            return try await writeNewDocument(input)
        }

        return try await writeDocumentUpdate(
            id: id,
            existingRecord: existingRecord,
            input: input,
            accessMutation: accessMutation
        )
    }

    private func writeDocumentUpdate(
        id: DocumentID,
        existingRecord: MetaBrainDocumentRecord,
        input: DocumentInput,
        accessMutation: EntryAccessMutation = .fullWrite
    ) async throws -> StoredDocument {
        if let existingPathID = try await documentID(forPath: input.path),
           existingPathID != id {
            throw MetaBrainStoreError.pathAlreadyExists(input.path, existingID: existingPathID)
        }

        let existing = existingRecord.document
        let (nextVersion, overflow) = existing.currentVersion.addingReportingOverflow(1)
        guard !overflow else {
            throw MetaBrainStoreError.documentVersionExhausted(existing.path)
        }

        var input = input
        input.markdown = input.markdown ?? existing.markdown
        if existing.path.hasMarkdownExtension, !input.path.hasMarkdownExtension, input.markdown == nil {
            input.markdown = true
        }
        let now = Date()
        let document = StoredDocument(
            id: id,
            path: input.path,
            title: input.title,
            body: input.body,
            tags: input.tags,
            metadata: input.metadata,
            references: input.references,
            currentVersion: nextVersion,
            createdAt: existing.createdAt,
            updatedAt: now,
            markdown: input.markdown
        )
        let record = MetaBrainDocumentRecord(
            document: document,
            retention: input.retention ?? existingRecord.retention
        )
        let version = DocumentVersion(
            documentID: id,
            sequence: document.currentVersion,
            snapshot: input,
            createdAt: now
        )
        let removedPath: DocumentPath?
        if existing.path == input.path {
            removedPath = nil
        } else {
            removedPath = existing.path
        }
        let prunedVersions = try await prunedVersionRecords(
            id: id,
            appending: version,
            policy: record.retention
        )
        let entryMetadata = try await updatedEntryMetadata(
            for: document,
            accessMutation: accessMutation
        )

        try await writeDocumentBatch(
            record: record,
            version: version,
            entryMetadata: entryMetadata,
            previousRecord: existingRecord,
            removedPath: removedPath,
            prunedVersions: prunedVersions
        )

        return document
    }

    private func patchedDocumentInput(
        for request: DocumentPatchRequest
    ) async throws -> (id: DocumentID, input: DocumentInput) {
        guard let id = try await documentID(for: request.reference),
              let record = try await documentRecord(id: id) else {
            throw MetaBrainPatchError.documentNotFound
        }

        let document = record.document
        let patchedBody = try UnifiedTextPatch(request.unifiedDiff).applying(to: document.body)
        let input = DocumentInput(
            path: document.path,
            title: document.title,
            body: patchedBody,
            tags: document.tags,
            metadata: document.metadata,
            references: document.references,
            retention: request.retention
        )

        return (id: id, input: input)
    }

    private func writeDocumentBatch(
        record: MetaBrainDocumentRecord,
        version: DocumentVersion,
        entryMetadata: DocumentEntryMetadata,
        previousRecord: MetaBrainDocumentRecord?,
        removedPath: DocumentPath?,
        prunedVersions: [DocumentVersion],
        writeOptions: Database.WriteOptions = .default
    ) async throws {
        let document = record.document
        let documentKey = MetaBrainKeyspace.document(id: document.id)
        let pathKey = MetaBrainKeyspace.documentPath(document.path)
        let versionKey = MetaBrainKeyspace.version(
            id: document.id,
            sequence: version.sequence
        )
        let encodedRecord = try compressedData(record)
        let encodedVersion = try compressedData(version)
        let encodedEntryMetadata = try compressedData(entryMetadata)
        let encodedID = Data(document.id.rawValue.utf8)
        let staleChunkRecords = try await currentChunkRecordEntries(for: document.id)
        try staleChunkRecords.requireCurrentSchemaVersions(operation: "update document chunks")
        let staleChunkKeys = staleChunkRecords.map(\.key)
        let staleIndexKeys = try await staleIndexKeys(
            for: previousRecord?.document,
            staleChunks: staleChunkRecords.map(\.payload)
        )
        let staleReferenceKeys = try await staleReferenceKeys(sourceID: document.id)
        let citationEdit = try await citationEdit(replacing: previousRecord?.document, with: document)
        let treeUpdate = try await incrementalTreeUpdate(
            replacing: document,
            removedPath: removedPath
        )
        let chunks = Self.chunkRecords(for: document)
        let encodedChunks = try chunks.map { chunk in
            (
                key: MetaBrainKeyspace.currentChunk(id: document.id, ordinal: chunk.ordinal),
                value: try compressedData(chunk)
            )
        }
        let indexKeys = try await currentIndexKeys(for: document, chunks: chunks)
        try await ensureSearchFieldIndex()
        let previousFieldKeys = previousRecord.map { Self.searchFieldKeys(for: $0.document) } ?? []
        let fieldKeys = Self.searchFieldKeys(for: document)
        let removedFieldKeys = previousFieldKeys.subtracting(fieldKeys)
        let addedFieldKeys = fieldKeys.subtracting(previousFieldKeys)
        let updatedDocumentCount = if previousRecord == nil {
            try await updatedSearchDocumentCount(by: 1)
        } else {
            nil as Data?
        }

        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            try await records.write(writeOptions: writeOptions) { batch in
                for key in staleChunkKeys + staleIndexKeys + staleReferenceKeys {
                    try batch.deleteValue(forKey: key)
                }
                for key in citationEdit.removals { try batch.deleteValue(forKey: key) }
                for (key, value) in citationEdit.puts { try batch.put(value, forKey: key) }

                try batch.put(encodedRecord, forKey: documentKey)
                try batch.put(
                    encodedEntryMetadata,
                    forKey: MetaBrainKeyspace.documentMetadata(id: document.id)
                )
                try batch.put(encodedID, forKey: pathKey)
                try batch.put(encodedVersion, forKey: versionKey)

                for chunk in encodedChunks {
                    try batch.put(chunk.value, forKey: chunk.key)
                }

                for key in indexKeys {
                    try batch.put(Self.emptyIndexValue, forKey: key)
                }
                for key in removedFieldKeys {
                    try batch.deleteValue(forKey: key)
                }
                for key in addedFieldKeys {
                    try batch.put(Self.emptyIndexValue, forKey: key)
                }
                if let updatedDocumentCount {
                    try batch.put(updatedDocumentCount, forKey: MetaBrainKeyspace.searchDocumentCount)
                }

                for key in treeUpdate.removedKeys {
                    try batch.deleteValue(forKey: key)
                }

                for record in treeUpdate.records {
                    try batch.put(record.value, forKey: record.key)
                }

                if let removedPath {
                    try batch.deleteValue(forKey: MetaBrainKeyspace.documentPath(removedPath))
                }

                for prunedVersion in prunedVersions {
                    try batch.deleteValue(forKey: MetaBrainKeyspace.version(
                        id: prunedVersion.documentID,
                        sequence: prunedVersion.sequence
                    ))
                }
            }
        }
    }

    private func deleteDocumentRecord(_ record: MetaBrainDocumentRecord) async throws {
        let document = record.document
        let staleChunkRecords = try await currentChunkRecordEntries(for: document.id)
        try staleChunkRecords.requireCurrentSchemaVersions(operation: "delete document chunks")
        let staleChunkKeys = staleChunkRecords.map(\.key)
        let staleIndexKeys = try await staleIndexKeys(
            for: document,
            staleChunks: staleChunkRecords.map(\.payload)
        )
        let staleReferenceKeys = try await staleReferenceKeys(sourceID: document.id)
        let staleBacklinkKeys = try await staleBacklinkKeys(targetID: document.id)
        let citationEdit = try await citationEdit(replacing: document, with: nil)
        let versionRecords = try await versionRecordEntries(for: document.id)
        try versionRecords.requireCurrentSchemaVersions(operation: "delete document versions")
        let versionKeys = versionRecords.map(\.key)
        let entryMetadata = try await entryMetadataStoredRecord(for: document)
        try entryMetadata?.requireCurrentSchemaVersion(operation: "delete document metadata")
        let treeUpdate = try await incrementalTreeUpdate(removing: document)
        try await ensureSearchFieldIndex()
        let fieldKeys = Self.searchFieldKeys(for: document)
        let updatedDocumentCount = try await updatedSearchDocumentCount(by: -1)

        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            try await records.write { batch in
                for key in staleChunkKeys
                    + staleIndexKeys
                    + staleReferenceKeys
                    + staleBacklinkKeys
                    + versionKeys {
                    try batch.deleteValue(forKey: key)
                }
                for key in citationEdit.removals { try batch.deleteValue(forKey: key) }
                for (key, value) in citationEdit.puts { try batch.put(value, forKey: key) }

                try batch.deleteValue(forKey: MetaBrainKeyspace.document(id: document.id))
                try batch.deleteValue(forKey: MetaBrainKeyspace.documentMetadata(id: document.id))
                try batch.deleteValue(forKey: MetaBrainKeyspace.documentPath(document.path))
                for key in fieldKeys {
                    try batch.deleteValue(forKey: key)
                }
                try batch.put(updatedDocumentCount, forKey: MetaBrainKeyspace.searchDocumentCount)

                for key in treeUpdate.removedKeys {
                    try batch.deleteValue(forKey: key)
                }

                for record in treeUpdate.records {
                    try batch.put(record.value, forKey: record.key)
                }
            }
        }
    }

    private func pruneVersions(
        id: DocumentID,
        policy: VersionRetentionPolicy
    ) async throws -> PruneResult {
        let versionRecords = try await versionRecordEntries(for: id)
        try versionRecords.requireCurrentSchemaVersions(operation: "prune versions")
        let versions = versionRecords.map(\.payload)
        guard !versions.isEmpty else {
            return PruneResult(prunedVersionCount: 0, retainedVersionCount: 0)
        }

        let prunedVersions = prunedVersionRecords(from: versions, policy: policy)

        guard !prunedVersions.isEmpty else {
            return PruneResult(
                prunedVersionCount: 0,
                retainedVersionCount: versions.count
            )
        }

        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            try await records.write { batch in
                for version in prunedVersions {
                    try batch.deleteValue(forKey: MetaBrainKeyspace.version(
                        id: version.documentID,
                        sequence: version.sequence
                    ))
                }
            }
        }

        return PruneResult(
            prunedVersionCount: prunedVersions.count,
            retainedVersionCount: versions.count - prunedVersions.count
        )
    }

    private func prunedVersionRecords(
        id: DocumentID,
        appending version: DocumentVersion,
        policy: VersionRetentionPolicy
    ) async throws -> [DocumentVersion] {
        let existingRecords = try await versionRecordEntries(for: id)
        try existingRecords.requireCurrentSchemaVersions(operation: "update document versions")

        return prunedVersionRecords(
            from: existingRecords.map(\.payload) + [version],
            policy: policy
        )
    }

    private func prunedVersionRecords(
        from versions: [DocumentVersion],
        policy: VersionRetentionPolicy
    ) -> [DocumentVersion] {
        let retainedSequences = retainedVersionSequences(
            from: versions,
            policy: policy,
            currentSequence: versions.map(\.sequence).max()!
        )

        return versions.filter { !retainedSequences.contains($0.sequence) }
    }

    private func retainedVersionSequences(
        from versions: [DocumentVersion],
        policy: VersionRetentionPolicy,
        currentSequence: UInt64
    ) -> Set<UInt64> {
        switch policy {
        case .keepAll:
            return Set(versions.map(\.sequence))

        case .keepMostRecent(let count):
            let retainedCount = max(1, count)
            let retained = versions
                .sorted { $0.sequence > $1.sequence }
                .prefix(retainedCount)
                .map(\.sequence)
            return Set(retained).union(pinnedSequences(from: versions)).union([currentSequence])

        case .keepWithin(let interval):
            let cutoff = Date().addingTimeInterval(-interval)
            let retained = versions
                .filter { $0.createdAt >= cutoff || $0.sequence == currentSequence || $0.isPinned }
                .map(\.sequence)
            return Set(retained)
        }
    }

    private func pinnedSequences(from versions: [DocumentVersion]) -> Set<UInt64> {
        Set(versions.filter(\.isPinned).map(\.sequence))
    }

    private func documentID(for reference: DocumentReference) async throws -> DocumentID? {
        switch reference {
        case .documentID(let id):
            return id
        case .path(let path):
            return try await documentID(forPath: path)
        case .externalURL:
            return nil
        }
    }

    private func documentID(forPath path: DocumentPath) async throws -> DocumentID? {
        guard let data = try await rawValue(forKey: MetaBrainKeyspace.documentPath(path)),
              let rawID = String(data: data, encoding: .utf8) else {
            return nil
        }

        return try DocumentID(rawValue: rawID)
    }

    private func documentRecord(id: DocumentID) async throws -> MetaBrainDocumentRecord? {
        try await documentStoredRecord(id: id)?.payload
    }

    private func currentDocumentRecord(
        id: DocumentID,
        operation: String
    ) async throws -> MetaBrainDocumentRecord? {
        guard let record = try await documentStoredRecord(id: id) else {
            return nil
        }

        try record.requireCurrentSchemaVersion(operation: operation)
        return record.payload
    }

    private func documentStoredRecord(id: DocumentID) async throws -> MetaBrainStoredRecord<MetaBrainDocumentRecord>? {
        try await compressedStoredRecord(
            forKey: MetaBrainKeyspace.document(id: id),
            as: MetaBrainDocumentRecord.self
        )
    }

    private func entryMetadataRecord(for document: StoredDocument) async throws -> DocumentEntryMetadata {
        guard let metadata = try await entryMetadataStoredRecord(for: document) else {
            return Self.defaultEntryMetadata(for: document)
        }

        return Self.rederivedEntryMetadata(metadata.payload, for: document)
    }

    private func entryMetadataStoredRecord(
        for document: StoredDocument
    ) async throws -> MetaBrainStoredRecord<DocumentEntryMetadata>? {
        try await compressedStoredRecord(
            forKey: MetaBrainKeyspace.documentMetadata(id: document.id),
            as: DocumentEntryMetadata.self
        )
    }

    private func updatedEntryMetadata(
        for document: StoredDocument,
        accessMutation: EntryAccessMutation
    ) async throws -> DocumentEntryMetadata {
        let storedMetadata = try await entryMetadataStoredRecord(for: document)
        try storedMetadata?.requireCurrentSchemaVersion(operation: "update document metadata")

        var metadata = if let storedMetadata {
            Self.rederivedEntryMetadata(storedMetadata.payload, for: document)
        } else {
            Self.defaultEntryMetadata(for: document)
        }

        switch accessMutation {
        case .fullWrite:
            metadata.access.fullWriteCount = Self.incremented(metadata.access.fullWriteCount)
        case .patch:
            metadata.access.patchCount = Self.incremented(metadata.access.patchCount)
        }

        return Self.rederivedEntryMetadata(metadata, for: document)
    }

    private func writeEntryMetadata(
        for document: StoredDocument,
        readDelta: UInt64
    ) async throws -> DocumentEntryMetadata {
        let storedMetadata = try await entryMetadataStoredRecord(for: document)
        if let storedMetadata, !storedMetadata.schemaVersion.isCurrent {
            return Self.rederivedEntryMetadata(storedMetadata.payload, for: document)
        }

        var metadata = if let storedMetadata {
            Self.rederivedEntryMetadata(storedMetadata.payload, for: document)
        } else {
            Self.defaultEntryMetadata(for: document)
        }
        metadata.access.readCount = Self.incremented(metadata.access.readCount, by: readDelta)
        metadata = Self.rederivedEntryMetadata(metadata, for: document)

        try await writeRawValue(
            try compressedData(metadata),
            forKey: MetaBrainKeyspace.documentMetadata(id: document.id)
        )

        return metadata
    }

    private func versionRecords(for id: DocumentID) async throws -> [DocumentVersion] {
        try await versionRecordEntries(for: id).map(\.payload)
    }

    private func versionRecordEntries(for id: DocumentID) async throws -> [MetaBrainKeyedStoredRecord<DocumentVersion>] {
        let prefix = MetaBrainKeyspace.versionPrefix(id: id)
        return try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            return try await records
                .scanEncodedPrefix(Data(prefix.utf8), readOptions: Self.bulkReadOptions)
                .map {
                    try MetaBrainKeyedStoredRecord(
                        key: $0.key,
                        record: decodeCompressedRecord($0.value, as: DocumentVersion.self)
                    )
                }
        }
    }

    private func currentChunkRecords(for id: DocumentID) async throws -> [MetaBrainChunkRecord] {
        try await currentChunkRecordEntries(for: id).map(\.payload)
    }

    private func currentChunkRecordEntries(for id: DocumentID) async throws -> [MetaBrainKeyedStoredRecord<MetaBrainChunkRecord>] {
        return try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            return try await records
                .scanEncodedPrefix(
                    Data(MetaBrainKeyspace.currentChunkPrefix(id: id).utf8),
                    readOptions: Self.bulkReadOptions
                )
                .map {
                    try MetaBrainKeyedStoredRecord(
                        key: $0.key,
                        record: decodeCompressedRecord($0.value, as: MetaBrainChunkRecord.self)
                    )
                }
        }
    }

    private func ensureSearchFieldIndex() async throws {
        try await searchFieldIndex.prepare {
            try await self.backfillSearchFieldIndexIfNeeded()
        }
    }

    private func backfillSearchFieldIndexIfNeeded() async throws {
        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            let layout = try await records.value(forKey: MetaBrainKeyspace.searchFieldLayout)
            if layout == Self.currentSearchFieldLayout { return }
            if let layout, layout != Data([1]) {
                throw MetaBrainStoreError.operationFailed(
                    message: "Unrecognized search field index layout. Upgrade metaBrain to use this store's search index."
                )
            }

            if layout == nil {
                let fieldPrefix = Data(MetaBrainKeyspace.prefix(.searchFieldTerm).utf8)
                guard try await records.value(forKey: MetaBrainKeyspace.searchDocumentCount) == nil,
                      try await records.scanEncodedPrefixKeys(fieldPrefix, readOptions: Self.bulkReadOptions).isEmpty else {
                    throw MetaBrainStoreError.operationFailed(message: "Search field index exists without its layout marker.")
                }
            }

            let documentPrefix = Data(MetaBrainKeyspace.prefix(.documentID).utf8)
            let documentKeys = try await records.scanEncodedPrefixKeys(documentPrefix, readOptions: Self.bulkReadOptions)
            var fieldKeys: [String] = []
            var documentCount = 0
            for key in documentKeys {
                guard let data = try await records.value(forKey: key, readOptions: Self.bulkReadOptions) else {
                    continue
                }
                let document = try decodeCompressedRecord(data, as: MetaBrainDocumentRecord.self).payload.document
                if layout == nil {
                    fieldKeys.append(contentsOf: Self.searchFieldKeys(for: document))
                }
                fieldKeys.append(contentsOf: MarkdownProperties.filterKeys(for: document))
                documentCount += 1
            }

            try await records.write { [fieldKeys, documentCount] batch in
                for key in fieldKeys {
                    try batch.put(Self.emptyIndexValue, forKey: key)
                }
                try batch.put(Data(String(documentCount).utf8), forKey: MetaBrainKeyspace.searchDocumentCount)
                try batch.put(Self.currentSearchFieldLayout, forKey: MetaBrainKeyspace.searchFieldLayout)
            }
        }
    }

    private func indexedSearchDocumentCount() async throws -> Int {
        guard let data = try await rawValue(forKey: MetaBrainKeyspace.searchDocumentCount),
              let text = String(data: data, encoding: .utf8),
              let count = Int(text), count >= 0 else {
            throw MetaBrainStoreError.operationFailed(message: "Missing or invalid search corpus document count.")
        }
        return count
    }

    private func updatedSearchDocumentCount(by change: Int) async throws -> Data {
        let (count, overflow) = try await indexedSearchDocumentCount().addingReportingOverflow(change)
        guard !overflow, count >= 0 else {
            throw MetaBrainStoreError.operationFailed(message: "Invalid search corpus document count adjustment.")
        }
        return Data(String(count).utf8)
    }

    private static func searchFieldKeys(for document: StoredDocument) -> Set<String> {
        let terms = Set(tokenize(document.path.rawValue) + tokenize(document.title ?? ""))
        return Set(terms.map { MetaBrainKeyspace.searchFieldTerm($0, id: document.id) })
    }

    private func ensureTreeIndex() async throws {
        try await treeIndex.prepare {
            try await self.migrateTreeIndexIfNeeded()
        }
    }

    private func migrateTreeIndexIfNeeded() async throws {
        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            if let layout = try await records.value(forKey: MetaBrainKeyspace.treeLayout) {
                guard layout == Self.caseSensitiveTreeLayout else {
                    throw MetaBrainStoreError.operationFailed(
                        message: "Unrecognized tree index layout. Upgrade metaBrain to use this store's tree."
                    )
                }
                return
            }

            var rebuilt: [String: MetaBrainTreeRecord] = [:]
            let documentPrefix = Data(MetaBrainKeyspace.prefix(.documentID).utf8)
            let documentKeys = try await records.scanEncodedPrefixKeys(documentPrefix, readOptions: Self.bulkReadOptions)
            for key in documentKeys {
                guard let data = try await records.value(forKey: key, readOptions: Self.bulkReadOptions) else {
                    continue
                }
                let document = try decodeCompressedRecord(data, as: MetaBrainDocumentRecord.self).payload.document
                for path in Self.treeBranchPaths(for: document.path) {
                    let key = MetaBrainKeyspace.tree(parentPath: path.parent!, name: path.name)
                    if path == document.path {
                        rebuilt[key] = MetaBrainTreeRecord(
                            path: path,
                            hasChildren: rebuilt[key]?.entry.hasChildren ?? false,
                            document: document
                        )
                    } else {
                        let directory = MetaBrainTreeRecord(path: path, hasChildren: true)
                        rebuilt[key, default: directory].entry.hasChildren = true
                    }
                }
            }

            var obsoleteKeys: [String] = []
            let treePrefix = Data(MetaBrainKeyspace.prefix(.tree).utf8)
            for row in try await records.scanEncodedPrefix(treePrefix, readOptions: Self.bulkReadOptions) {
                let stored = try decodeCompressedRecord(row.value, as: MetaBrainTreeRecord.self)
                // A byte-for-byte retained row can keep compatible future fields.
                if stored.payload == rebuilt[row.key] {
                    rebuilt.removeValue(forKey: row.key)
                } else {
                    try stored.requireCurrentSchemaVersion(operation: "rebuild document tree")
                    if rebuilt[row.key] == nil {
                        obsoleteKeys.append(row.key)
                    }
                }
            }

            let updatedRecords = try rebuilt.map { (key: $0.key, value: try compressedData($0.value)) }
            try await records.write { [obsoleteKeys] batch in
                for key in obsoleteKeys {
                    try batch.deleteValue(forKey: key)
                }
                for record in updatedRecords {
                    try batch.put(record.value, forKey: record.key)
                }
                try batch.put(Self.caseSensitiveTreeLayout, forKey: MetaBrainKeyspace.treeLayout)
            }
        }
    }

    private func childTreeEntries(of path: DocumentPath) async throws -> [DocumentTreeEntry] {
        try await childTreeRecordEntries(of: path)
            .map { $0.payload.entry }
            .sorted { $0.path < $1.path }
    }

    private func childTreeRecordEntries(of path: DocumentPath) async throws -> [MetaBrainKeyedStoredRecord<MetaBrainTreeRecord>] {
        let prefix = MetaBrainKeyspace.treePrefix(parentPath: path)

        return try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            return try await records
                .scanEncodedPrefix(Data(prefix.utf8), readOptions: Self.bulkReadOptions)
                .map {
                    try MetaBrainKeyedStoredRecord(
                        key: $0.key,
                        record: decodeCompressedRecord($0.value, as: MetaBrainTreeRecord.self)
                    )
                }
        }
    }

    private func flattenedTreeEntries(
        under path: DocumentPath,
        directoriesOnly: Bool,
        maxDepth: Int?,
        currentDepth: Int
    ) async throws -> [DocumentTreeEntry] {
        if let maxDepth, currentDepth >= maxDepth {
            return []
        }

        let children = try await childTreeEntries(of: path)
        var entries: [DocumentTreeEntry] = []

        for child in children {
            if !directoriesOnly || child.hasChildren {
                entries.append(child)
            }

            if child.hasChildren {
                entries += try await flattenedTreeEntries(
                    under: child.path,
                    directoriesOnly: directoriesOnly,
                    maxDepth: maxDepth,
                    currentDepth: currentDepth + 1
                )
            }
        }

        return entries
    }

    private func incrementalTreeUpdate(
        replacing document: StoredDocument,
        removedPath: DocumentPath?
    ) async throws -> (removedKeys: [String], records: [(key: String, value: Data)]) {
        try await ensureTreeIndex()
        let affectedPaths = Self.treeAffectedPaths(
            newPath: document.path,
            removedPath: removedPath
        )
        try await requireCurrentTreeRecords(for: affectedPaths, operation: "update document tree")

        var removedKeys: [String] = []
        var records: [(key: String, value: Data)] = []

        for path in affectedPaths {
            let key = MetaBrainKeyspace.tree(parentPath: path.parent!, name: path.name)
            guard let record = try await treeRecordAfterWrite(
                for: path,
                replacing: document,
                removedPath: removedPath
            ) else {
                removedKeys.append(key)
                continue
            }

            records.append((key: key, value: try compressedData(record)))
        }

        return (removedKeys, records)
    }

    private func incrementalTreeUpdate(
        removing document: StoredDocument
    ) async throws -> (removedKeys: [String], records: [(key: String, value: Data)]) {
        try await ensureTreeIndex()
        let affectedPaths = Self.treeBranchPaths(for: document.path)
        try await requireCurrentTreeRecords(for: affectedPaths, operation: "delete document tree")

        var removedKeys: [String] = []
        var records: [(key: String, value: Data)] = []

        for path in affectedPaths.sorted(by: { lhs, rhs in
            lhs.rawValue.count > rhs.rawValue.count
        }) {
            let key = MetaBrainKeyspace.tree(parentPath: path.parent!, name: path.name)
            guard let record = try await treeRecordAfterDelete(
                for: path,
                removing: document
            ) else {
                removedKeys.append(key)
                continue
            }

            records.append((key: key, value: try compressedData(record)))
        }

        return (removedKeys, records)
    }

    private func requireCurrentTreeRecords(
        for paths: [DocumentPath],
        operation: String
    ) async throws {
        for path in paths {
            let key = MetaBrainKeyspace.tree(parentPath: path.parent!, name: path.name)
            if let record = try await compressedStoredRecord(forKey: key, as: MetaBrainTreeRecord.self) {
                try record.requireCurrentSchemaVersion(operation: operation)
            }
        }
    }

    private func treeRecordAfterWrite(
        for path: DocumentPath,
        replacing document: StoredDocument,
        removedPath: DocumentPath?
    ) async throws -> MetaBrainTreeRecord? {
        let documentAtPath: StoredDocument?
        if path == document.path {
            documentAtPath = document
        } else if path == removedPath {
            documentAtPath = nil
        } else if let id = try await documentID(forPath: path),
                  let record = try await documentRecord(id: id) {
            documentAtPath = record.document
        } else {
            documentAtPath = nil
        }

        let hasChildren = try await pathHasChildrenAfterWrite(
            path,
            replacing: document,
            removedPath: removedPath
        )

        guard documentAtPath != nil || hasChildren else {
            return nil
        }

        return MetaBrainTreeRecord(path: path, hasChildren: hasChildren, document: documentAtPath)
    }

    private func pathHasChildrenAfterWrite(
        _ path: DocumentPath,
        replacing document: StoredDocument,
        removedPath: DocumentPath?
    ) async throws -> Bool {
        if Self.path(document.path, isDescendantOf: path) {
            return true
        }

        let prefix = MetaBrainKeyspace.documentPathDescendantPrefix(path)
        for key in try await scanKeys(withPrefix: prefix) {
            let rawPath = String(key.dropFirst(MetaBrainKeyspace.prefix(.documentPath).count))
            guard let existingPath = try? DocumentPath(rawPath) else {
                continue
            }

            if existingPath == removedPath {
                continue
            }

            if existingPath != document.path {
                return true
            }
        }

        return false
    }

    private func treeRecordAfterDelete(
        for path: DocumentPath,
        removing document: StoredDocument
    ) async throws -> MetaBrainTreeRecord? {
        let documentAtPath: StoredDocument?
        if path == document.path {
            documentAtPath = nil
        } else if let id = try await documentID(forPath: path),
                  let record = try await documentRecord(id: id) {
            documentAtPath = record.document
        } else {
            documentAtPath = nil
        }

        let hasChildren = try await pathHasChildrenAfterDelete(path, removing: document)
        guard documentAtPath != nil || hasChildren else {
            return nil
        }

        return MetaBrainTreeRecord(path: path, hasChildren: hasChildren, document: documentAtPath)
    }

    private func pathHasChildrenAfterDelete(
        _ path: DocumentPath,
        removing document: StoredDocument
    ) async throws -> Bool {
        let prefix = MetaBrainKeyspace.documentPathDescendantPrefix(path)
        for key in try await scanKeys(withPrefix: prefix) {
            let rawPath = String(key.dropFirst(MetaBrainKeyspace.prefix(.documentPath).count))
            guard let existingPath = try? DocumentPath(rawPath) else {
                continue
            }

            if existingPath != document.path {
                return true
            }
        }

        return false
    }

    private func staleIndexKeys(
        for document: StoredDocument?,
        staleChunks: [MetaBrainChunkRecord]
    ) async throws -> [String] {
        guard let document else {
            return []
        }

        var keys = Set<String>()
        for chunk in staleChunks {
            for term in Self.tokenize(chunk.text) {
                keys.insert(MetaBrainKeyspace.term(term, id: document.id, ordinal: chunk.ordinal))
            }
        }
        keys.formUnion(MarkdownProperties.filterKeys(for: document))

        return keys.sorted()
    }

    private func staleReferenceKeys(sourceID: DocumentID) async throws -> [String] {
        let outboundPrefix = MetaBrainKeyspace.outboundReferencePrefix(sourceID: sourceID)
        let outboundKeys = try await scanKeys(withPrefix: outboundPrefix)
        var keys = Set(outboundKeys)

        for key in outboundKeys {
            let rawTargetID = String(key.dropFirst(outboundPrefix.count))
            let targetID = try DocumentID(rawValue: rawTargetID)
            keys.insert(MetaBrainKeyspace.inboundReference(targetID: targetID, sourceID: sourceID))
        }

        return keys.sorted()
    }

    private func refreshPathReferenceIndexes(for document: StoredDocument) async throws {
        guard document.references.contains(where: { reference in
            if case .path = reference { true } else { false }
        }) else {
            return
        }

        let sourceID = document.id
        let resolvedIDs = try await resolvedReferenceIDs(from: document.references)
        let indexedIDs = try await Set(nativeOutboundReferences(from: sourceID))
        guard resolvedIDs != indexedIDs else {
            return
        }

        let removedIDs = indexedIDs.subtracting(resolvedIDs)
        let addedIDs = resolvedIDs.subtracting(indexedIDs)
        try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            try await records.write { batch in
                for targetID in removedIDs {
                    try batch.deleteValue(forKey: MetaBrainKeyspace.outboundReference(sourceID: sourceID, targetID: targetID))
                    try batch.deleteValue(forKey: MetaBrainKeyspace.inboundReference(targetID: targetID, sourceID: sourceID))
                }
                for targetID in addedIDs {
                    try batch.put(Self.emptyIndexValue, forKey: MetaBrainKeyspace.outboundReference(sourceID: sourceID, targetID: targetID))
                    try batch.put(Self.emptyIndexValue, forKey: MetaBrainKeyspace.inboundReference(targetID: targetID, sourceID: sourceID))
                }
            }
        }
    }

    private func staleBacklinkKeys(targetID: DocumentID) async throws -> [String] {
        let inboundPrefix = MetaBrainKeyspace.inboundReferencePrefix(targetID: targetID)
        let inboundKeys = try await scanKeys(withPrefix: inboundPrefix)
        var keys = Set(inboundKeys)

        for key in inboundKeys {
            let rawSourceID = String(key.dropFirst(inboundPrefix.count))
            let sourceID = try DocumentID(rawValue: rawSourceID)
            keys.insert(MetaBrainKeyspace.outboundReference(sourceID: sourceID, targetID: targetID))
        }

        return keys.sorted()
    }

    private func currentIndexKeys(
        for document: StoredDocument,
        chunks: [MetaBrainChunkRecord]
    ) async throws -> [String] {
        var keys = Set<String>()

        for chunk in chunks {
            for term in Self.tokenize(chunk.text) {
                keys.insert(MetaBrainKeyspace.term(term, id: document.id, ordinal: chunk.ordinal))
            }
        }
        keys.formUnion(MarkdownProperties.filterKeys(for: document))
        for targetID in try await resolvedReferenceIDs(from: document.references) {
            keys.insert(MetaBrainKeyspace.outboundReference(sourceID: document.id, targetID: targetID))
            keys.insert(MetaBrainKeyspace.inboundReference(targetID: targetID, sourceID: document.id))
        }

        return keys.sorted()
    }

    private func resolvedReferenceIDs(from references: [DocumentReference]) async throws -> Set<DocumentID> {
        var ids = Set<DocumentID>()

        for reference in references {
            switch reference {
            case .documentID(let id):
                ids.insert(id)
            case .path(let path):
                if let id = try await documentID(forPath: path) {
                    ids.insert(id)
                }
            case .externalURL:
                continue
            }
        }

        return ids
    }

    private func documentIDs(forIndexPrefix prefix: String) async throws -> [DocumentID] {
        let keys = try await scanKeys(withPrefix: prefix)
        let ids = try keys.map { key in
            let suffix = key.dropFirst(prefix.count)
            let parts = suffix.split(separator: "/")
            let rawID: String
            if let first = parts.first {
                rawID = String(first)
            } else {
                rawID = ""
            }
            return try DocumentID(rawValue: rawID)
        }

        return Array(Set(ids)).sorted()
    }

    private func filteredDocumentIDs(for query: SearchQuery) async throws -> Set<DocumentID>? {
        if !query.tags.isEmpty || !query.metadata.isEmpty {
            try await ensureSearchFieldIndex()
        }
        var filteredIDs: Set<DocumentID>?

        for tag in query.tags {
            let ids = Set(try await documentIDs(tagged: tag))
            if let existingIDs = filteredIDs {
                filteredIDs = existingIDs.intersection(ids)
            } else {
                filteredIDs = ids
            }
        }

        for (key, value) in query.metadata {
            let ids = Set(try await documentIDs(metadataKey: key, value: value))
            if let existingIDs = filteredIDs {
                filteredIDs = existingIDs.intersection(ids)
            } else {
                filteredIDs = ids
            }
        }

        return filteredIDs
    }

    private func termPostings(for term: String) async throws -> [MetaBrainSearchCandidate] {
        let normalized = Self.normalizedTerm(term)
        let prefix = MetaBrainKeyspace.termPrefix(normalized)
        return try await scanKeys(withPrefix: prefix).map { key in
            let suffix = key.dropFirst(prefix.count)
            let parts = suffix.split(separator: "/", maxSplits: 1).map(String.init)
            let rawID: String
            if let first = parts.first {
                rawID = first
            } else {
                rawID = ""
            }
            let id = try DocumentID(rawValue: rawID)

            let ordinal: UInt32
            if let rawOrdinal = parts.dropFirst().first,
               let parsedOrdinal = UInt32(rawOrdinal) {
                ordinal = parsedOrdinal
            } else {
                ordinal = 0
            }
            return MetaBrainSearchCandidate(documentID: id, chunkOrdinal: ordinal)
        }
    }

    private func searchResults(
        from candidates: [MetaBrainRankedSearchCandidate],
        query: SearchQuery
    ) async throws -> [SearchResult] {
        var linkedDocumentsByDocument: [DocumentID: [DocumentReference]] = [:]
        var backlinksByDocument: [DocumentID: [DocumentReference]] = [:]
        var results: [SearchResult] = []

        for candidate in candidates {
            let linkedDocuments: [DocumentReference]
            if query.includeLinkedDocuments {
                if let cachedReferences = linkedDocumentsByDocument[candidate.documentID] {
                    linkedDocuments = cachedReferences
                } else {
                    let references = try await outboundReferences(from: candidate.documentID)
                        .map(DocumentReference.documentID)
                    linkedDocumentsByDocument[candidate.documentID] = references
                    linkedDocuments = references
                }
            } else {
                linkedDocuments = []
            }

            let backlinks: [DocumentReference]
            if query.includeBacklinks {
                if let cachedReferences = backlinksByDocument[candidate.documentID] {
                    backlinks = cachedReferences
                } else {
                    let references = try await inboundReferences(to: candidate.documentID)
                        .map(DocumentReference.documentID)
                    backlinksByDocument[candidate.documentID] = references
                    backlinks = references
                }
            } else {
                backlinks = []
            }

            results.append(SearchResult(
                documentID: candidate.documentID,
                path: candidate.path,
                title: candidate.title,
                chunkOrdinal: candidate.chunkOrdinal,
                snippet: candidate.snippet,
                score: candidate.score,
                context: candidate.context,
                linkedDocuments: linkedDocuments,
                backlinks: backlinks
            ))
        }

        return results
    }

    private func scanKeys(withPrefix prefix: String) async throws -> [String] {
        return try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            return try await records
                .scanEncodedPrefixKeys(Data(prefix.utf8), readOptions: Self.bulkReadOptions)
        }
    }

    static func tokenize(_ text: String) -> [String] {
        var terms: [String] = []
        var current = ""

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty {
                    terms.append(current)
                    current = ""
                }
            }
        }

        if !current.isEmpty {
            terms.append(current)
        }

        return terms
    }

    private static func normalizedTerm(_ term: String) -> String {
        let terms = tokenize(term)
        guard let first = terms.first else {
            return ""
        }
        return first
    }

    private static func path(_ path: DocumentPath, matchesPrefix prefix: DocumentPath?) -> Bool {
        guard let prefix else {
            return true
        }

        if prefix.rawValue == "/" || path == prefix {
            return true
        }

        return path.rawValue.utf8.starts(with: (prefix.rawValue + "/").utf8)
    }

    private static func path(_ path: DocumentPath, isDescendantOf ancestor: DocumentPath) -> Bool {
        ancestor.rawValue != "/" && path.rawValue.utf8.starts(with: (ancestor.rawValue + "/").utf8)
    }

    private static func treeAffectedPaths(
        newPath: DocumentPath,
        removedPath: DocumentPath?
    ) -> [DocumentPath] {
        var paths = Set(treeBranchPaths(for: newPath))
        if let removedPath {
            paths.formUnion(treeBranchPaths(for: removedPath))
        }

        return paths.sorted { lhs, rhs in
            lhs.rawValue.count > rhs.rawValue.count
        }
    }

    private static func treeBranchPaths(for path: DocumentPath) -> [DocumentPath] {
        let segments = path.rawValue.split(separator: "/", omittingEmptySubsequences: true)
        return segments.indices.compactMap { index in
            try? DocumentPath("/" + segments.prefix(through: index).joined(separator: "/"))
        }
    }

    private static func contextChunks(
        around ordinal: UInt32,
        in chunks: [UInt32: MetaBrainChunkRecord]
    ) -> [SearchContextChunk] {
        let previous = ordinal > 0 ? chunks[ordinal - 1] : nil
        let next = ordinal < .max ? chunks[ordinal + 1] : nil
        return [previous, next].compactMap { chunk in
            chunk.map { SearchContextChunk(ordinal: $0.ordinal, text: $0.text) }
        }
    }

    private static func defaultEntryMetadata(
        for document: StoredDocument,
        access: DocumentAccessCounts = DocumentAccessCounts()
    ) -> DocumentEntryMetadata {
        DocumentEntryMetadata(
            featureFlags: entryFeatureFlags(for: document),
            access: access
        )
    }

    private static func rederivedEntryMetadata(
        _ metadata: DocumentEntryMetadata,
        for document: StoredDocument
    ) -> DocumentEntryMetadata {
        let preservedFeatureFlags = metadata.featureFlags.filter {
            !knownEntryFeatureFlags.contains($0)
        }

        return DocumentEntryMetadata(
            formatTag: metadata.formatTag,
            featureFlags: entryFeatureFlags(for: document) + preservedFeatureFlags,
            access: metadata.access
        )
    }

    private static func entryFeatureFlags(for document: StoredDocument) -> [String] {
        var flags = ["body"]

        if document.title != nil {
            flags.append("title")
        }
        if !document.tags.isEmpty {
            flags.append("tags")
        }
        if !document.metadata.isEmpty {
            flags.append("user-metadata")
        }
        if !document.references.isEmpty {
            flags.append("references")
        }

        return flags
    }

    private static let knownEntryFeatureFlags: Set<String> = [
        "body",
        "references",
        "tags",
        "title",
        "user-metadata"
    ]

    private static func incremented(_ value: UInt64, by delta: UInt64 = 1) -> UInt64 {
        let result = value.addingReportingOverflow(delta)
        return result.overflow ? .max : result.partialValue
    }

    private static func chunkRecords(for document: StoredDocument) -> [MetaBrainChunkRecord] {
        let text = document.body
        guard !text.isEmpty else {
            return [
                MetaBrainChunkRecord(
                    documentID: document.id,
                    versionSequence: document.currentVersion,
                    ordinal: 0,
                    text: "",
                    startOffset: 0,
                    endOffset: 0
                )
            ]
        }

        let count = text.count
        var chunks: [MetaBrainChunkRecord] = []
        var startOffset = 0
        var startIndex = text.startIndex
        var ordinal: UInt32 = 0

        while startOffset < count {
            let endOffset = min(startOffset + chunkTargetCharacterCount, count)
            let endIndex = text.index(startIndex, offsetBy: endOffset - startOffset)
            chunks.append(MetaBrainChunkRecord(
                documentID: document.id,
                versionSequence: document.currentVersion,
                ordinal: ordinal,
                text: String(text[startIndex..<endIndex]),
                startOffset: startOffset,
                endOffset: endOffset
            ))

            guard endOffset < count else {
                break
            }

            let nextStartOffset = max(startOffset + 1, endOffset - chunkOverlapCharacterCount)
            startIndex = text.index(startIndex, offsetBy: nextStartOffset - startOffset)
            startOffset = nextStartOffset
            ordinal += 1
        }

        return chunks
    }

    private func codec<Value: Codable & Sendable>(
        for type: Value.Type
    ) -> ZstdCodec<JSONCodec<MetaBrainRecordEnvelope<Value>>> {
        ZstdCodec(
            wrapping: JSONCodec<MetaBrainRecordEnvelope<Value>>(),
            compressionLevel: options.zstdCompressionLevel,
            storageStrategy: .adaptive(
                minimumCompressionSavingsRatio: options.zstdAdaptiveMinimumSavingsRatio
            )
        )
    }

    private func compressedData<Value: Codable & Sendable>(_ value: Value) throws -> Data {
        try codec(for: Value.self).encode(MetaBrainRecordEnvelope(payload: value))
    }

    private func decodeCompressedRecord<Value: Codable & Sendable>(
        _ data: Data,
        as type: Value.Type = Value.self
    ) throws -> MetaBrainStoredRecord<Value> {
        let envelope = try codec(for: type).decode(data)
        try envelope.schemaVersion.requireReadable()
        return MetaBrainStoredRecord(
            schemaVersion: envelope.schemaVersion,
            payload: envelope.payload
        )
    }

    static func mapLevelDBErrors<T: Sendable>(
        path: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as LevelDBError {
            throw storeError(from: error, path: path)
        }
    }

    static func storeError(from error: LevelDBError, path: String) -> MetaBrainStoreError {
        switch error {
        case .openFailed(let message):
            .openFailed(path: path, message: message)
        case .operationFailed(let message):
            .operationFailed(message: message)
        }
    }

    private static func referenceDescription(_ reference: DocumentReference) -> String {
        switch reference {
        case .documentID(let id):
            id.rawValue
        case .path(let path):
            path.rawValue
        case .externalURL(let url):
            url.absoluteString
        }
    }
}

private actor MetaBrainStoreDatabase {
    private var records: LevelDBStore<StringCodec, DataCodec>?

    init(_ records: LevelDBStore<StringCodec, DataCodec>) {
        self.records = records
    }

    func store() throws -> LevelDBStore<StringCodec, DataCodec> {
        guard let records else {
            throw MetaBrainStoreError.operationFailed(message: "metaBrain store is closed.")
        }

        return records
    }

    func close() {
        records = nil
    }
}

public enum MetaBrainRecordSchemaVersion: Codable, Equatable, Hashable, Sendable, Comparable, CustomStringConvertible {
    case unsupported(UInt8)
    case v1
    case future(UInt8)

    public static let current = MetaBrainRecordSchemaVersion.v1

    public init(rawValue: UInt8) {
        switch rawValue {
        case 1:
            self = .v1
        case 2...UInt8.max:
            self = .future(rawValue)
        default:
            self = .unsupported(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .unsupported(let version), .future(let version):
            version
        case .v1:
            1
        }
    }

    public var isCurrent: Bool {
        self == Self.current
    }

    public var isFuture: Bool {
        if case .future = self {
            return true
        }

        return false
    }

    public var description: String {
        "\(rawValue)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt8.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: MetaBrainRecordSchemaVersion, rhs: MetaBrainRecordSchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func requireReadable() throws {
        if case .unsupported(let version) = self {
            throw MetaBrainStoreError.unsupportedRecordSchemaVersion(version)
        }
    }
}

private struct MetaBrainStoredRecord<Payload: Sendable>: Sendable {
    var schemaVersion: MetaBrainRecordSchemaVersion
    var payload: Payload

    func requireCurrentSchemaVersion(operation: String) throws {
        try schemaVersion.requireReadable()
        guard schemaVersion.isCurrent else {
            throw MetaBrainStoreError.newerRecordSchemaVersion(
                schemaVersion.rawValue,
                operation: operation
            )
        }
    }
}

private struct MetaBrainKeyedStoredRecord<Payload: Sendable>: Sendable {
    var key: String
    var schemaVersion: MetaBrainRecordSchemaVersion
    var payload: Payload

    init(key: String, record: MetaBrainStoredRecord<Payload>) {
        self.key = key
        self.schemaVersion = record.schemaVersion
        self.payload = record.payload
    }

    func requireCurrentSchemaVersion(operation: String) throws {
        try MetaBrainStoredRecord(
            schemaVersion: schemaVersion,
            payload: payload
        ).requireCurrentSchemaVersion(operation: operation)
    }
}

private extension Sequence {
    func requireCurrentSchemaVersions<Payload>(
        operation: String
    ) throws where Element == MetaBrainKeyedStoredRecord<Payload> {
        for record in self {
            try record.requireCurrentSchemaVersion(operation: operation)
        }
    }
}

struct MetaBrainRecordEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    static var currentSchemaVersion: MetaBrainRecordSchemaVersion { .current }

    var schemaVersion: MetaBrainRecordSchemaVersion
    var payload: Payload

    init(schemaVersion: MetaBrainRecordSchemaVersion = currentSchemaVersion, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    init(schemaVersion: UInt8, payload: Payload) {
        self.init(schemaVersion: MetaBrainRecordSchemaVersion(rawValue: schemaVersion), payload: payload)
    }
}

private actor MetaBrainWriteCoordinator {
    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if active {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            active = true
        }

        defer {
            if waiters.isEmpty {
                active = false
            } else {
                // Keep writes reserved as ownership passes to the next waiter.
                waiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

private actor MetaBrainIndexPreparation {
    private var preparation: Task<Void, Error>?

    func prepare(_ operation: @Sendable @escaping () async throws -> Void) async throws {
        if let preparation {
            return try await preparation.value
        }

        let task = Task {
            do {
                try await operation()
            } catch {
                preparation = nil
                throw error
            }
        }
        preparation = task
        try await task.value
    }
}

private enum EntryAccessMutation: Sendable {
    case fullWrite
    case patch
}

private struct MetaBrainDocumentRecord: Codable, Equatable, Sendable {
    var document: StoredDocument
    var retention: VersionRetentionPolicy

    func bodyReplacement(_ body: String) -> DocumentInput {
        DocumentInput(
            path: document.path,
            title: document.title,
            body: body,
            tags: document.tags,
            metadata: document.metadata,
            references: document.references,
            retention: retention
        )
    }

    func matches(_ input: DocumentInput) -> Bool {
        document.path == input.path && document.title == input.title && document.tags == input.tags
            && document.metadata == input.metadata && document.references == input.references
            && retention == (input.retention ?? retention) && document.body.utf8.elementsEqual(input.body.utf8)
            && document.markdown == (input.markdown ?? document.markdown)
    }
}

private struct MetaBrainTreeRecord: Codable, Equatable, Sendable {
    var parentPath: DocumentPath
    var entry: DocumentTreeEntry

    init(path: DocumentPath, hasChildren: Bool, document: StoredDocument? = nil) {
        parentPath = path.parent!
        entry = DocumentTreeEntry(
            path: path,
            name: path.name,
            hasChildren: hasChildren,
            documentID: document?.id,
            createdAt: document?.createdAt,
            updatedAt: document?.updatedAt
        )
    }
}

struct MetaBrainChunkRecord: Codable, Equatable, Sendable {
    var documentID: DocumentID
    var versionSequence: UInt64
    var ordinal: UInt32
    var text: String
    var startOffset: Int
    var endOffset: Int
}

private struct MetaBrainSearchCandidate: Hashable, Sendable {
    var documentID: DocumentID
    var chunkOrdinal: UInt32
}

private struct MetaBrainRankedSearchCandidate: Sendable {
    var documentID: DocumentID
    var path: DocumentPath
    var title: String?
    var chunkOrdinal: UInt32
    var snippet: String
    var context: [SearchContextChunk]
    var score: Double
}

private struct MetaBrainSearchTopCandidates: Sendable {
    private let limit: Int
    private var candidates: [MetaBrainRankedSearchCandidate] = []

    init(limit: Int) {
        self.limit = limit
    }

    mutating func insert(_ candidate: MetaBrainRankedSearchCandidate) {
        if let insertionIndex = candidates.firstIndex(where: { Self.ranksBefore(candidate, $0) }) {
            candidates.insert(candidate, at: insertionIndex)
            if candidates.count > limit {
                candidates.removeLast()
            }
        } else if candidates.count < limit {
            candidates.append(candidate)
        }
    }

    func sortedCandidates() -> [MetaBrainRankedSearchCandidate] {
        candidates
    }

    private static func ranksBefore(
        _ lhs: MetaBrainRankedSearchCandidate,
        _ rhs: MetaBrainRankedSearchCandidate
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.documentID != rhs.documentID {
            return lhs.documentID < rhs.documentID
        }
        return lhs.chunkOrdinal < rhs.chunkOrdinal
    }
}

extension MetaBrainStore {
    /// Reads one passage from the current document or an explicitly retained revision.
    /// The result uses the selected revision's path and half-open Character offsets.
    public func readPassage(
        _ reference: DocumentReference,
        selector: DocumentPassageSelector,
        version: UInt64? = nil
    ) async throws -> DocumentPassage? {
        let document: StoredDocument?
        if let version {
            document = try await getDocument(reference, version: version)
        } else {
            document = try await getDocument(reference, trackingRead: false)
        }
        guard let document else { return nil }

        let range: Range<Int>
        switch selector {
        case .range(let start, let end):
            guard start >= 0, end >= start, end <= document.body.count else {
                throw DocumentPassageError.invalidRange(start: start, end: end)
            }
            range = start..<end
        case .heading, .block:
            guard document.isMarkdown,
                  let anchor = try MarkdownDocument(body: document.body, includeLinks: false).anchor(for: selector) else {
                return nil
            }
            range = anchor.range
        }
        let start = document.body.index(document.body.startIndex, offsetBy: range.lowerBound)
        let end = document.body.index(start, offsetBy: range.count)
        return DocumentPassage(
            documentID: document.id,
            path: document.path,
            version: document.currentVersion,
            selector: selector,
            passage: RecallPassage(start: range.lowerBound, end: range.upperBound, text: String(document.body[start..<end]))
        )
    }

    /// Lists current Markdown occurrences in source path and body order.
    /// A block filter matches the source block for outgoing links and the cited block for incoming links.
    public func links(
        for reference: DocumentReference,
        direction: DocumentLinkDirection = .outgoing,
        block: String? = nil
    ) async throws -> [DocumentLinkOccurrence] {
        try await writes.run {
            try await self.ensureCitationIndex()
            guard let id = try await self.documentID(for: reference),
                  try await self.citationPath(id) != nil else {
                return []
            }
            let citations: [MarkdownCitation]
            let requestedBlock = block.map(MarkdownDocument.blockName)
            switch direction {
            case .outgoing:
                citations = try await self.outgoingCitationRecords(from: id).filter {
                    requestedBlock == nil || $0.link.sourceBlock == requestedBlock
                }
            case .incoming:
                citations = try await self.citationRecords(at: MetaBrainKeyspace.citationInPrefix(id)).filter {
                    guard let requestedBlock else { return true }
                    return $0.destination.fragment == "^" + requestedBlock
                }
            }
            return try await self.linkOccurrences(citations)
        }
    }

    /// Audits current Markdown citations within the selected path, resolving against the whole store.
    public func lint(_ query: DocumentLintQuery = DocumentLintQuery()) async throws -> DocumentLintReport {
        try await writes.run {
            let scope = query.path ?? (try! DocumentPath("/"))
            let ids = try await self.lintSourceIDs(under: scope)
            if query.path != nil, ids.isEmpty {
                throw MetaBrainStoreError.lintScopeNotFound(scope)
            }
            try await self.ensureCitationIndex()
            var findings: [DocumentLintFinding] = []
            var documentsChecked = 0
            var cache = CitationReadCache()
            for id in ids {
                guard let source = try await self.documentRecord(id: id)?.document, source.isMarkdown else { continue }
                documentsChecked += 1
                let citations = try await self.outgoingCitationRecords(from: id)
                for citation in citations.sorted(by: { $0.link.start < $1.link.start }) where citation.status != .external {
                    let link = try await self.linkOccurrence(citation, cache: &cache)
                    if let finding = DocumentLintFinding(link) { findings.append(finding) }
                }
                if query.includeOrphans, try await self.inboundReferences(to: id).allSatisfy({ $0 == id }) {
                    findings.append(DocumentLintFinding(orphan: source))
                }
            }
            return DocumentLintReport(path: scope.rawValue, documentsChecked: documentsChecked, findings: findings)
        }
    }

    /// Path keys sort in document path order. A non-root scope can also be a document itself.
    private func lintSourceIDs(under scope: DocumentPath) async throws -> [DocumentID] {
        let prefix = scope.rawValue == "/"
            ? MetaBrainKeyspace.documentPath(scope)
            : MetaBrainKeyspace.documentPathDescendantPrefix(scope)
        let exact = scope.rawValue == "/" ? nil : try await documentID(forPath: scope)
        let descendants = try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            return try await records.scanEncodedPrefix(Data(prefix.utf8), readOptions: Self.bulkReadOptions).map { row in
                guard let rawID = String(data: row.value, encoding: .utf8) else {
                    throw MetaBrainStoreError.operationFailed(message: "Invalid ID in document path index.")
                }
                return try DocumentID(rawValue: rawID)
            }
        }
        return (exact.map { [$0] } ?? []) + descendants
    }

    private struct CitationReadCache {
        var paths: [DocumentID: DocumentPath?] = [:]
        var parsedTargets: [DocumentID: MarkdownDocument] = [:]
        var checkedTargets: Set<DocumentID> = []
    }

    private func linkOccurrences(_ records: [MarkdownCitation]) async throws -> [DocumentLinkOccurrence] {
        var cache = CitationReadCache()
        var occurrences: [DocumentLinkOccurrence] = []
        for record in records {
            occurrences.append(try await linkOccurrence(record, cache: &cache))
        }
        return occurrences.sorted {
            if $0.sourcePath != $1.sourcePath { return $0.sourcePath < $1.sourcePath }
            return $0.start < $1.start
        }
    }

    private func linkOccurrence(
        _ record: MarkdownCitation,
        cache: inout CitationReadCache
    ) async throws -> DocumentLinkOccurrence {
        var targetPath: DocumentPath?
        var status = record.status
        if status == .resolved, let target = record.targetID {
            targetPath = try await citationPath(target, cache: &cache)
            if targetPath == nil {
                status = .unresolved
            } else if let fragment = record.destination.fragment, !fragment.isEmpty {
                if cache.checkedTargets.insert(target).inserted,
                   let document = try await documentRecord(id: target)?.document, document.isMarkdown {
                    cache.parsedTargets[target] = MarkdownDocument(body: document.body, includeLinks: false)
                }
                let selector: DocumentPassageSelector = fragment.hasPrefix("^") ? .block(fragment) : .heading(fragment)
                do {
                    if try cache.parsedTargets[target]?.anchor(for: selector) == nil {
                        status = .unresolved
                    }
                } catch DocumentPassageError.ambiguousSelector {
                    status = .ambiguous
                }
            }
        }
        var candidates: [DocumentLinkCandidate] = []
        for id in record.candidates {
            if let path = try await citationPath(id, cache: &cache) {
                candidates.append(DocumentLinkCandidate(documentID: id, path: path))
            }
        }
        return record.occurrence(
            targetPath: targetPath,
            status: status,
            candidates: candidates.sorted { $0.path < $1.path }
        )
    }

    private func citationPath(_ id: DocumentID, cache: inout CitationReadCache) async throws -> DocumentPath? {
        if let cached = cache.paths[id] { return cached }
        let path = try await citationPath(id)
        cache.paths.updateValue(path, forKey: id)
        return path
    }

    private func citationPath(_ id: DocumentID) async throws -> DocumentPath? {
        guard let data = try await rawValue(forKey: MetaBrainKeyspace.citationPath(id)),
              let path = String(data: data, encoding: .utf8) else { return nil }
        return try DocumentPath(path)
    }

    private func ensureCitationIndex() async throws {
        try await citationIndex.prepare { try await self.prepareCitationIndex() }
    }

    private func prepareCitationIndex() async throws {
        let layout = Data([2])
        let current = try await rawValue(forKey: MetaBrainKeyspace.citationLayout)
        if current == layout { return }
        guard current == nil || current == Data([1]) else {
            throw MetaBrainStoreError.operationFailed(message: "Unrecognized Markdown citation index layout.")
        }

        let prefix = MetaBrainKeyspace.prefix(.documentID)
        var catalog: [MarkdownCitationHeader] = []
        var citations: [MarkdownCitation] = []
        var edit = MarkdownCitationEdit()
        for key in try await scanKeys(withPrefix: prefix) {
            let id = try DocumentID(rawValue: String(key.dropFirst(prefix.count)))
            guard let document = try await documentRecord(id: id)?.document else { continue }
            let header = MarkdownCitationHeader(id: id, path: document.path)
            catalog.append(header)
            Self.insertCitationHeader(header, in: &edit)
            var parsed = Self.markdownCitations(from: document)
            if current != nil && document.isMarkdown {
                // The body has not changed. Its offsets identify the surviving occurrences,
                // even when the old target moved or was deleted and its path was reused.
                let previous = try await outgoingCitationRecords(from: id, operation: "upgrade Markdown citations")
                var bound: [Int: MarkdownCitation] = [:]
                for citation in previous {
                    edit.remove(citation)
                    if citation.targetID != nil { bound[citation.link.start] = citation }
                }
                for index in parsed.indices {
                    let link = parsed[index].link
                    guard let prior = bound[link.start], prior.sourceVersion == document.currentVersion,
                          prior.link.syntax == link.syntax, prior.link.destination.utf8.elementsEqual(link.destination.utf8),
                          parsed[index].destination.bindableTarget != nil else { continue }
                    parsed[index].targetID = prior.targetID
                    parsed[index].status = prior.status
                }
            }
            citations += parsed
        }

        let resolver = MarkdownCitationCatalog(catalog)
        for citation in citations {
            let resolved = if citation.targetID == nil {
                try await resolveCitation(citation, catalog: resolver)
            } else {
                citation
            }
            try addCitation(resolved, to: &edit)
        }
        edit.put(layout, for: MetaBrainKeyspace.citationLayout)
        try await Self.mapLevelDBErrors(path: url.path) { [edit] in
            let records = try await currentRecords()
            try await records.write { batch in
                for key in edit.removals { try batch.deleteValue(forKey: key) }
                for (key, value) in edit.puts { try batch.put(value, forKey: key) }
            }
        }
    }

    private func citationEdit(
        replacing previous: StoredDocument?,
        with next: StoredDocument?
    ) async throws -> MarkdownCitationEdit {
        try await ensureCitationIndex()
        guard let id = next?.id ?? previous?.id else { return MarkdownCitationEdit() }
        let old = if previous?.isMarkdown == true {
            try await outgoingCitationRecords(from: id, operation: "update Markdown citations")
        } else {
            [] as [MarkdownCitation]
        }
        var edit = MarkdownCitationEdit()
        for citation in old {
            edit.remove(citation)
        }
        if previous?.path != next?.path {
            if let previous {
                edit.remove(MetaBrainKeyspace.citationPath(id))
                edit.remove(Self.citationNameKey(previous.path, id: id))
            }
            if let next {
                Self.insertCitationHeader(MarkdownCitationHeader(id: id, path: next.path), in: &edit)
            }
            var prefixes: Set<String> = []
            if let previous { prefixes.formUnion(MarkdownDestination.pendingPrefixes(changedBy: previous.path)) }
            if let next { prefixes.formUnion(MarkdownDestination.pendingPrefixes(changedBy: next.path)) }
            var visited = Set<String>()
            for prefix in prefixes {
                for citation in try await citationRecords(at: prefix, operation: "resolve Markdown citations")
                    where citation.sourceID != id && visited.insert(citation.key).inserted {
                    let resolved = try await resolveCitation(citation, replacing: previous?.path, with: next?.path, id: id)
                    edit.remove(citation)
                    try addCitation(resolved, to: &edit)
                }
            }
        }

        if let next {
            var citations = Self.markdownCitations(from: next)
            MarkdownCitationBindings.preserve(from: old, in: &citations)
            for citation in citations {
                let resolved = if citation.targetID == nil {
                    try await resolveCitation(citation, replacing: previous?.path, with: next.path, id: id)
                } else {
                    citation
                }
                try addCitation(resolved, to: &edit)
            }
        } else {
            let prefix = MetaBrainKeyspace.citationInPrefix(id)
            for var citation in try await citationRecords(at: prefix, operation: "delete Markdown citations")
                where citation.sourceID != id {
                edit.remove(citation)
                citation.status = .unresolved
                try addCitation(citation, to: &edit)
            }
        }
        return edit
    }

    private static func markdownCitations(from document: StoredDocument) -> [MarkdownCitation] {
        guard document.isMarkdown else { return [] }
        return MarkdownDocument(body: document.body).links.map {
            MarkdownCitation(
                sourceID: document.id,
                sourcePath: document.path,
                sourceVersion: document.currentVersion,
                link: $0,
                status: .unresolved
            )
        }
    }

    private static func insertCitationHeader(_ header: MarkdownCitationHeader, in edit: inout MarkdownCitationEdit) {
        edit.put(Data(header.path.rawValue.utf8), for: MetaBrainKeyspace.citationPath(header.id))
        edit.put(for: citationNameKey(header.path, id: header.id))
    }

    private static func citationNameKey(_ path: DocumentPath, id: DocumentID) -> String {
        MetaBrainKeyspace.citationNamePrefix(MarkdownDestination.wikiName(path.name)) + id.rawValue
    }

    private func addCitation(_ citation: MarkdownCitation, to edit: inout MarkdownCitationEdit) throws {
        edit.put(try compressedData(citation), for: citation.key)
        for key in citation.secondaryKeys { edit.put(for: key) }
    }

    private func resolveCitation(
        _ citation: MarkdownCitation,
        replacing oldPath: DocumentPath? = nil,
        with newPath: DocumentPath? = nil,
        id: DocumentID? = nil,
        catalog: MarkdownCitationCatalog? = nil
    ) async throws -> MarkdownCitation {
        var citation = citation
        citation.candidates = []
        let destination = citation.destination
        if destination.isExternal {
            citation.status = .external
            return citation
        }
        if destination.isSelfLink {
            citation.targetID = citation.sourceID
        }
        for path in destination.paths where citation.targetID == nil {
            if let catalog {
                citation.targetID = catalog.id(for: path)
            } else if path == newPath {
                citation.targetID = id
            } else if path != oldPath {
                citation.targetID = try await documentID(forPath: path)
            }
        }
        if citation.targetID == nil, let name = destination.name {
            var matches: Set<DocumentID>
            if let catalog {
                matches = catalog.ids(named: name)
            } else {
                let prefix = MetaBrainKeyspace.citationNamePrefix(name)
                matches = try await Set(scanKeys(withPrefix: prefix).map { key in
                    try DocumentID(rawValue: String(key.dropFirst(prefix.count)))
                })
                if let id, let oldPath, MarkdownDestination.wikiName(oldPath.name).utf8.elementsEqual(name.utf8) {
                    matches.remove(id)
                }
                if let id, let newPath, MarkdownDestination.wikiName(newPath.name).utf8.elementsEqual(name.utf8) {
                    matches.insert(id)
                }
            }
            if matches.count == 1 {
                citation.targetID = matches.first
            } else if matches.count > 1 {
                citation.candidates = matches.sorted()
            }
        }
        if citation.targetID != nil {
            citation.status = .resolved
        } else {
            citation.status = citation.candidates.isEmpty ? .unresolved : .ambiguous
        }
        return citation
    }

    private func outgoingCitationRecords(
        from id: DocumentID,
        operation: String? = nil
    ) async throws -> [MarkdownCitation] {
        let prefix = MetaBrainKeyspace.citationOutPrefix(id)
        return try await Self.mapLevelDBErrors(path: url.path) {
            let records = try await currentRecords()
            return try await records.scanEncodedPrefix(Data(prefix.utf8), readOptions: Self.bulkReadOptions).map { row in
                let decoded = try decodeCompressedRecord(row.value, as: MarkdownCitation.self)
                if let operation { try decoded.requireCurrentSchemaVersion(operation: operation) }
                return decoded.payload
            }
        }
    }

    private func citationRecords(at prefix: String, operation: String? = nil) async throws -> [MarkdownCitation] {
        var citations: [MarkdownCitation] = []
        for key in try await scanKeys(withPrefix: prefix) {
            let occurrence = try Self.citationOccurrenceKey(key, prefix: prefix)
            let outbound = MetaBrainKeyspace.citationOutPrefix(occurrence.source) + occurrence.start
            if let decoded = try await compressedStoredRecord(forKey: outbound, as: MarkdownCitation.self) {
                if let operation { try decoded.requireCurrentSchemaVersion(operation: operation) }
                citations.append(decoded.payload)
            }
        }
        return citations
    }

    private static func citationOccurrenceKey(_ key: String, prefix: String) throws -> (source: DocumentID, start: String) {
        let parts = key.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let start = Int(parts[1]), start >= 0 else {
            throw MetaBrainStoreError.operationFailed(message: "Invalid Markdown citation occurrence key.")
        }
        return (try DocumentID(rawValue: String(parts[0])), String(parts[1]))
    }
}
