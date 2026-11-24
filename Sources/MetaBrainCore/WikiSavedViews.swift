import Foundation
import Yams

extension WikiPreview {
    /// Compiles the supported subset of a YAML saved view before any rows can be evaluated.
    public static func base(body: String, project: DocumentPath) throws -> WikiSavedViews {
        guard let definition = try compose(yaml: body)?.mapping,
              let views = definition["views"]?.sequence else {
            throw WikiPreviewError("A saved view requires a YAML mapping with a views list.")
        }
        let filter = try definition["filters"].map { try BaseFilter($0, project: project) }
        let tables = try views.map { try BaseTable($0, project: project) }
        return WikiSavedViews(project: project, filter: filter, tables: tables)
    }
}

/// Source fields for a candidate row, as stored in the document.
public struct WikiPreviewDocument: Sendable {
    public let path: DocumentPath
    public let title: String?
    public let body: String
    public let tags: [String]
    public let metadata: [String: String]
    public let markdown: Bool?

    public init(
        path: DocumentPath, title: String? = nil, body: String, tags: [String] = [],
        metadata: [String: String] = [:], markdown: Bool? = nil
    ) {
        self.path = path
        self.title = title
        self.body = body
        self.tags = tags
        self.metadata = metadata
        self.markdown = markdown
    }
}

/// A validated, project-scoped collection of table definitions.
public struct WikiSavedViews: Sendable {
    fileprivate let project: DocumentPath
    fileprivate let filter: BaseFilter?
    fileprivate let tables: [BaseTable]

    /// Evaluates the definitions in source order against project descendants in path order.
    public func preview(documents: [WikiPreviewDocument]) -> [WikiTablePreview] {
        let candidates = documents
            .filter { isBelow($0.path, folder: project) }
            .sorted { $0.path < $1.path }
            .map { BaseRow($0, project: project) }
            .filter { filter?.matches($0) ?? true }
        return tables.map { table in
            let matches = candidates.lazy.filter { table.filter?.matches($0) ?? true }
            let rows = Array(matches.prefix(table.limit ?? Int.max).map { row in
                WikiTableRow(path: row.path, cells: table.columns.map { row.values($0)?.joined(separator: ", ") })
            })
            return WikiTablePreview(name: table.name, columns: table.columns, rows: rows)
        }
    }
}

public struct WikiTablePreview: Encodable, Sendable {
    public let name: String
    public let columns: [String]
    public let rows: [WikiTableRow]
}

public struct WikiTableRow: Encodable, Sendable {
    public let path: DocumentPath
    public let cells: [String?]
}

private struct BaseTable: Sendable {
    let name: String
    let columns: [String]
    let limit: Int?
    let filter: BaseFilter?

    init(_ node: Node, project: DocumentPath) throws {
        guard let view = node.mapping, view["type"]?.string == "table" else {
            throw WikiPreviewError("Only table views are supported.")
        }
        let name = view["name"]?.string ?? "Table"
        self.name = name
        if let order = view["order"] {
            guard let sequence = order.sequence else {
                throw WikiPreviewError("Table '\(name)' requires an order list of column names.")
            }
            columns = try sequence.map { column in
                guard let key = column.string, BaseProperty.supports(key) else {
                    throw WikiPreviewError("Table '\(name)' has an unsupported column: \(column).")
                }
                return key
            }
        } else {
            columns = ["file.name"]
        }
        if let count = view["limit"] {
            guard let parsed = count.int, parsed >= 0 else {
                throw WikiPreviewError("Table '\(name)' requires a nonnegative integer limit.")
            }
            limit = parsed
        } else {
            limit = nil
        }
        filter = try view["filters"].map { try BaseFilter($0, project: project) }
    }
}

private struct BaseRow {
    let path: DocumentPath
    let title: String?
    let relativePath: String
    let values: [String: [String]]
    let tags: Set<String>

    init(_ document: WikiPreviewDocument, project: DocumentPath) {
        path = document.path
        title = document.title
        let prefix = project.rawValue == "/" ? "/" : project.rawValue + "/"
        relativePath = String(decoding: path.rawValue.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        let properties = MarkdownProperties.project(
            document.body, isMarkdown: document.markdown == true || document.path.hasMarkdownExtension,
            tags: document.tags, metadata: document.metadata
        )
        var grouped: [String: [String]] = [:]
        for property in properties.values {
            grouped[property.key.lowercased(), default: []].append(property.value)
        }
        values = grouped
        tags = Set(properties.tags)
    }

    func values(_ property: String) -> [String]? {
        switch property {
        case "file.name": return [path.name]
        case "file.path": return [relativePath]
        case "file.folder": return [relativePath.lastIndex(of: "/").map { String(relativePath[..<$0]) } ?? ""]
        case "file.ext": return [(path.name as NSString).pathExtension]
        case "file.title": return title.map { [$0] }
        case "file.tags": return tags.sorted()
        default:
            let key = property.hasPrefix("note.") ? String(property.dropFirst("note.".count)) : property
            return values[key.lowercased()]
        }
    }
}

private enum BaseProperty {
    static let fileColumns: Set<String> = ["file.name", "file.path", "file.folder", "file.ext", "file.title", "file.tags"]

    static func supports(_ key: String) -> Bool {
        !key.isEmpty && key != "note." && (!key.hasPrefix("file.") || fileColumns.contains(key)) &&
            !key.hasPrefix("formula.") && !key.hasPrefix("this.")
    }
}

private indirect enum BaseFilter: Sendable {
    case and([BaseFilter])
    case or([BaseFilter])
    case not([BaseFilter])
    case folder(DocumentPath)
    case tag(String)
    case equal(String, String)

    init(_ node: Node, project: DocumentPath) throws {
        if let mapping = node.mapping, mapping.count == 1, let entry = mapping.first,
           let operation = entry.key.string, let parts = entry.value.sequence {
            let children = try parts.map { try Self($0, project: project) }
            switch operation {
            case "and": self = .and(children)
            case "or": self = .or(children)
            case "not": self = .not(children)
            default: throw WikiPreviewError("Unsupported saved view filter operator '\(operation)'.")
            }
            return
        }
        guard let expression = node.string else {
            throw WikiPreviewError("Unsupported saved view filter: \(node).")
        }
        self = try Self.expression(expression, project: project)
    }

    func matches(_ row: BaseRow) -> Bool {
        switch self {
        case .and(let children): return children.allSatisfy { $0.matches(row) }
        case .or(let children): return children.contains { $0.matches(row) }
        case .not(let children): return !children.contains { $0.matches(row) }
        case .folder(let folder): return isBelow(row.path, folder: folder)
        case .tag(let tag):
            return row.tags.contains { value in
                let name = Self.tagName(value)
                return name == tag || name.hasPrefix(tag + "/")
            }
        case .equal(let property, let value):
            return row.values(property)?.contains { $0.lowercased() == value } ?? false
        }
    }

    private static let quoted = #"(?:"[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*')"#
    private static let functionPattern = try! NSRegularExpression(
        pattern: #"\A\s*file\.(inFolder|hasTag)\s*\(\s*("# + quoted + #")\s*\)\s*\z"#
    )
    private static let comparisonPattern = try! NSRegularExpression(
        pattern: #"\A\s*([\p{L}_][\p{L}\p{N}_.-]*)\s*==\s*("# + quoted + #"|true|false|-?\d+(?:\.\d+)?)\s*\z"#
    )

    private static func expression(_ source: String, project: DocumentPath) throws -> Self {
        let range = NSRange(source.startIndex..., in: source)
        if let match = functionPattern.firstMatch(in: source, range: range) {
            let function = capture(1, match, in: source)
            let argument = try literal(capture(2, match, in: source), expression: source)
            if function == "inFolder" {
                if argument.isEmpty { return .folder(project) }
                return .folder(try projectRelativePath(argument, project: project))
            }
            let tag = tagName(argument)
            guard !tag.isEmpty else { throw WikiPreviewError("Expected a tag in filter '\(source)'.") }
            return .tag(tag)
        }
        if let match = comparisonPattern.firstMatch(in: source, range: range) {
            let property = capture(1, match, in: source)
            if BaseProperty.supports(property) {
                let value = try literal(capture(2, match, in: source), expression: source)
                return .equal(property, value.lowercased())
            }
        }
        throw WikiPreviewError("Unsupported saved view filter '\(source)'.")
    }

    private static func capture(_ index: Int, _ match: NSTextCheckingResult, in source: String) -> String {
        (source as NSString).substring(with: match.range(at: index))
    }

    private static func tagName(_ name: String) -> String {
        (name.hasPrefix("#") ? String(name.dropFirst()) : name).lowercased()
    }

    private static func literal(_ value: String, expression: String) throws -> String {
        let json: String
        if value.hasPrefix("'") {
            var characters = value.dropFirst().dropLast().makeIterator()
            var contents = ""
            while let character = characters.next() {
                switch character {
                case "\\":
                    let next = characters.next()!
                    contents += next == "'" ? "'" : "\\" + String(next)
                case "\"": contents += #"\""#
                default: contents.append(character)
                }
            }
            json = "\"" + contents + "\""
        } else if value.hasPrefix("\"") {
            json = value
        } else {
            return value
        }
        guard let decoded = try? JSONDecoder().decode(String.self, from: Data(json.utf8)) else {
            throw WikiPreviewError("Unsupported string literal in filter '\(expression)'.")
        }
        return decoded
    }
}

private func isBelow(_ path: DocumentPath, folder: DocumentPath) -> Bool {
    let prefix = folder.rawValue == "/" ? "/" : folder.rawValue + "/"
    return path != folder && path.rawValue.utf8.starts(with: prefix.utf8)
}
