import Foundation

struct ServerSourceChunk: Codable, Sendable {
    let bytes: Data
}

struct ServerSourceChunkDigest: Codable, Sendable {
    let sha256: String
}

struct ServerSourceFinishRequest: Codable, Sendable {
    let chunks: [String]
}

struct ServerSourceDescriptorRequest: Codable, Sendable {
    let reference: DocumentReferenceDTO
    let version: UInt64?
}

struct ServerSourceReadRequest: Codable, Sendable {
    let reference: DocumentReferenceDTO
    let version: UInt64
    let index: Int
}
