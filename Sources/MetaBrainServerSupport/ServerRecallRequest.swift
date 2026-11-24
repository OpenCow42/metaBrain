import MetaBrainCore

public struct ServerRecallRequest: Codable, Equatable, Sendable {
    public static let defaultLimit = 5
    public static let maximumOutputBytes = 1_048_576

    public var query: String
    public var pathPrefix: String?
    public var tags: [String]?
    public var metadata: [String: String]?
    public var limit: Int?
    public var maxBytes: Int?

    public init(
        query: String,
        pathPrefix: String? = nil,
        tags: [String]? = nil,
        metadata: [String: String]? = nil,
        limit: Int? = nil,
        maxBytes: Int? = nil
    ) {
        self.query = query
        self.pathPrefix = pathPrefix
        self.tags = tags
        self.metadata = metadata
        self.limit = limit
        self.maxBytes = maxBytes
    }

    public func searchQuery() throws -> SearchQuery {
        try ServerSearchRequest(
            query: query,
            pathPrefix: pathPrefix,
            tags: tags ?? [],
            metadata: metadata ?? [:],
            limit: limit ?? Self.defaultLimit
        ).searchQuery()
    }

    public func validatedMaxBytes() throws -> Int {
        let budget = maxBytes ?? RecallResult.defaultMaxBytes
        guard (RecallResult.minimumMaxBytes...Self.maximumOutputBytes).contains(budget) else {
            throw RecallBudgetError.outOfRange(budget)
        }
        return budget
    }

    private enum RecallBudgetError: Error, CustomStringConvertible {
        case outOfRange(Int)

        var description: String {
            switch self {
            case .outOfRange(let value):
                "maxBytes must be between \(RecallResult.minimumMaxBytes) and \(ServerRecallRequest.maximumOutputBytes), got \(value)."
            }
        }
    }
}
