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
        do {
            try await records.put(value, forKey: key)
        } catch let error as LevelDBError {
            throw Self.storeError(from: error, path: url.path)
        }
    }

    func rawValue(forKey key: String) async throws -> Data? {
        do {
            return try await records.value(forKey: key)
        } catch let error as LevelDBError {
            throw Self.storeError(from: error, path: url.path)
        }
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
        let removedPath = existing.path == input.path ? nil : existing.path
        let prunedVersions = try await prunedVersionRecords(
            id: id,
            appending: version,
            policy: record.retention
        )

        try await writeDocumentBatch(
            record: record,
            version: version,
            removedPath: removedPath,
            prunedVersions: prunedVersions
        )

        return document
    }

    private func writeDocumentBatch(
        record: MetaBrainDocumentRecord,
        version: DocumentVersion,
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

        do {
            try await records.write { batch in
                try batch.put(encodedRecord, forKey: documentKey)
                try batch.put(encodedID, forKey: pathKey)
                try batch.put(encodedVersion, forKey: versionKey)

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
        } catch let error as LevelDBError {
            throw Self.storeError(from: error, path: url.path)
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

        do {
            try await records.write { batch in
                for version in prunedVersions {
                    try batch.deleteValue(forKey: MetaBrainKeyspace.version(
                        id: version.documentID,
                        sequence: version.sequence
                    ))
                }
            }
        } catch let error as LevelDBError {
            throw Self.storeError(from: error, path: url.path)
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
            currentSequence: versions.map(\.sequence).max() ?? 0
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

        do {
            return try await records
                .scanEncodedPrefix(Data(prefix.utf8))
                .map { try decodeCompressedData($0.value, as: DocumentVersion.self) }
                .sorted { $0.sequence < $1.sequence }
        } catch let error as LevelDBError {
            throw Self.storeError(from: error, path: url.path)
        }
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

    private static func storeError(from error: LevelDBError, path: String) -> MetaBrainStoreError {
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
