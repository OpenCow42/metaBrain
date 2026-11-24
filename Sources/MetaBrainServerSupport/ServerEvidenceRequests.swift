import MetaBrainCore

public struct ServerMarkdownPutRequest: Codable, Equatable, Sendable {
    public var document: ServerPutRequest
    public var ifVersion: UInt64?

    public init(document: ServerPutRequest, ifVersion: UInt64? = nil) {
        self.document = document
        self.ifVersion = ifVersion
    }

    public func documentInput() throws -> DocumentInput {
        var input = try document.documentInput()
        input.markdown = true
        return input
    }
}

public struct ServerLinksRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO
    public var direction: DocumentLinkDirection?
    public var block: String?

    public init(
        reference: DocumentReferenceDTO,
        direction: DocumentLinkDirection? = nil,
        block: String? = nil
    ) {
        self.reference = reference
        self.direction = direction
        self.block = block
    }
}

public struct ServerGetPassageRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReferenceDTO
    public var block: String?
    public var heading: String?
    public var version: UInt64?

    public init(
        reference: DocumentReferenceDTO,
        block: String? = nil,
        heading: String? = nil,
        version: UInt64? = nil
    ) {
        self.reference = reference
        self.block = block
        self.heading = heading
        self.version = version
    }

    public func passageSelector() throws -> DocumentPassageSelector {
        switch (block, heading) {
        case (.some(let block), nil) where !block.isEmpty:
            return .block(block)
        case (nil, .some(let heading)) where !heading.isEmpty:
            return .heading(heading)
        default:
            throw ServerPassageError.missingSelector
        }
    }

    public func read(from store: MetaBrainStore) async throws -> DocumentPassageOutput {
        guard let passage = try await store.readPassage(
            reference.documentReference(), selector: passageSelector(), version: version
        ) else {
            throw ServerPassageError.passageNotFound
        }
        return DocumentPassageOutput(passage)
    }
}

public enum ServerPassageError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingSelector
    case passageNotFound

    public var description: String {
        switch self {
        case .missingSelector:
            return "Provide one nonempty block ID or heading."
        case .passageNotFound:
            return "The requested passage was not found."
        }
    }
}

public struct ServerGetEvidenceRequest: Codable, Equatable, Sendable {
    public var ref: EvidenceReference
    public var context: EvidenceContext?
    public var maxTokens: Int?

    public init(ref: EvidenceReference, context: EvidenceContext? = nil, maxTokens: Int? = nil) {
        self.ref = ref
        self.context = context
        self.maxTokens = maxTokens
    }
}

public struct ServerEvidenceSearchRequest: Codable, Equatable, Sendable {
    public var query: String?
    public var pathPrefix: String?
    public var tags: [String]?
    public var metadata: [String: String]?
    public var limit: Int?
    public var view: EvidenceSearchView
    public var maxTokens: Int?

    public init(
        query: String? = nil,
        pathPrefix: String? = nil,
        tags: [String]? = nil,
        metadata: [String: String]? = nil,
        limit: Int? = nil,
        view: EvidenceSearchView,
        maxTokens: Int? = nil
    ) {
        self.query = query
        self.pathPrefix = pathPrefix
        self.tags = tags
        self.metadata = metadata
        self.limit = limit
        self.view = view
        self.maxTokens = maxTokens
    }

    public func searchQuery() throws -> SearchQuery {
        try ServerSearchRequest(
            query: query ?? "",
            pathPrefix: pathPrefix,
            tags: tags ?? [],
            metadata: metadata ?? [:],
            limit: limit ?? 20
        ).searchQuery()
    }
}
