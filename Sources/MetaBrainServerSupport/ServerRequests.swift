import Foundation
import MetaBrainCore

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
