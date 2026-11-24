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

    /// Stable ID used if this operation creates the path. Inspect reports it for each absent target.
    public func creationID(for path: DocumentPath) -> DocumentID {
        let name = operationID.uuidString.lowercased() + "/" + path.rawValue
        // Preserve the UUID spelling exposed by normal document creation. Version 8 is application-defined.
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return try! DocumentID(rawValue: uuid.uuidString)
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

public struct OperationCreation: Codable, Equatable, Sendable {
    public let path: DocumentPath
    public let documentID: DocumentID
}

public struct OperationPreview: Codable, Equatable, Sendable {
    public let operation: ProjectOperation
    public let storePath: String
    public let storeIdentity: UUID
    public let targets: [OperationTarget]
    public let digest: String
    /// Derived from the reviewed operation and absent targets; older previews may omit it.
    public private(set) var creations: [OperationCreation]? = nil

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
        var preview = Self(
            operation: operation, storePath: storePath, storeIdentity: storeIdentity, targets: targets,
            digest: digest.hexString
        )
        preview.creations = targets.compactMap { target in
            guard target.documentID == nil else { return nil }
            return OperationCreation(path: target.path, documentID: operation.creationID(for: target.path))
        }
        return preview
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
        guard digest == expected.digest, creations == nil || creations == expected.creations else {
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
