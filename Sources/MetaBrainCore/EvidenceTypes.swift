import Foundation

public enum EvidenceSearchView: String, Codable, Sendable {
    case evidence
    case refs
}

public enum EvidenceContext: String, Codable, Sendable {
    case section
}

/// A retained document version and either an exact body range or a named Markdown block.
public struct EvidenceReference: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Location: Hashable, Sendable {
        /// Half-open Swift Character offsets into the exact revision body.
        case range(Range<Int>)
        case block(String)
    }

    public let documentID: DocumentID
    public let version: UInt64
    public let location: Location

    /// Parses `DOCUMENTID@VERSION#START-END` or `DOCUMENTID@VERSION#^BLOCK`.
    public init(_ rawValue: String) throws {
        let components = rawValue.split(separator: "#", omittingEmptySubsequences: false)
        guard components.count == 2 else { throw EvidenceError.invalidReference(rawValue) }
        let document = components[0].split(separator: "@", omittingEmptySubsequences: false)
        guard document.count == 2,
              let id = try? DocumentID(rawValue: String(document[0])), id.rawValue == document[0],
              Self.isDecimal(document[1]), let version = UInt64(document[1]), version > 0 else {
            throw EvidenceError.invalidReference(rawValue)
        }

        let target = components[1]
        if target.hasPrefix("^"), Self.isBlockName(target.dropFirst()) {
            location = .block(String(target.dropFirst()))
        } else {
            let offsets = target.split(separator: "-", omittingEmptySubsequences: false)
            guard offsets.count == 2, Self.isDecimal(offsets[0]), Self.isDecimal(offsets[1]),
                  let start = Int(offsets[0]), let end = Int(offsets[1]), start <= end else {
                throw EvidenceError.invalidReference(rawValue)
            }
            location = .range(start..<end)
        }
        self.documentID = id
        self.version = version
    }

    init(document: StoredDocument, location: Location) {
        documentID = document.id
        version = document.currentVersion
        self.location = location
    }

    public var rawValue: String {
        let target: String
        switch location {
        case .range(let range): target = "\(range.lowerBound)-\(range.upperBound)"
        case .block(let name): target = "^\(name)"
        }
        return "\(documentID.rawValue)@\(version)#\(target)"
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }

    private static func isDecimal(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isBlockName(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public struct EvidenceItem: Codable, Equatable, Sendable {
    public let ref: EvidenceReference
    public let path: String
    /// Exact body text when requested. A refs-only item omits this property.
    public let text: String?

    public init(ref: EvidenceReference, path: String, text: String? = nil) {
        self.ref = ref
        self.path = path
        self.text = text
    }
}

/// Compact JSON output whose UTF-8 byte count bounds its tokens for lossless byte-level tokenizers.
public struct EvidenceOutput: Codable, Equatable, Sendable {
    public static let defaultMaxTokens = 4096
    /// The bytes required by an empty result, including the final line feed.
    public static let minimumMaxTokens = 31

    public let items: [EvidenceItem]
    public let truncated: Bool

    public init(items: [EvidenceItem], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }

    /// Encodes compact JSON. The command line appends one line feed, which the budget reserves.
    public func jsonData() throws -> Data {
        try RecallResult.jsonEncoder().encode(self)
    }

    public func fits(maxTokens: Int) throws -> Bool {
        try jsonData().count < maxTokens
    }
}

public enum EvidenceError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidReference(String)
    case invalidRange(EvidenceReference)
    case blockNotFound(EvidenceReference)
    case invalidTokenBudget(Int)
    case invalidDocumentLimit(Int)
    case missingTextOrFilters
    case filterOnlyRequiresRefs

    public var description: String {
        switch self {
        case .invalidReference(let value):
            "Invalid evidence reference '\(value)'. Use DOCUMENTID@VERSION#START-END or DOCUMENTID@VERSION#^BLOCK."
        case .invalidRange(let reference):
            "Evidence range in '\(reference)' is outside the retained document body."
        case .blockNotFound(let reference):
            "Evidence block in '\(reference)' is missing or ambiguous in the retained document body."
        case .invalidTokenBudget(let value):
            "Evidence output requires a budget of at least \(EvidenceOutput.minimumMaxTokens) tokens. Received \(value)."
        case .invalidDocumentLimit(let value):
            "Evidence search requires a positive document limit. Received \(value)."
        case .missingTextOrFilters:
            "Evidence search requires text or at least one path, tag, or metadata filter."
        case .filterOnlyRequiresRefs:
            "Search without text requires the refs view."
        }
    }
}
