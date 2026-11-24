import MetaBrainCore

public struct DocumentPassageOutput: Codable, Equatable, Sendable {
    public var documentID: String
    public var path: String
    public var version: UInt64
    public var start: Int
    public var end: Int
    public var text: String
    public var block: String?
    public var heading: String?

    public init(_ result: DocumentPassage) {
        documentID = result.documentID.rawValue
        path = result.path.rawValue
        version = result.version
        start = result.passage.start
        end = result.passage.end
        text = result.passage.text
        switch result.selector {
        case .block(let id):
            block = id
        case .heading(let title):
            heading = title
        case .range:
            break
        }
    }
}

public struct DocumentLinkOutput: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public var documentID: String
        public var path: String
    }

    public var sourceID: String
    public var sourcePath: String
    public var sourceVersion: UInt64
    public var start: Int
    public var end: Int
    public var snippet: String
    public var label: String?
    public var destination: String
    public var syntax: DocumentLinkSyntax
    public var isEmbed: Bool
    public var sourceBlock: String?
    public var fragment: String?
    public var targetID: String?
    public var targetPath: String?
    public var status: DocumentLinkStatus
    public var candidates: [Candidate]?

    public init(_ occurrence: DocumentLinkOccurrence) {
        sourceID = occurrence.sourceID.rawValue
        sourcePath = occurrence.sourcePath.rawValue
        sourceVersion = occurrence.sourceVersion
        start = occurrence.start
        end = occurrence.end
        snippet = occurrence.snippet
        label = occurrence.label
        destination = occurrence.destination
        syntax = occurrence.syntax
        isEmbed = occurrence.isEmbed
        sourceBlock = occurrence.sourceBlock
        fragment = occurrence.fragment
        targetID = occurrence.targetID?.rawValue
        targetPath = occurrence.targetPath?.rawValue
        status = occurrence.status
        if !occurrence.candidates.isEmpty {
            candidates = occurrence.candidates.map {
                Candidate(documentID: $0.documentID.rawValue, path: $0.path.rawValue)
            }
        }
    }
}
