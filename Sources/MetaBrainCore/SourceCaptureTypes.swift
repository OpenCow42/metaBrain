import Foundation

/// Content identity for the exact original bytes. Chunks use zero-based indices.
public struct SourceBlob: Codable, Equatable, Sendable {
    public static let chunkSize = 1_048_576
    public let sha256: String
    public let byteCount: Int

    public init(sha256: String, byteCount: Int) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public var chunkCount: Int { byteCount <= 0 ? 0 : 1 + (byteCount - 1) / Self.chunkSize }

    /// Calculates the original byte count after the individual chunk sizes have been checked.
    static func verifiedByteCount(chunkCount: Int, finalChunkSize: Int) throws -> Int {
        let fullChunks = max(0, chunkCount - 1)
        let (prefixBytes, prefixOverflow) = fullChunks.multipliedReportingOverflow(by: chunkSize)
        let (total, totalOverflow) = prefixBytes.addingReportingOverflow(finalChunkSize)
        guard !prefixOverflow, !totalOverflow else {
            throw ProjectOperationError.invalid("The original source is too large.")
        }
        return total
    }

    public func validate() throws {
        guard byteCount >= 0, Self.isDigest(sha256) else {
            throw ProjectOperationError.invalid("Expected a nonnegative byte count and lowercase SHA-256 digest.")
        }
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Provenance of one captured original, attached to a retained document revision.
public struct SourceCapture: Codable, Equatable, Sendable {
    public let blob: SourceBlob
    public let filename: String
    public let mediaType: String
    public let origin: String
    /// The method actually used to derive the document text, when applicable.
    public let extraction: String?

    public init(blob: SourceBlob, filename: String, mediaType: String, origin: String, extraction: String? = nil) {
        self.blob = blob
        self.filename = filename
        self.mediaType = mediaType
        self.origin = origin
        self.extraction = extraction
    }

    public func validate() throws {
        try blob.validate()
        try Self.validateMetadata(filename: filename, mediaType: mediaType, origin: origin, extraction: extraction)
    }

    public static func validateMetadata(filename: String, mediaType: String, origin: String, extraction: String?) throws {
        guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"),
              filename.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProjectOperationError.invalid("Expected an original filename without directory components.")
        }
        let type = mediaType.prefix { $0 != ";" }
        guard type.split(separator: "/", omittingEmptySubsequences: false).count == 2,
              !type.hasPrefix("/"), !type.hasSuffix("/"),
              type.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              mediaType.rangeOfCharacter(from: .controlCharacters) == nil,
              !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              extraction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw ProjectOperationError.invalid("Provide a media type, an origin and, when specified, a nonempty extraction method.")
        }
    }
}

public struct SourceDescriptor: Codable, Equatable, Sendable {
    public let documentID: DocumentID
    public let version: UInt64
    public let capture: SourceCapture

    public init(documentID: DocumentID, version: UInt64, capture: SourceCapture) {
        self.documentID = documentID
        self.version = version
        self.capture = capture
    }
}
