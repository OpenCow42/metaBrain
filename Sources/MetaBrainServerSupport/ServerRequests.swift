import Foundation
import MetaBrainCore

public enum ServerRequestDTOError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidTreeMaxDepth(Int)
    case invalidSearchLimit(Int)
    case missingRetention
    case invalidRemoveVersionSequence(UInt64)

    public var description: String {
        switch self {
        case .invalidTreeMaxDepth(let maxDepth):
            return "maxDepth must be zero or greater, got \(maxDepth)"
        case .invalidSearchLimit(let limit):
            return "limit must be greater than zero, got \(limit)"
        case .missingRetention:
            return "retention is required"
        case .invalidRemoveVersionSequence(let sequence):
            return "sequence must be greater than zero, got \(sequence)"
        }
    }
}

public struct ServerPutRequest: Codable, Equatable, Sendable {
    public var path: String
    public var body: String
    public var title: String?
    public var tags: [String]
    public var metadata: [String: String]
    public var references: [DocumentReferenceDTO]
    public var retention: DocumentRetentionPolicyDTO?

    public init(
        path: String,
        body: String,
        title: String? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:],
        references: [DocumentReferenceDTO] = [],
        retention: DocumentRetentionPolicyDTO? = nil
    ) {
        self.path = path
        self.body = body
        self.title = title
        self.tags = tags
        self.metadata = metadata
        self.references = references
        self.retention = retention
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case body
        case title
        case tags
        case metadata
        case references
        case retention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.body = try container.decode(String.self, forKey: .body)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.references = try container.decodeIfPresent([DocumentReferenceDTO].self, forKey: .references) ?? []
        self.retention = try container.decodeIfPresent(DocumentRetentionPolicyDTO.self, forKey: .retention)
    }

    public func documentInput() throws -> DocumentInput {
        try DocumentInput(
            path: DocumentPath(path),
            title: title,
            body: body,
            tags: tags,
            metadata: metadata,
            references: references.map { try $0.documentReference() },
            retention: retention.map { try $0.retentionPolicy() }
        )
    }
}

public struct ServerListRequest: Codable, Equatable, Sendable {
    public var path: String
    public var recursive: Bool
    public var directoriesOnly: Bool

    public init(path: String = "/", recursive: Bool = false, directoriesOnly: Bool = false) {
        self.path = path
        self.recursive = recursive
        self.directoriesOnly = directoriesOnly
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case recursive
        case directoriesOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decodeIfPresent(String.self, forKey: .path) ?? "/"
        self.recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        self.directoriesOnly = try container.decodeIfPresent(Bool.self, forKey: .directoriesOnly) ?? false
    }

    public func documentPath() throws -> DocumentPath {
        try DocumentPath(path)
    }
}

public struct ServerTreeRequest: Codable, Equatable, Sendable {
    public var path: String
    public var directoriesOnly: Bool
    public var maxDepth: Int?

    public init(path: String = "/", directoriesOnly: Bool = false, maxDepth: Int? = nil) {
        self.path = path
        self.directoriesOnly = directoriesOnly
        self.maxDepth = maxDepth
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case directoriesOnly
        case maxDepth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decodeIfPresent(String.self, forKey: .path) ?? "/"
        self.directoriesOnly = try container.decodeIfPresent(Bool.self, forKey: .directoriesOnly) ?? false
        self.maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
    }

    public func treeQuery() throws -> TreeQuery {
        if let maxDepth, maxDepth < 0 {
            throw ServerRequestDTOError.invalidTreeMaxDepth(maxDepth)
        }
        return try TreeQuery(
            path: DocumentPath(path),
            directoriesOnly: directoriesOnly,
            maxDepth: maxDepth
        )
    }
}

public struct ServerSearchRequest: Codable, Equatable, Sendable {
    public var query: String
    public var pathPrefix: String?
    public var tags: [String]
    public var metadata: [String: String]
    public var includeLinkedDocuments: Bool
    public var includeBacklinks: Bool
    public var limit: Int

    public init(
        query: String,
        pathPrefix: String? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:],
        includeLinkedDocuments: Bool = false,
        includeBacklinks: Bool = false,
        limit: Int = 20
    ) {
        self.query = query
        self.pathPrefix = pathPrefix
        self.tags = tags
        self.metadata = metadata
        self.includeLinkedDocuments = includeLinkedDocuments
        self.includeBacklinks = includeBacklinks
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case pathPrefix
        case tags
        case metadata
        case includeLinkedDocuments
        case includeBacklinks
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try container.decode(String.self, forKey: .query)
        self.pathPrefix = try container.decodeIfPresent(String.self, forKey: .pathPrefix)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.includeLinkedDocuments = try container.decodeIfPresent(Bool.self, forKey: .includeLinkedDocuments) ?? false
        self.includeBacklinks = try container.decodeIfPresent(Bool.self, forKey: .includeBacklinks) ?? false
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20
    }

    public func searchQuery() throws -> SearchQuery {
        guard limit > 0 else {
            throw ServerRequestDTOError.invalidSearchLimit(limit)
        }
        return try SearchQuery(
            text: query,
            pathPrefix: pathPrefix.map(DocumentPath.init),
            tags: tags,
            metadata: metadata,
            includeLinkedDocuments: includeLinkedDocuments,
            includeBacklinks: includeBacklinks,
            limit: limit
        )
    }
}

public struct ServerVersionsRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO

    public init(reference: DocumentReferenceDTO) {
        self.reference = reference
    }

    public func documentReference() throws -> DocumentReference {
        try reference.documentReference()
    }
}

public struct ServerGetRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO
    public var trackingRead: Bool

    public init(reference: DocumentReferenceDTO, trackingRead: Bool = true) {
        self.reference = reference
        self.trackingRead = trackingRead
    }

    private enum CodingKeys: String, CodingKey {
        case reference
        case trackingRead
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reference = try container.decode(DocumentReferenceDTO.self, forKey: .reference)
        self.trackingRead = try container.decodeIfPresent(Bool.self, forKey: .trackingRead) ?? true
    }

    public func documentReference() throws -> DocumentReference {
        try reference.documentReference()
    }
}

public struct ServerPatchRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO
    public var unifiedDiff: String
    public var check: Bool
    public var retention: DocumentRetentionPolicyDTO?

    public init(
        reference: DocumentReferenceDTO,
        unifiedDiff: String,
        check: Bool = false,
        retention: DocumentRetentionPolicyDTO? = nil
    ) {
        self.reference = reference
        self.unifiedDiff = unifiedDiff
        self.check = check
        self.retention = retention
    }

    private enum CodingKeys: String, CodingKey {
        case reference
        case unifiedDiff
        case check
        case retention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reference = try container.decode(DocumentReferenceDTO.self, forKey: .reference)
        self.unifiedDiff = try container.decode(String.self, forKey: .unifiedDiff)
        self.check = try container.decodeIfPresent(Bool.self, forKey: .check) ?? false
        self.retention = try container.decodeIfPresent(DocumentRetentionPolicyDTO.self, forKey: .retention)
    }

    public func documentPatchRequest() throws -> DocumentPatchRequest {
        try DocumentPatchRequest(
            reference: reference.documentReference(),
            unifiedDiff: unifiedDiff,
            retention: retention.map { try $0.retentionPolicy() }
        )
    }
}

public struct ServerMoveRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO
    public var destinationPath: String

    public init(reference: DocumentReferenceDTO, destinationPath: String) {
        self.reference = reference
        self.destinationPath = destinationPath
    }

    public func documentReference() throws -> DocumentReference {
        try reference.documentReference()
    }

    public func documentPath() throws -> DocumentPath {
        try DocumentPath(destinationPath)
    }
}

public struct ServerPruneRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO
    public var retention: DocumentRetentionPolicyDTO?

    public init(reference: DocumentReferenceDTO, retention: DocumentRetentionPolicyDTO? = nil) {
        self.reference = reference
        self.retention = retention
    }

    public func pruneRequest() throws -> PruneRequest {
        guard let retention else {
            throw ServerRequestDTOError.missingRetention
        }
        return try PruneRequest(
            reference: reference.documentReference(),
            policy: retention.retentionPolicy()
        )
    }
}

public struct ServerDeleteRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO

    public init(reference: DocumentReferenceDTO) {
        self.reference = reference
    }

    public func documentReference() throws -> DocumentReference {
        try reference.documentReference()
    }
}

public struct ServerRemoveVersionRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO
    public var sequence: UInt64

    public init(reference: DocumentReferenceDTO, sequence: UInt64) {
        self.reference = reference
        self.sequence = sequence
    }

    public func documentReference() throws -> DocumentReference {
        try reference.documentReference()
    }

    public func validatedSequence() throws -> UInt64 {
        guard sequence > 0 else {
            throw ServerRequestDTOError.invalidRemoveVersionSequence(sequence)
        }
        return sequence
    }
}
