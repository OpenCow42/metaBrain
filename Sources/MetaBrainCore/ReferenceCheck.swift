import Foundation

public enum ReferenceKind: String, Codable, Equatable, Sendable {
    case storeDocument, storePassage, retainedEvidence, externalURL
}

public enum ReferenceLocation: String, Codable, Equatable, Sendable {
    case markdown, documentReference, captureOrigin, claimEvidence
}

public enum ReferenceStatus: String, Codable, Equatable, Sendable {
    case resolved, missingDocument, ambiguousDocument, missingAnchor, ambiguousAnchor
    case invalidReference, unavailableRevision, invalidRange
    case notChecked, unsupportedURL, blockedURL

    public var isDefect: Bool {
        switch self {
        case .resolved, .notChecked, .unsupportedURL, .blockedURL: false
        default: true
        }
    }
}

/// One occurrence and the result of validating it against the selected store.
/// Markdown offsets are half-open Swift Character offsets into the source revision.
public struct ReferenceCheck: Codable, Equatable, Sendable {
    public let sourceID: DocumentID
    public let sourcePath: DocumentPath
    public let sourceVersion: UInt64
    public let location: ReferenceLocation
    public let start: Int?
    public let end: Int?
    public let index: Int?
    public let claimID: UUID?
    public let kind: ReferenceKind
    public let destination: String
    public let status: ReferenceStatus
    public let targetID: DocumentID?
    public let targetPath: DocumentPath?
    public let targetVersion: UInt64?
    public let candidates: [DocumentLinkCandidate]
    public let passage: DocumentPassage?
    public internal(set) var blocksApply: Bool? = nil

    init(
        source: StoredDocument, location: ReferenceLocation, range: Range<Int>? = nil, index: Int? = nil,
        claimID: UUID? = nil, kind: ReferenceKind, destination: String, status: ReferenceStatus,
        target: StoredDocument? = nil, targetID: DocumentID? = nil, targetVersion: UInt64? = nil,
        candidates: [DocumentLinkCandidate] = [], passage: DocumentPassage? = nil
    ) {
        sourceID = source.id
        sourcePath = source.path
        sourceVersion = source.currentVersion
        self.location = location
        start = range?.lowerBound
        end = range?.upperBound
        self.index = index
        self.claimID = claimID
        self.kind = kind
        self.destination = destination
        self.status = status
        self.targetID = target?.id ?? targetID
        targetPath = target?.path
        self.targetVersion = target?.currentVersion ?? targetVersion
        self.candidates = candidates
        self.passage = passage
    }
}

/// Classifies the URL without sending a request. Preserve the original spelling for eligible URLs.
public enum ExternalReference {
    private static let secretKeys: Set<String> = [
        "access_token", "api_key", "apikey", "auth", "authorization", "key", "password", "sig",
        "signature", "token", "x-goog-signature", "x-amz-signature", "x-amz-credential",
        "x-amz-security-token"
    ]

    public static func classify(_ value: String) -> (destination: String, status: ReferenceStatus) {
        guard let parts = URLComponents(string: value) else { return ("[invalid URL]", .invalidReference) }
        guard let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return (value, .unsupportedURL)
        }
        guard parts.user == nil, parts.password == nil,
              !(parts.queryItems ?? []).contains(where: { secretKeys.contains($0.name.lowercased()) }) else {
            return ("[URL with credentials]", .blockedURL)
        }
        guard let host = parts.host, !host.isEmpty, parts.port != 0, (parts.port ?? 1) <= 65535,
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\\" }),
              parts.url != nil else {
            return ("[invalid URL]", .invalidReference)
        }
        return (value, .notChecked)
    }
}
