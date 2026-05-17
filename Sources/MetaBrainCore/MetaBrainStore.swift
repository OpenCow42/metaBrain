import Foundation
import LevelDBTyped
import LevelDBZstd
import swift_leveldb

public struct MetaBrainStoreOptions: Equatable, Sendable {
    public static let `default` = MetaBrainStoreOptions()

    public var createIfMissing: Bool
    public var errorIfExists: Bool
    public var zstdCompressionLevel: Int32
    public var zstdAdaptiveMinimumSavingsRatio: Double
    public var lruCacheCapacity: Int?
    public var bloomFilterBitsPerKey: Int?

    public init(
        createIfMissing: Bool = true,
        errorIfExists: Bool = false,
        zstdCompressionLevel: Int32 = 3,
        zstdAdaptiveMinimumSavingsRatio: Double = 0.10,
        lruCacheCapacity: Int? = 64 * 1024 * 1024,
        bloomFilterBitsPerKey: Int? = 10
    ) {
        self.createIfMissing = createIfMissing
        self.errorIfExists = errorIfExists
        self.zstdCompressionLevel = zstdCompressionLevel
        self.zstdAdaptiveMinimumSavingsRatio = zstdAdaptiveMinimumSavingsRatio
        self.lruCacheCapacity = lruCacheCapacity
        self.bloomFilterBitsPerKey = bloomFilterBitsPerKey
    }

    var levelDBOptions: LevelDBStoreOptions {
        LevelDBStoreOptions(
            createIfMissing: createIfMissing,
            errorIfExists: errorIfExists,
            compression: Database.OpenOptions.Compression.none,
            lruCacheCapacity: lruCacheCapacity,
            bloomFilterBitsPerKey: bloomFilterBitsPerKey
        )
    }
}

public enum MetaBrainStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case operationFailed(message: String)
    case pathAlreadyExists(DocumentPath, existingID: DocumentID)
    case unsupportedRecordSchemaVersion(UInt8)

    public var description: String {
        switch self {
        case .openFailed(let path, let message):
            "Could not open metaBrain store at \(path): \(message)"
        case .operationFailed(let message):
            "LevelDB operation failed: \(message)"
        case .pathAlreadyExists(let path, let existingID):
            "Document path \(path.rawValue) already points to document \(existingID.rawValue)."
        case .unsupportedRecordSchemaVersion(let version):
            "Unsupported metaBrain record schema version: \(version)"
        }
    }
}

public final class MetaBrainStore: Sendable {
    public let url: URL
    public let options: MetaBrainStoreOptions

    private let records: LevelDBStore<StringCodec, DataCodec>
    private let writes = MetaBrainWriteCoordinator()
    private static let chunkTargetCharacterCount = 4_000
    private static let chunkOverlapCharacterCount = 400
    private static let emptyIndexValue = Data()
    private static let bulkReadOptions = Database.ReadOptions(fillCache: false)

    public convenience init(path: String, options: MetaBrainStoreOptions = .default) throws {
        try self.init(url: URL(fileURLWithPath: path, isDirectory: true), options: options)
    }

    public init(url: URL, options: MetaBrainStoreOptions = .default) throws {
        self.url = url
        self.options = options

        do {
            records = try LevelDBStore(
                path: url.path,
                keyCodec: StringCodec(),
                valueCodec: DataCodec(),
                options: options.levelDBOptions
            )
        } catch let error as LevelDBError {
            throw Self.storeError(from: error, path: url.path)
        }
    }

    @discardableResult
    public func putDocument(_ input: DocumentInput) async throws -> StoredDocument {
        try await writes.run {
            if let id = try await self.documentID(forPath: input.path) {
                return try await self.writeDocumentUpdate(id: id, input: input)
            }

            return try await self.writeNewDocument(input)
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

    public func getDocument(_ reference: DocumentReference) async throws -> StoredDocument? {
        guard let id = try await documentID(for: reference) else {
            return nil
        }

        return try await documentRecord(id: id)?.document
    }

    public func listVersions(of reference: DocumentReference) async throws -> [DocumentVersion] {
        guard let id = try await documentID(for: reference) else {
            return []
        }

        return try await versionRecords(for: id)
    }

    public func checkDocumentPatch(_ request: DocumentPatchRequest) async throws {
        _ = try await patchedDocumentInput(for: request)
    }

    @discardableResult
    public func patchDocument(_ request: DocumentPatchRequest) async throws -> StoredDocument {
        try await writes.run {
            let patched = try await self.patchedDocumentInput(for: request)
            return try await self.writeDocumentUpdate(id: patched.id, input: patched.input)
        }
    }

    public func listDirectory(
        path: DocumentPath = try! DocumentPath("/"),
        recursive: Bool = false,
        directoriesOnly: Bool = false
    ) async throws -> [DocumentTreeEntry] {
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
        try await flattenedTreeEntries(
            under: query.path,
            directoriesOnly: query.directoriesOnly,
            maxDepth: query.maxDepth,
            currentDepth: 0
        )
    }

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        let queryTerms = Array(Set(Self.tokenize(query.text))).sorted()
        guard !queryTerms.isEmpty, query.limit > 0 else {
            return []
        }

        let allowedIDs = try await filteredDocumentIDs(for: query)
        var matches: [MetaBrainSearchCandidate: Set<String>] = [:]

        for term in queryTerms {
            let postings = try await termPostings(for: term)
            for posting in postings {
                if let allowedIDs, !allowedIDs.contains(posting.documentID) {
                    continue
                }

                var matchedTerms = matches[posting] ?? []
                matchedTerms.insert(term)
                matches[posting] = matchedTerms
            }
        }

        let candidatesByDocument = Dictionary(grouping: matches) { element in
            element.key.documentID
        }

        var topCandidates = MetaBrainSearchTopCandidates(limit: query.limit)
        let groupedCandidates = candidatesByDocument.sorted { lhs, rhs in
            lhs.key < rhs.key
        }
        for (documentID, documentCandidates) in groupedCandidates {
            guard let record = try await documentRecord(id: documentID) else {
                continue
            }

            let document = record.document
            guard Self.path(document.path, matchesPrefix: query.pathPrefix) else {
                continue
            }

            let chunks = try await currentChunkRecords(for: documentID)
            let chunksByOrdinal = Dictionary(uniqueKeysWithValues: chunks.map { ($0.ordinal, $0) })

            for (candidate, matchedTerms) in documentCandidates {
                guard let chunk = chunksByOrdinal[candidate.chunkOrdinal] else {
                    continue
                }

                let chunkTerms = Self.tokenize(chunk.text)
                let score = Self.searchScore(
                    queryTerms: queryTerms,
                    matchedTerms: matchedTerms,
                    chunkTerms: chunkTerms
                )

                topCandidates.insert(MetaBrainRankedSearchCandidate(
                    documentID: document.id,
                    path: document.path,
                    title: document.title,
                    chunkOrdinal: chunk.ordinal,
                    snippet: chunk.text,
                    context: Self.contextChunks(around: chunk.ordinal, in: chunks),
                    score: score
                ))
            }
        }

        return try await searchResults(
            from: topCandidates.sortedCandidates(),
            query: query
        )
    }

    @discardableResult
    public func prune(_ request: PruneRequest) async throws -> PruneResult {
        try await writes.run {
            guard let id = try await self.documentID(for: request.reference) else {
                return PruneResult(prunedVersionCount: 0, retainedVersionCount: 0)
            }

            return try await self.pruneVersions(id: id, policy: request.policy)
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
        guard let data = try await rawValue(forKey: key) else {
            return nil
        }

        let envelope = try codec(for: type).decode(data)
        guard envelope.schemaVersion == MetaBrainRecordEnvelope<Value>.currentSchemaVersion else {
            throw MetaBrainStoreError.unsupportedRecordSchemaVersion(envelope.schemaVersion)
        }

        return envelope.payload
    }

    func writeRawValue(_ value: Data, forKey key: String) async throws {
        try await Self.mapLevelDBErrors(path: url.path) {
            try await records.put(value, forKey: key)
        }
    }

    func rawValue(forKey key: String) async throws -> Data? {
        try await Self.mapLevelDBErrors(path: url.path) {
            try await records.value(forKey: key)
        }
    }

    func currentChunks(for id: DocumentID) async throws -> [MetaBrainChunkRecord] {
        try await currentChunkRecords(for: id)
    }

    func documentIDs(matchingTerm term: String) async throws -> [DocumentID] {
        try await documentIDs(forIndexPrefix: MetaBrainKeyspace.termPrefix(Self.normalizedTerm(term)))
    }

    func documentIDs(tagged tag: String) async throws -> [DocumentID] {
        try await documentIDs(forIndexPrefix: MetaBrainKeyspace.tagPrefix(tag))
    }

    func documentIDs(metadataKey key: String, value: String) async throws -> [DocumentID] {
        try await documentIDs(forIndexPrefix: MetaBrainKeyspace.metadataPrefix(key: key, value: value))
    }

    func outboundReferences(from sourceID: DocumentID) async throws -> [DocumentID] {
        let prefix = MetaBrainKeyspace.outboundReferencePrefix(sourceID: sourceID)
        return try await scanKeys(withPrefix: prefix)
            .compactMap { key in
                try DocumentID(rawValue: String(key.dropFirst(prefix.count)))
            }
            .sorted()
    }

    func inboundReferences(to targetID: DocumentID) async throws -> [DocumentID] {
        let prefix = MetaBrainKeyspace.inboundReferencePrefix(targetID: targetID)
        return try await scanKeys(withPrefix: prefix)
            .compactMap { key in
                try DocumentID(rawValue: String(key.dropFirst(prefix.count)))
            }
            .sorted()
    }

    private func writeNewDocument(_ input: DocumentInput) async throws -> StoredDocument {
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
            updatedAt: now
        )
        let retentionPolicy: VersionRetentionPolicy
        if let inputRetention = input.retention {
            retentionPolicy = inputRetention
        } else {
            retentionPolicy = .keepAll
        }
        let record = MetaBrainDocumentRecord(
            document: document,
            retention: retentionPolicy
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
            previousRecord: nil,
            removedPath: nil,
            prunedVersions: []
        )

        return document
    }

    private func writeDocumentUpdate(
        id: DocumentID,
        input: DocumentInput
    ) async throws -> StoredDocument {
        guard let existingRecord = try await documentRecord(id: id) else {
            return try await writeNewDocument(input)
        }

        if let existingPathID = try await documentID(forPath: input.path),
           existingPathID != id {
            throw MetaBrainStoreError.pathAlreadyExists(input.path, existingID: existingPathID)
        }

        let now = Date()
        let existing = existingRecord.document
        let document = StoredDocument(
            id: id,
            path: input.path,
            title: input.title,
            body: input.body,
            tags: input.tags,
            metadata: input.metadata,
            references: input.references,
            currentVersion: existing.currentVersion + 1,
            createdAt: existing.createdAt,
            updatedAt: now
        )
        let retentionPolicy: VersionRetentionPolicy
        if let inputRetention = input.retention {
            retentionPolicy = inputRetention
        } else {
            retentionPolicy = existingRecord.retention
        }
        let record = MetaBrainDocumentRecord(
            document: document,
            retention: retentionPolicy
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

        try await writeDocumentBatch(
            record: record,
            version: version,
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
        previousRecord: MetaBrainDocumentRecord?,
        removedPath: DocumentPath?,
        prunedVersions: [DocumentVersion]
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
        let encodedID = Data(document.id.rawValue.utf8)
        let staleChunkKeys = try await currentChunkKeys(for: document.id)
        let staleIndexKeys = try await staleIndexKeys(
            for: previousRecord?.document,
            staleChunkKeys: staleChunkKeys
        )
        let staleReferenceKeys = try await staleReferenceKeys(sourceID: document.id)
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

        try await Self.mapLevelDBErrors(path: url.path) {
            try await records.write { batch in
                for key in staleChunkKeys + staleIndexKeys + staleReferenceKeys {
                    try batch.deleteValue(forKey: key)
                }

                try batch.put(encodedRecord, forKey: documentKey)
                try batch.put(encodedID, forKey: pathKey)
                try batch.put(encodedVersion, forKey: versionKey)

                for chunk in encodedChunks {
                    try batch.put(chunk.value, forKey: chunk.key)
                }

                for key in indexKeys {
                    try batch.put(Self.emptyIndexValue, forKey: key)
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

    private func pruneVersions(
        id: DocumentID,
        policy: VersionRetentionPolicy
    ) async throws -> PruneResult {
        let versions = try await versionRecords(for: id)
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
        prunedVersionRecords(
            from: try await versionRecords(for: id) + [version],
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
        try await compressedRecord(
            forKey: MetaBrainKeyspace.document(id: id),
            as: MetaBrainDocumentRecord.self
        )
    }

    private func versionRecords(for id: DocumentID) async throws -> [DocumentVersion] {
        let prefix = "ver/\(id.rawValue)/"

        return try await Self.mapLevelDBErrors(path: url.path) {
            try await records
                .scanEncodedPrefix(Data(prefix.utf8), readOptions: Self.bulkReadOptions)
                .map { try decodeCompressedData($0.value, as: DocumentVersion.self) }
        }
    }

    private func currentChunkRecords(for id: DocumentID) async throws -> [MetaBrainChunkRecord] {
        return try await Self.mapLevelDBErrors(path: url.path) {
            try await records
                .scanEncodedPrefix(
                    Data(MetaBrainKeyspace.currentChunkPrefix(id: id).utf8),
                    readOptions: Self.bulkReadOptions
                )
                .map { try decodeCompressedData($0.value, as: MetaBrainChunkRecord.self) }
        }
    }

    private func currentChunkKeys(for id: DocumentID) async throws -> [String] {
        try await scanKeys(withPrefix: MetaBrainKeyspace.currentChunkPrefix(id: id))
    }

    private func childTreeEntries(of path: DocumentPath) async throws -> [DocumentTreeEntry] {
        let prefix = MetaBrainKeyspace.treePrefix(parentPath: path)

        return try await Self.mapLevelDBErrors(path: url.path) {
            try await records
                .scanEncodedPrefix(Data(prefix.utf8), readOptions: Self.bulkReadOptions)
                .map { try decodeCompressedData($0.value, as: MetaBrainTreeRecord.self).entry }
                .sorted { $0.path.rawValue < $1.path.rawValue }
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
        let affectedPaths = Self.treeAffectedPaths(
            newPath: document.path,
            removedPath: removedPath
        )
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

        return MetaBrainTreeRecord(
            parentPath: path.parent!,
            entry: DocumentTreeEntry(
                path: path,
                name: path.name,
                hasChildren: hasChildren,
                documentID: documentAtPath?.id,
                createdAt: documentAtPath?.createdAt,
                updatedAt: documentAtPath?.updatedAt
            )
        )
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

    private func staleIndexKeys(
        for document: StoredDocument?,
        staleChunkKeys: [String]
    ) async throws -> [String] {
        guard let document else {
            return []
        }

        var chunks: [MetaBrainChunkRecord] = []
        for key in staleChunkKeys {
            if let chunk = try await compressedRecord(forKey: key, as: MetaBrainChunkRecord.self) {
                chunks.append(chunk)
            }
        }

        var keys = Set<String>()
        for chunk in chunks {
            for term in Self.tokenize(chunk.text) {
                keys.insert(MetaBrainKeyspace.term(term, id: document.id, ordinal: chunk.ordinal))
            }
        }
        for tag in document.tags {
            keys.insert(MetaBrainKeyspace.tag(tag, id: document.id))
        }
        for (key, value) in document.metadata {
            keys.insert(MetaBrainKeyspace.metadata(key: key, value: value, id: document.id))
        }

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
        for tag in document.tags {
            keys.insert(MetaBrainKeyspace.tag(tag, id: document.id))
        }
        for (key, value) in document.metadata {
            keys.insert(MetaBrainKeyspace.metadata(key: key, value: value, id: document.id))
        }
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
            try await records
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

        return path.rawValue.hasPrefix(prefix.rawValue + "/")
    }

    private static func path(_ path: DocumentPath, isDescendantOf ancestor: DocumentPath) -> Bool {
        ancestor.rawValue != "/" && path.rawValue.hasPrefix(ancestor.rawValue + "/")
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

    private static func searchScore(
        queryTerms: [String],
        matchedTerms: Set<String>,
        chunkTerms: [String]
    ) -> Double {
        let coverage = Double(matchedTerms.count) / Double(queryTerms.count)
        let frequency = chunkTerms.reduce(into: 0) { count, term in
            if matchedTerms.contains(term) {
                count += 1
            }
        }
        let locality = localityScore(for: queryTerms, in: chunkTerms)

        return coverage * 100 + Double(frequency) * 5 + locality * 25
    }

    private static func localityScore(for queryTerms: [String], in chunkTerms: [String]) -> Double {
        guard queryTerms.count > 1 else {
            return 1
        }

        let requiredTerms = Set(queryTerms)
        var bestSpan: Int?

        for start in chunkTerms.indices {
            guard requiredTerms.contains(chunkTerms[start]) else {
                continue
            }

            var seen: Set<String> = []
            for end in start..<chunkTerms.count {
                if requiredTerms.contains(chunkTerms[end]) {
                    seen.insert(chunkTerms[end])
                }

                if seen.count == requiredTerms.count {
                    let span = end - start + 1
                    if let currentBest = bestSpan {
                        bestSpan = min(currentBest, span)
                    } else {
                        bestSpan = span
                    }
                    break
                }
            }
        }

        guard let bestSpan else {
            return 0
        }

        return 1 / Double(bestSpan)
    }

    private static func contextChunks(
        around ordinal: UInt32,
        in chunks: [MetaBrainChunkRecord]
    ) -> [SearchContextChunk] {
        var context: [SearchContextChunk] = []
        for chunk in chunks {
            let distance = Int64(chunk.ordinal) - Int64(ordinal)
            if distance != 0 && abs(distance) <= 1 {
                context.append(SearchContextChunk(ordinal: chunk.ordinal, text: chunk.text))
            }
        }

        return context
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

    private func decodeCompressedData<Value: Codable & Sendable>(
        _ data: Data,
        as type: Value.Type = Value.self
    ) throws -> Value {
        let envelope = try codec(for: type).decode(data)
        guard envelope.schemaVersion == MetaBrainRecordEnvelope<Value>.currentSchemaVersion else {
            throw MetaBrainStoreError.unsupportedRecordSchemaVersion(envelope.schemaVersion)
        }

        return envelope.payload
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
}

struct MetaBrainRecordEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    static var currentSchemaVersion: UInt8 { 1 }

    var schemaVersion: UInt8
    var payload: Payload

    init(schemaVersion: UInt8 = currentSchemaVersion, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }
}

private actor MetaBrainWriteCoordinator {
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await operation()
    }
}

private struct MetaBrainDocumentRecord: Codable, Equatable, Sendable {
    var document: StoredDocument
    var retention: VersionRetentionPolicy
}

private struct MetaBrainTreeRecord: Codable, Equatable, Sendable {
    var parentPath: DocumentPath
    var entry: DocumentTreeEntry
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
