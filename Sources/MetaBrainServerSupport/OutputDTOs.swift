import Foundation
import MetaBrainCore

public struct InitializeOutput: Codable, Equatable, Sendable {
    public var operation: String
    public var status: String
    public var storePath: String

    public init(operation: String = "init", status: String = "initialized", storePath: String) {
        self.operation = operation
        self.status = status
        self.storePath = storePath
    }
}

public struct PutOutput: Codable, Equatable, Sendable {
    public var documentID: String
    public var operation: String
    public var path: String
    public var status: String
    public var version: UInt64

    public init(
        documentID: String,
        operation: String = "put",
        path: String,
        status: String,
        version: UInt64
    ) {
        self.documentID = documentID
        self.operation = operation
        self.path = path
        self.status = status
        self.version = version
    }

    public init(_ document: StoredDocument, status: String) {
        self.init(
            documentID: document.id.rawValue,
            path: document.path.rawValue,
            status: status,
            version: document.currentVersion
        )
    }
}

public struct PatchOutput: Codable, Equatable, Sendable {
    public var documentID: String
    public var operation: String
    public var path: String
    public var status: String
    public var version: UInt64

    public init(
        documentID: String,
        operation: String = "patch",
        path: String,
        status: String = "patched",
        version: UInt64
    ) {
        self.documentID = documentID
        self.operation = operation
        self.path = path
        self.status = status
        self.version = version
    }

    public init(_ document: StoredDocument) {
        self.init(
            documentID: document.id.rawValue,
            path: document.path.rawValue,
            version: document.currentVersion
        )
    }
}

public struct PatchCheckOutput: Codable, Equatable, Sendable {
    public var check: Bool
    public var operation: String
    public var status: String
    public var success: Bool

    public init(
        check: Bool = true,
        operation: String = "patch",
        status: String = "applies",
        success: Bool = true
    ) {
        self.check = check
        self.operation = operation
        self.status = status
        self.success = success
    }
}

public enum ServerPatchOutput: Encodable, Equatable, Sendable {
    case check(PatchCheckOutput)
    case patch(PatchOutput)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .check(let output):
            try output.encode(to: encoder)
        case .patch(let output):
            try output.encode(to: encoder)
        }
    }
}

public struct MoveOutput: Codable, Equatable, Sendable {
    public var documentID: String
    public var from: String
    public var operation: String
    public var path: String
    public var status: String
    public var version: UInt64

    public init(
        documentID: String,
        from: String,
        operation: String = "move",
        path: String,
        status: String,
        version: UInt64
    ) {
        self.documentID = documentID
        self.from = from
        self.operation = operation
        self.path = path
        self.status = status
        self.version = version
    }

    public init(_ result: DocumentMoveResult) {
        self.init(
            documentID: result.document.id.rawValue,
            from: result.sourcePath.rawValue,
            path: result.document.path.rawValue,
            status: result.moved ? "moved" : "unchanged",
            version: result.document.currentVersion
        )
    }
}

public struct GetOutput: Codable, Equatable, Sendable {
    public var body: String
    public var createdAt: Date
    public var documentID: String
    public var metadata: [String: String]
    public var path: String
    public var references: [DocumentDumpReference]
    public var tags: [String]
    public var title: String?
    public var updatedAt: Date
    public var version: UInt64

    public init(
        body: String,
        createdAt: Date,
        documentID: String,
        metadata: [String: String],
        path: String,
        references: [DocumentDumpReference],
        tags: [String],
        title: String?,
        updatedAt: Date,
        version: UInt64
    ) {
        self.body = body
        self.createdAt = createdAt
        self.documentID = documentID
        self.metadata = metadata
        self.path = path
        self.references = references
        self.tags = tags
        self.title = title
        self.updatedAt = updatedAt
        self.version = version
    }

    public init(_ document: StoredDocument) {
        self.init(
            body: document.body,
            createdAt: document.createdAt,
            documentID: document.id.rawValue,
            metadata: document.metadata,
            path: document.path.rawValue,
            references: document.references.map(DocumentDumpReference.init),
            tags: document.tags,
            title: document.title,
            updatedAt: document.updatedAt,
            version: document.currentVersion
        )
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

    public func encode(to encoder: Encoder) throws {
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

public struct ListOutput: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var hasChildren: Bool
    public var documentID: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        path: String,
        name: String,
        hasChildren: Bool,
        documentID: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.hasChildren = hasChildren
        self.documentID = documentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(_ entry: DocumentTreeEntry) {
        self.init(
            path: entry.path.rawValue,
            name: entry.name,
            hasChildren: entry.hasChildren,
            documentID: entry.documentID?.rawValue,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt
        )
    }
}

public struct TreeOutput: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var hasChildren: Bool
    public var documentID: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var kind: String

    public init(
        path: String,
        name: String,
        hasChildren: Bool,
        documentID: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        kind: String
    ) {
        self.path = path
        self.name = name
        self.hasChildren = hasChildren
        self.documentID = documentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kind = kind
    }

    public init(root: DocumentPath, hasChildren: Bool) {
        self.init(
            path: root.rawValue,
            name: Self.treeRootName(root),
            hasChildren: hasChildren,
            kind: "root"
        )
    }

    public init(_ entry: DocumentTreeEntry) {
        self.init(
            path: entry.path.rawValue,
            name: entry.name,
            hasChildren: entry.hasChildren,
            documentID: entry.documentID?.rawValue,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            kind: "entry"
        )
    }

    private static func treeRootName(_ root: DocumentPath) -> String {
        root.rawValue == "/" ? "/" : root.name
    }

    private enum CodingKeys: String, CodingKey {
        case createdAt
        case documentID
        case hasChildren
        case kind
        case name
        case path
        case updatedAt
    }

    public func encode(to encoder: Encoder) throws {
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

public struct SearchOutput: Codable, Equatable, Sendable {
    public var backlinks: [DocumentDumpReference]
    public var chunkOrdinal: UInt32
    public var context: [SearchContextChunk]
    public var documentID: String
    public var linkedDocuments: [DocumentDumpReference]
    public var path: String
    public var score: Double
    public var snippet: String
    public var title: String?

    public init(
        backlinks: [DocumentDumpReference],
        chunkOrdinal: UInt32,
        context: [SearchContextChunk],
        documentID: String,
        linkedDocuments: [DocumentDumpReference],
        path: String,
        score: Double,
        snippet: String,
        title: String?
    ) {
        self.backlinks = backlinks
        self.chunkOrdinal = chunkOrdinal
        self.context = context
        self.documentID = documentID
        self.linkedDocuments = linkedDocuments
        self.path = path
        self.score = score
        self.snippet = snippet
        self.title = title
    }

    public init(_ result: SearchResult) {
        self.init(
            backlinks: result.backlinks.map(DocumentDumpReference.init),
            chunkOrdinal: result.chunkOrdinal,
            context: result.context,
            documentID: result.documentID.rawValue,
            linkedDocuments: result.linkedDocuments.map(DocumentDumpReference.init),
            path: result.path.rawValue,
            score: result.score,
            snippet: result.snippet,
            title: result.title
        )
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

    public func encode(to encoder: Encoder) throws {
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

public struct DumpOutput: Codable, Equatable, Sendable {
    public var body: String
    public var bodyCharacterCount: Int
    public var bodyUTF8ByteCount: Int
    public var documentID: String
    public var fileSystemPath: String?
    public var isCurrent: Bool
    public var metadata: [String: String]
    public var path: String
    public var references: [DocumentDumpReference]
    public var tags: [String]
    public var title: String?
    public var version: UInt64
    public var versionCreatedAt: Date

    public init(
        body: String,
        bodyCharacterCount: Int,
        bodyUTF8ByteCount: Int,
        documentID: String,
        fileSystemPath: String?,
        isCurrent: Bool,
        metadata: [String: String],
        path: String,
        references: [DocumentDumpReference],
        tags: [String],
        title: String?,
        version: UInt64,
        versionCreatedAt: Date
    ) {
        self.body = body
        self.bodyCharacterCount = bodyCharacterCount
        self.bodyUTF8ByteCount = bodyUTF8ByteCount
        self.documentID = documentID
        self.fileSystemPath = fileSystemPath
        self.isCurrent = isCurrent
        self.metadata = metadata
        self.path = path
        self.references = references
        self.tags = tags
        self.title = title
        self.version = version
        self.versionCreatedAt = versionCreatedAt
    }

    public init(_ entry: DocumentDumpEntry) {
        self.init(
            body: entry.body,
            bodyCharacterCount: entry.bodyCharacterCount,
            bodyUTF8ByteCount: entry.bodyUTF8ByteCount,
            documentID: entry.documentID.rawValue,
            fileSystemPath: entry.fileSystemPath,
            isCurrent: entry.isCurrent,
            metadata: entry.metadata,
            path: entry.path.rawValue,
            references: entry.references,
            tags: entry.tags,
            title: entry.title,
            version: entry.version,
            versionCreatedAt: entry.versionCreatedAt
        )
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

    public func encode(to encoder: Encoder) throws {
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

public struct VersionsOutput: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var documentID: String
    public var isPinned: Bool
    public var path: String
    public var sequence: UInt64

    public init(
        createdAt: Date,
        documentID: String,
        isPinned: Bool,
        path: String,
        sequence: UInt64
    ) {
        self.createdAt = createdAt
        self.documentID = documentID
        self.isPinned = isPinned
        self.path = path
        self.sequence = sequence
    }

    public init(_ version: DocumentVersion) {
        self.init(
            createdAt: version.createdAt,
            documentID: version.documentID.rawValue,
            isPinned: version.isPinned,
            path: version.snapshot.path.rawValue,
            sequence: version.sequence
        )
    }
}

public struct PruneOutput: Codable, Equatable, Sendable {
    public var operation: String
    public var prunedVersionCount: Int
    public var retainedVersionCount: Int
    public var status: String

    public init(
        operation: String = "prune",
        prunedVersionCount: Int,
        retainedVersionCount: Int,
        status: String = "completed"
    ) {
        self.operation = operation
        self.prunedVersionCount = prunedVersionCount
        self.retainedVersionCount = retainedVersionCount
        self.status = status
    }

    public init(_ result: PruneResult) {
        self.init(
            prunedVersionCount: result.prunedVersionCount,
            retainedVersionCount: result.retainedVersionCount
        )
    }
}

public struct DeleteOutput: Codable, Equatable, Sendable {
    public var deleted: Bool
    public var operation: String
    public var reference: String
    public var status: String

    public init(reference: String, deleted: Bool, operation: String = "delete", status: String = "completed") {
        self.deleted = deleted
        self.operation = operation
        self.reference = reference
        self.status = status
    }
}

public struct RemoveVersionOutput: Codable, Equatable, Sendable {
    public var operation: String
    public var reference: String
    public var removed: Bool
    public var sequence: UInt64
    public var status: String

    public init(
        reference: String,
        removed: Bool,
        sequence: UInt64,
        operation: String = "remove-version",
        status: String = "completed"
    ) {
        self.operation = operation
        self.reference = reference
        self.removed = removed
        self.sequence = sequence
        self.status = status
    }
}

public struct VersionOutput: Codable, Equatable, Sendable {
    public var currentTag: String
    public var releaseCheck: ReleaseCheckOutput?

    public init(currentTag: String, releaseCheck: ReleaseCheckOutput?) {
        self.currentTag = currentTag
        self.releaseCheck = releaseCheck
    }

    private enum CodingKeys: String, CodingKey {
        case currentTag
        case releaseCheck
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentTag, forKey: .currentTag)
        try container.encode(releaseCheck, forKey: .releaseCheck)
    }
}

public struct ReleaseCheckOutput: Codable, Equatable, Sendable {
    public var htmlURL: String?
    public var latestTag: String?
    public var message: String?
    public var status: String
    public var updateAvailable: Bool?

    public init(
        htmlURL: String?,
        latestTag: String?,
        message: String?,
        status: String,
        updateAvailable: Bool?
    ) {
        self.htmlURL = htmlURL
        self.latestTag = latestTag
        self.message = message
        self.status = status
        self.updateAvailable = updateAvailable
    }
}
