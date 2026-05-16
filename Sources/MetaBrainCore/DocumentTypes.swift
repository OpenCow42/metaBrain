import Foundation

public struct DocumentID: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValid(normalized) else {
            throw MetaBrainDomainError.invalidDocumentID(rawValue)
        }

        self.rawValue = normalized
    }

    public static func generate() -> DocumentID {
        try! DocumentID(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: DocumentID, rhs: DocumentID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        return value.unicodeScalars.allSatisfy { scalar in
            scalar == "-" || scalar == "_" ||
                (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 97 && scalar.value <= 122)
        }
    }
}

public struct DocumentPath: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ value: String) throws {
        rawValue = try Self.normalized(value)
    }

    public var parent: DocumentPath? {
        guard rawValue != "/" else {
            return nil
        }

        let segments = rawValue.split(separator: "/").map(String.init)
        guard segments.count > 1 else {
            return try? DocumentPath("/")
        }

        return try? DocumentPath("/" + segments.dropLast().joined(separator: "/"))
    }

    public var name: String {
        rawValue.split(separator: "/").last.map(String.init) ?? "/"
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: DocumentPath, rhs: DocumentPath) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func normalized(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MetaBrainDomainError.invalidDocumentPath(value)
        }

        let slashSeparated = trimmed.replacingOccurrences(of: "\\", with: "/")
        var segments: [String] = []

        for rawSegment in slashSeparated.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(rawSegment)

            if segment == "." {
                continue
            }

            if segment == ".." {
                guard !segments.isEmpty else {
                    throw MetaBrainDomainError.invalidDocumentPath(value)
                }

                segments.removeLast()
                continue
            }

            guard segment.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw MetaBrainDomainError.invalidDocumentPath(value)
            }

            segments.append(segment)
        }

        return "/" + segments.joined(separator: "/")
    }
}

public struct DocumentInput: Codable, Equatable, Sendable {
    public var path: DocumentPath
    public var title: String?
    public var body: String
    public var tags: [String]
    public var metadata: [String: String]
    public var references: [DocumentReference]
    public var retention: VersionRetentionPolicy?

    public init(
        path: DocumentPath,
        title: String? = nil,
        body: String,
        tags: [String] = [],
        metadata: [String: String] = [:],
        references: [DocumentReference] = [],
        retention: VersionRetentionPolicy? = nil
    ) {
        self.path = path
        self.title = title
        self.body = body
        self.tags = tags
        self.metadata = metadata
        self.references = references
        self.retention = retention
    }
}

public struct StoredDocument: Codable, Equatable, Sendable, Identifiable {
    public var id: DocumentID
    public var path: DocumentPath
    public var title: String?
    public var body: String
    public var tags: [String]
    public var metadata: [String: String]
    public var references: [DocumentReference]
    public var currentVersion: UInt64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: DocumentID,
        path: DocumentPath,
        title: String? = nil,
        body: String,
        tags: [String] = [],
        metadata: [String: String] = [:],
        references: [DocumentReference] = [],
        currentVersion: UInt64,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.body = body
        self.tags = tags
        self.metadata = metadata
        self.references = references
        self.currentVersion = currentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum DocumentReference: Codable, Equatable, Hashable, Sendable {
    case documentID(DocumentID)
    case path(DocumentPath)
    case externalURL(URL)
}

public struct DocumentVersion: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        "\(documentID.rawValue):\(sequence)"
    }

    public var documentID: DocumentID
    public var sequence: UInt64
    public var snapshot: DocumentInput
    public var createdAt: Date
    public var isPinned: Bool

    public init(
        documentID: DocumentID,
        sequence: UInt64,
        snapshot: DocumentInput,
        createdAt: Date,
        isPinned: Bool = false
    ) {
        self.documentID = documentID
        self.sequence = sequence
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.isPinned = isPinned
    }
}

public enum VersionRetentionPolicy: Codable, Equatable, Sendable {
    case keepAll
    case keepMostRecent(Int)
    case keepWithin(TimeInterval)
}

public struct PruneRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReference
    public var policy: VersionRetentionPolicy

    public init(reference: DocumentReference, policy: VersionRetentionPolicy) {
        self.reference = reference
        self.policy = policy
    }
}

public struct PruneResult: Codable, Equatable, Sendable {
    public var prunedVersionCount: Int
    public var retainedVersionCount: Int

    public init(prunedVersionCount: Int, retainedVersionCount: Int) {
        self.prunedVersionCount = prunedVersionCount
        self.retainedVersionCount = retainedVersionCount
    }
}

public enum MetaBrainDomainError: Error, Equatable, Sendable {
    case invalidDocumentID(String)
    case invalidDocumentPath(String)
}
