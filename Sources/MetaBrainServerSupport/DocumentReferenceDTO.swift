import Foundation
import MetaBrainCore

public enum MetaBrainDTOError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidURLReference(String)
    case invalidRetentionCount(Int?)
    case invalidRetentionSeconds(TimeInterval?)

    public var description: String {
        switch self {
        case .invalidURLReference(let value):
            return "Reference URL must be absolute: \(value)"
        case .invalidRetentionCount(let count):
            let rendered = count.map { String($0) } ?? "nil"
            return "keepLast retention count must be greater than zero, got \(rendered)"
        case .invalidRetentionSeconds(let seconds):
            let rendered = seconds.map { String($0) } ?? "nil"
            return "keepWithin retention seconds must be zero or greater, got \(rendered)"
        }
    }
}

public enum DocumentReferenceDTOKind: String, Codable, Equatable, Sendable {
    case documentID
    case path
    case url
}

public struct DocumentReferenceDTO: Codable, Equatable, Sendable {
    public var kind: DocumentReferenceDTOKind
    public var value: String

    public init(kind: DocumentReferenceDTOKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public init(_ reference: DocumentReference) {
        switch reference {
        case .documentID(let id):
            self.init(kind: .documentID, value: id.rawValue)
        case .path(let path):
            self.init(kind: .path, value: path.rawValue)
        case .externalURL(let url):
            self.init(kind: .url, value: url.absoluteString)
        }
    }

    public func documentReference() throws -> DocumentReference {
        switch kind {
        case .documentID:
            return .documentID(try DocumentID(rawValue: value))
        case .path:
            return .path(try DocumentPath(value))
        case .url:
            guard let url = URL(string: value), url.scheme != nil else {
                throw MetaBrainDTOError.invalidURLReference(value)
            }
            return .externalURL(url)
        }
    }
}

public struct DocumentReferenceListDTO: Codable, Equatable, Sendable {
    public var references: [DocumentReferenceDTO]

    public init(references: [DocumentReferenceDTO] = []) {
        self.references = references
    }

    public init(_ references: [DocumentReference]) {
        self.references = references.map(DocumentReferenceDTO.init)
    }

    public func documentReferences() throws -> [DocumentReference] {
        try references.map { try $0.documentReference() }
    }
}
