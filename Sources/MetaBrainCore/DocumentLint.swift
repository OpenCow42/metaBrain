/// Selects the current Markdown documents to audit. A nil path selects the whole store.
public struct DocumentLintQuery: Equatable, Sendable {
    public var path: DocumentPath?
    public var includeOrphans: Bool

    public init(path: DocumentPath? = nil, includeOrphans: Bool = false) {
        self.path = path
        self.includeOrphans = includeOrphans
    }
}

public enum DocumentLintKind: String, CaseIterable, Codable, Equatable, Sendable {
    case missingTarget
    case ambiguousTarget
    case missingAnchor
    case ambiguousAnchor
    case orphan
}

/// A finding in a current revision. Citation offsets count Swift Characters and exclude the end.
public struct DocumentLintFinding: Codable, Equatable, Sendable {
    public let kind: DocumentLintKind
    public let sourceID: String
    public let sourcePath: String
    public let sourceVersion: UInt64
    public let start: Int?
    public let end: Int?
    public let destination: String?
    public let targetPath: String?
    public let fragment: String?
    public let candidatePaths: [String]?

    init?(_ link: DocumentLinkOccurrence) {
        switch link.status {
        case .resolved, .external:
            return nil
        case .unresolved:
            kind = link.targetPath == nil ? .missingTarget : .missingAnchor
        case .ambiguous:
            kind = link.targetPath == nil ? .ambiguousTarget : .ambiguousAnchor
        }
        sourceID = link.sourceID.rawValue
        sourcePath = link.sourcePath.rawValue
        sourceVersion = link.sourceVersion
        start = link.start
        end = link.end
        destination = link.destination
        targetPath = link.targetPath?.rawValue
        fragment = link.fragment
        candidatePaths = link.candidates.isEmpty ? nil : link.candidates.map(\.path.rawValue)
    }

    init(orphan document: StoredDocument) {
        kind = .orphan
        sourceID = document.id.rawValue
        sourcePath = document.path.rawValue
        sourceVersion = document.currentVersion
        start = nil
        end = nil
        destination = nil
        targetPath = nil
        fragment = nil
        candidatePaths = nil
    }
}

public struct DocumentLintReport: Codable, Equatable, Sendable {
    public let path: String
    public let documentsChecked: Int
    /// Counts keyed by `DocumentLintKind.rawValue`, including zero counts.
    public let counts: [String: Int]
    public let findings: [DocumentLintFinding]

    init(path: String, documentsChecked: Int, findings: [DocumentLintFinding]) {
        self.path = path
        self.documentsChecked = documentsChecked
        var counts = Dictionary(uniqueKeysWithValues: DocumentLintKind.allCases.map { ($0.rawValue, 0) })
        for finding in findings { counts[finding.kind.rawValue, default: 0] += 1 }
        self.counts = counts
        self.findings = findings
    }
}
