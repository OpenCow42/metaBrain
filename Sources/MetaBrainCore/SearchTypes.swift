import Foundation

public struct SearchQuery: Codable, Equatable, Sendable {
    public var text: String
    public var pathPrefix: DocumentPath?
    public var tags: [String]
    public var metadata: [String: String]
    public var includeLinkedDocuments: Bool
    public var includeBacklinks: Bool
    public var limit: Int

    public init(
        text: String,
        pathPrefix: DocumentPath? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:],
        includeLinkedDocuments: Bool = false,
        includeBacklinks: Bool = false,
        limit: Int = 20
    ) {
        self.text = text
        self.pathPrefix = pathPrefix
        self.tags = tags
        self.metadata = metadata
        self.includeLinkedDocuments = includeLinkedDocuments
        self.includeBacklinks = includeBacklinks
        self.limit = limit
    }
}

public struct SearchResult: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        "\(documentID.rawValue):\(chunkOrdinal)"
    }

    public var documentID: DocumentID
    public var path: DocumentPath
    public var title: String?
    public var chunkOrdinal: UInt32
    public var snippet: String
    public var score: Double
    public var context: [SearchContextChunk]
    public var linkedDocuments: [DocumentReference]
    public var backlinks: [DocumentReference]

    public init(
        documentID: DocumentID,
        path: DocumentPath,
        title: String? = nil,
        chunkOrdinal: UInt32,
        snippet: String,
        score: Double,
        context: [SearchContextChunk] = [],
        linkedDocuments: [DocumentReference] = [],
        backlinks: [DocumentReference] = []
    ) {
        self.documentID = documentID
        self.path = path
        self.title = title
        self.chunkOrdinal = chunkOrdinal
        self.snippet = snippet
        self.score = score
        self.context = context
        self.linkedDocuments = linkedDocuments
        self.backlinks = backlinks
    }
}

public struct SearchContextChunk: Codable, Equatable, Sendable {
    public var ordinal: UInt32
    public var text: String

    public init(ordinal: UInt32, text: String) {
        self.ordinal = ordinal
        self.text = text
    }
}
