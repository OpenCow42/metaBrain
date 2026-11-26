import Foundation

/// A note neighborhood or the documents below one virtual folder.
public enum DocumentGraphScope: Codable, Equatable, Hashable, Sendable {
    case note(id: DocumentID, depth: Int)
    case folder(path: DocumentPath)
}

public struct DocumentGraphQuery: Codable, Equatable, Sendable {
    public var scope: DocumentGraphScope
    public var includeEvidence: Bool
    public var includeUnlinked: Bool
    public var filter: String

    public init(
        scope: DocumentGraphScope, includeEvidence: Bool = false,
        includeUnlinked: Bool = false, filter: String = ""
    ) {
        self.scope = scope
        self.includeEvidence = includeEvidence
        self.includeUnlinked = includeUnlinked
        self.filter = filter
    }
}

public struct DocumentGraphNode: Codable, Equatable, Sendable, Identifiable {
    public let id: DocumentID
    public let path: DocumentPath
    public let title: String?
}

public enum DocumentGraphRelationship: String, Codable, Hashable, Sendable {
    case markdown, reference, supports, contradicts
}

public struct DocumentGraphEvidence: Codable, Equatable, Sendable {
    public let claimID: UUID
    public let claim: String
    public let state: ClaimState
    public let ref: EvidenceReference
}

public enum DocumentGraphOccurrence: Codable, Equatable, Sendable {
    case markdown(DocumentLinkOccurrence)
    case evidence(DocumentGraphEvidence)
}

/// Claim arrows run from the decision to the evidence document.
public struct DocumentGraphConnection: Codable, Equatable, Sendable, Identifiable {
    public struct ID: Codable, Equatable, Hashable, Sendable {
        public let source: DocumentID
        public let target: DocumentID
        public let relationship: DocumentGraphRelationship
    }

    public let id: ID
    public internal(set) var count: Int
    public internal(set) var occurrences: [DocumentGraphOccurrence]
}

public struct DocumentGraph: Codable, Equatable, Sendable {
    public static let nodeLimit = 200
    public static let connectionLimit = 500
    public static let occurrenceLimit = 32

    public let nodes: [DocumentGraphNode]
    public let connections: [DocumentGraphConnection]
    public let diagnostics: [DocumentLinkOccurrence]
    /// A display limit omitted nodes, connections, diagnostics, or occurrence details.
    public let truncated: Bool
}

struct DocumentGraphRecord: Codable, Sendable {
    let title: String?
    let claims: [ProjectClaim]

    init(_ document: StoredDocument) {
        title = document.title
        claims = document.claims ?? []
    }

    var evidenceSources: Set<DocumentID> {
        Set(claims.flatMap { $0.evidence.map(\.sourceID) })
    }
}

struct DocumentGraphBuilder {
    var nodes: [DocumentGraphNode] = []
    var nodeIDs: Set<DocumentID> = []
    var connections: [DocumentGraphConnection] = []
    var diagnostics: [DocumentLinkOccurrence] = []
    var truncated = false
    private var connectionIndices: [DocumentGraphConnection.ID: Int] = [:]
    private var details = 0

    mutating func add(_ node: DocumentGraphNode) -> Bool {
        guard nodes.count < DocumentGraph.nodeLimit else {
            truncated = true
            return false
        }
        nodes.append(node)
        nodeIDs.insert(node.id)
        return true
    }

    mutating func connect(_ id: DocumentGraphConnection.ID, occurrence: DocumentGraphOccurrence? = nil) {
        if connectionIndices[id] == nil {
            guard connections.count < DocumentGraph.connectionLimit else {
                truncated = true
                return
            }
            connectionIndices[id] = connections.count
            connections.append(DocumentGraphConnection(id: id, count: 0, occurrences: []))
        }
        let index = connectionIndices[id]!
        connections[index].count += 1
        guard let occurrence else { return }
        if connections[index].occurrences.count < DocumentGraph.occurrenceLimit, details < 1_000 {
            connections[index].occurrences.append(occurrence)
            details += 1
        } else {
            truncated = true
        }
    }

    mutating func diagnose(_ link: DocumentLinkOccurrence) {
        if diagnostics.count < DocumentGraph.nodeLimit {
            diagnostics.append(link)
        } else {
            truncated = true
        }
    }

    var result: DocumentGraph {
        DocumentGraph(nodes: nodes, connections: connections, diagnostics: diagnostics, truncated: truncated)
    }
}
