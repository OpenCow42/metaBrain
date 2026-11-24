import Crypto
import Foundation

/// A single, retryable set of replacements or creations below one virtual project root.
public struct ProjectOperation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let project: DocumentPath
    public let documents: [DocumentInput]

    public init(operationID: UUID, project: DocumentPath, documents: [DocumentInput]) {
        self.operationID = operationID
        self.project = project
        self.documents = documents
    }

    func validate() throws {
        guard project != (try DocumentPath("/")), try DocumentPath(project.rawValue) == project,
              !documents.isEmpty else {
            throw ProjectOperationError.invalid("Select a project below / and at least one document.")
        }
        let prefix = (project.rawValue + "/").utf8
        var paths: Set<DocumentPath> = []
        for document in documents {
            // Codable inputs may come over the wire without passing through the public path initializer.
            guard try DocumentPath(document.path.rawValue) == document.path,
                  document.path.rawValue.utf8.starts(with: prefix),
                  paths.insert(document.path).inserted else {
                throw ProjectOperationError.invalid("Expected a unique document path under \(project): \(document.path)")
            }
        }
    }
}

public enum ProjectOperationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)
    case conflict(String)

    public var description: String {
        switch self {
        case .invalid(let detail), .conflict(let detail): detail
        }
    }
}

/// The identity and version observed during inspection. An absent document has version zero.
public struct OperationTarget: Codable, Equatable, Sendable {
    public let path: DocumentPath
    public let documentID: DocumentID?
    public let version: UInt64
}

public struct OperationPreview: Codable, Equatable, Sendable {
    public let operation: ProjectOperation
    public let storePath: String
    public let storeIdentity: UUID
    public let targets: [OperationTarget]
    public let digest: String

    static func make(
        operation: ProjectOperation,
        storePath: String,
        storeIdentity: UUID,
        targets: [OperationTarget]
    ) throws -> Self {
        let payload = ReviewedOperation(
            operation: operation, storePath: storePath, storeIdentity: storeIdentity, targets: targets
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return Self(
            operation: operation, storePath: storePath, storeIdentity: storeIdentity, targets: targets,
            digest: digest.hexString
        )
    }

    func verify() throws {
        try operation.validate()
        guard targets.map(\.path) == operation.documents.map(\.path),
              targets.allSatisfy({ ($0.documentID == nil) == ($0.version == 0) }) else {
            throw ProjectOperationError.invalid("The inspected targets do not match the proposed writes.")
        }
        let expected = try Self.make(
            operation: operation, storePath: storePath, storeIdentity: storeIdentity, targets: targets
        )
        guard digest == expected.digest else {
            throw ProjectOperationError.invalid("The operation differs from the inspected preview.")
        }
    }
}

private struct ReviewedOperation: Encodable {
    let operation: ProjectOperation
    let storePath: String
    let storeIdentity: UUID
    let targets: [OperationTarget]
}

extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Persisted in the same batch as the changes it describes.
public struct OperationReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let digest: String
    public let results: [OperationResult]
}

public struct OperationResult: Codable, Equatable, Sendable {
    public let path: DocumentPath
    public let documentID: DocumentID
    public let version: UInt64
    public let status: DocumentWriteStatus
}
