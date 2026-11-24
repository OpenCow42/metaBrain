import Foundation

/// Read-only previews of portable wiki formats. The source remains available for editing.
public enum WikiPreview {
    /// Parses a JSON Canvas 1.0 board and resolves its file nodes within the project.
    public static func canvas(body: String, project: DocumentPath) throws -> WikiCanvas {
        let decoder = JSONDecoder()
        decoder.userInfo[.canvasProject] = project
        return try decoder.decode(WikiCanvas.self, from: Data(body.utf8))
    }
}

/// A validation failure that can be presented alongside the original source.
public struct WikiPreviewError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

/// Nodes appear in stacking order, from bottom to top.
public struct WikiCanvas: Encodable, Sendable {
    public let nodes: [WikiCanvasNode]
    public let edges: [WikiCanvasEdge]
}

extension WikiCanvas: Decodable {
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try fields.contains(.nodes) ? fields.decode([WikiCanvasNode].self, forKey: .nodes) : []
        edges = try fields.contains(.edges) ? fields.decode([WikiCanvasEdge].self, forKey: .edges) : []
        let nodeIDs = Set(nodes.map(\.id))
        guard nodeIDs.count == nodes.count else {
            throw WikiPreviewError("Canvas node IDs must be unique.")
        }
        guard Set(edges.map(\.id)).count == edges.count else {
            throw WikiPreviewError("Canvas edge IDs must be unique.")
        }
        for edge in edges {
            guard !edge.id.isEmpty else { throw WikiPreviewError("Canvas edge IDs cannot be empty.") }
            guard nodeIDs.contains(edge.fromNode), nodeIDs.contains(edge.toNode) else {
                throw WikiPreviewError("Canvas edge '\(edge.id)' points to a missing node.")
            }
        }
    }
}

public struct WikiCanvasNode: Encodable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, file, link, group }

    public let id: String
    public let type: Kind
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let text: String?
    public let file: String?
    public let filePath: DocumentPath?
    public let subpath: String?
    public let url: String?
    public let label: String?
    public let background: String?
    public let backgroundStyle: String?
    public let color: String?
}

extension WikiCanvasNode: Decodable {
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        type = try fields.decode(Kind.self, forKey: .type)
        x = try Double(fields.decode(Int.self, forKey: .x))
        y = try Double(fields.decode(Int.self, forKey: .y))
        width = try Double(fields.decode(Int.self, forKey: .width))
        height = try Double(fields.decode(Int.self, forKey: .height))
        guard !id.isEmpty else { throw WikiPreviewError("Canvas node IDs cannot be empty.") }
        guard width > 0, height > 0 else {
            throw WikiPreviewError("Canvas node '\(id)' must have positive width and height.")
        }
        color = try fields.decodeIfPresent(String.self, forKey: .color)
        text = type == .text ? try fields.decode(String.self, forKey: .text) : nil
        url = type == .link ? try fields.decode(String.self, forKey: .url) : nil
        label = type == .group ? try fields.decodeIfPresent(String.self, forKey: .label) : nil
        background = type == .group ? try fields.decodeIfPresent(String.self, forKey: .background) : nil
        backgroundStyle = type == .group ? try fields.decodeIfPresent(String.self, forKey: .backgroundStyle) : nil
        let project = try (decoder.userInfo[.canvasProject] as? DocumentPath) ?? DocumentPath("/")
        if let background { _ = try projectRelativePath(background, project: project) }
        if type == .file {
            let source = try fields.decode(String.self, forKey: .file)
            let fragment = try fields.decodeIfPresent(String.self, forKey: .subpath)
            guard fragment?.hasPrefix("#") != false else {
                throw WikiPreviewError("Canvas node '\(id)' subpath must start with '#'.")
            }
            file = source
            filePath = try projectRelativePath(source, project: project)
            subpath = fragment
        } else {
            file = nil
            filePath = nil
            subpath = nil
        }
    }
}

public struct WikiCanvasEdge: Codable, Sendable {
    public let id: String
    public let fromNode: String
    public let toNode: String
    public let fromSide: String?
    public let toSide: String?
    public let fromEnd: String?
    public let toEnd: String?
    public let color: String?
    public let label: String?
}

private extension CodingUserInfoKey {
    static let canvasProject = CodingUserInfoKey(rawValue: "canvasProject")!
}

func projectRelativePath(_ relative: String, project: DocumentPath) throws -> DocumentPath {
    let segments = relative.components(separatedBy: "/")
    guard relative == relative.trimmingCharacters(in: .whitespacesAndNewlines),
          relative.rangeOfCharacter(from: .controlCharacters) == nil,
          !relative.contains("\\"), !segments[0].contains(":"),
          segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw WikiPreviewError("Expected a project-relative path, found '\(relative)'.")
    }
    let prefix = project.rawValue == "/" ? "" : project.rawValue
    return try DocumentPath(prefix + "/" + relative)
}
