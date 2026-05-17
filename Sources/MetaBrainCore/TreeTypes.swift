import Foundation

public struct DocumentTreeEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        path.rawValue
    }

    public var path: DocumentPath
    public var name: String
    public var hasChildren: Bool
    public var documentID: DocumentID?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        path: DocumentPath,
        name: String,
        hasChildren: Bool,
        documentID: DocumentID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.hasChildren = hasChildren
        self.documentID = documentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TreeQuery: Codable, Equatable, Sendable {
    public var path: DocumentPath
    public var directoriesOnly: Bool
    public var maxDepth: Int?

    public init(
        path: DocumentPath = try! DocumentPath("/"),
        directoriesOnly: Bool = false,
        maxDepth: Int? = nil
    ) {
        self.path = path
        self.directoriesOnly = directoriesOnly
        self.maxDepth = maxDepth
    }
}
