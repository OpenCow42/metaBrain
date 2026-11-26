import Foundation

public enum DocumentLinkDirection: String, Codable, Equatable, Sendable {
    case outgoing
    case incoming
}

public enum DocumentLinkSyntax: String, Codable, Equatable, Sendable {
    case wiki
    case markdown
}

public enum DocumentLinkStatus: String, Codable, Equatable, Sendable {
    case resolved
    case unresolved
    case ambiguous
    case external
}

public struct DocumentLinkCandidate: Codable, Equatable, Sendable {
    public let documentID: DocumentID
    public let path: DocumentPath

    public init(documentID: DocumentID, path: DocumentPath) {
        self.documentID = documentID
        self.path = path
    }
}

/// One occurrence in a current Markdown document. Offsets count Swift Characters.
public struct DocumentLinkOccurrence: Codable, Equatable, Sendable {
    public let sourceID: DocumentID
    public let sourcePath: DocumentPath
    public let sourceVersion: UInt64
    public let start: Int
    public let end: Int
    public let snippet: String
    public let label: String?
    public let destination: String
    public let syntax: DocumentLinkSyntax
    let embed: Bool?
    public var isEmbed: Bool { embed == true }
    public let sourceBlock: String?
    public let fragment: String?
    public let targetID: DocumentID?
    public let targetPath: DocumentPath?
    public let status: DocumentLinkStatus
    public let candidates: [DocumentLinkCandidate]

    public init(
        sourceID: DocumentID, sourcePath: DocumentPath, sourceVersion: UInt64, start: Int, end: Int,
        snippet: String, label: String?, destination: String, syntax: DocumentLinkSyntax, embed: Bool?,
        sourceBlock: String?, fragment: String?, targetID: DocumentID?, targetPath: DocumentPath?,
        status: DocumentLinkStatus, candidates: [DocumentLinkCandidate]
    ) {
        self.sourceID = sourceID
        self.sourcePath = sourcePath
        self.sourceVersion = sourceVersion
        self.start = start
        self.end = end
        self.snippet = snippet
        self.label = label
        self.destination = destination
        self.syntax = syntax
        self.embed = embed
        self.sourceBlock = sourceBlock
        self.fragment = fragment
        self.targetID = targetID
        self.targetPath = targetPath
        self.status = status
        self.candidates = candidates
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, sourcePath, sourceVersion, start, end, snippet, label, destination, syntax
        case embed = "isEmbed"
        case sourceBlock, fragment, targetID, targetPath, status, candidates
    }
}

public enum DocumentPassageSelector: Codable, Equatable, Hashable, Sendable {
    case heading(String)
    case block(String)
    /// Half-open Swift Character offsets into the selected revision's body.
    case range(start: Int, end: Int)

    /// Interprets a decoded Markdown fragment using the store's heading and block conventions.
    public init?(markdownFragment: String) {
        guard !markdownFragment.isEmpty else { return nil }
        self = markdownFragment.hasPrefix("^") ? .block(markdownFragment) : .heading(markdownFragment)
    }
}

public struct DocumentPassage: Codable, Equatable, Sendable {
    public let documentID: DocumentID
    public let path: DocumentPath
    public let version: UInt64
    public let selector: DocumentPassageSelector
    public let passage: RecallPassage
}

public enum DocumentPassageError: Error, Equatable, Sendable, CustomStringConvertible {
    case ambiguousSelector(String)
    case invalidRange(start: Int, end: Int)

    public var description: String {
        switch self {
        case .ambiguousSelector(let selector):
            "More than one passage matches \(selector)."
        case .invalidRange(let start, let end):
            "Invalid passage range \(start)..<\(end) for this revision."
        }
    }
}
