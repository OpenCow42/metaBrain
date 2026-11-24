import Foundation

public struct RecallPassage: Codable, Equatable, Sendable {
    /// Half-open Swift Character offsets into the cited document body.
    public let start: Int
    public let end: Int
    public let text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct RecallResult: Codable, Equatable, Sendable {
    public static let defaultMaxBytes = 8192
    public static let minimumMaxBytes = 3

    public let documentID: String
    public let path: String
    public let version: UInt64
    public let title: String?
    public let sources: [String]
    public var passages: [RecallPassage]

    public init(
        documentID: String,
        path: String,
        version: UInt64,
        title: String? = nil,
        sources: [String] = [],
        passages: [RecallPassage] = []
    ) {
        self.documentID = documentID
        self.path = path
        self.version = version
        self.title = title
        self.sources = sources
        self.passages = passages
    }

    /// Encodes compact JSON. Command-line output appends one line feed.
    public static func jsonData(_ results: [RecallResult]) throws -> Data {
        try jsonEncoder().encode(results)
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum RecallError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidByteBudget(Int)
    case invalidDocumentLimit(Int)

    public var description: String {
        switch self {
        case .invalidByteBudget(let bytes):
            "Recall requires at least \(RecallResult.minimumMaxBytes) bytes. Received \(bytes)."
        case .invalidDocumentLimit(let limit):
            "Recall requires a positive document limit. Received \(limit)."
        }
    }
}
