import Foundation

/// An occurrence has one primary row. Secondary rows map target IDs or unresolved names to that row.
struct MarkdownCitation: Codable, Sendable {
    let sourceID: DocumentID
    let sourcePath: DocumentPath
    let sourceVersion: UInt64
    let link: MarkdownLink
    var targetID: DocumentID?
    var status: DocumentLinkStatus
    var candidates: [DocumentID] = []

    var destination: MarkdownDestination { MarkdownDestination(link, relativeTo: sourcePath) }
    var key: String { MetaBrainKeyspace.citationOutPrefix(sourceID) + String(link.start) }

    func occurrence(
        targetPath: DocumentPath?,
        status: DocumentLinkStatus,
        candidates: [DocumentLinkCandidate]
    ) -> DocumentLinkOccurrence {
        let destination = destination
        return DocumentLinkOccurrence(
            sourceID: sourceID,
            sourcePath: sourcePath,
            sourceVersion: sourceVersion,
            start: link.start,
            end: link.end,
            snippet: link.snippet,
            label: link.label,
            destination: link.destination,
            syntax: link.syntax,
            embed: link.embed,
            sourceBlock: link.sourceBlock,
            fragment: destination.fragment,
            targetID: targetPath == nil ? nil : targetID,
            targetPath: targetPath,
            status: status,
            candidates: candidates
        )
    }

    var secondaryKeys: [String] {
        let suffix = sourceID.rawValue + "/" + String(link.start)
        if let targetID {
            return status == .resolved ? [MetaBrainKeyspace.citationInPrefix(targetID) + suffix] : []
        }
        return destination.lookupKeys.map { MetaBrainKeyspace.citationPendingPrefix($0) + suffix }
    }
}

struct MarkdownDestination {
    let rawTarget: String
    let fragment: String?
    let isExternal: Bool
    let paths: [DocumentPath]
    let name: String?

    var lookupKeys: [String] {
        paths.map { "path:" + $0.rawValue } + (name.map { ["name:" + $0] } ?? [])
    }

    var isSelfLink: Bool { !isExternal && rawTarget.isEmpty && fragment != nil }

    init(_ link: MarkdownLink, relativeTo source: DocumentPath) {
        let parts = Self.split(link.destination)
        rawTarget = Self.decode(parts.path)
        fragment = parts.fragment.map(Self.decode)
        isExternal = Self.isExternal(parts.path)
        if isExternal || rawTarget.isEmpty {
            paths = []
            name = nil
            return
        }

        let parent = source.parent?.rawValue ?? "/"
        let relative = rawTarget.hasPrefix("/") ? rawTarget : parent + "/" + rawTarget
        var local: [DocumentPath] = []
        if let exact = try? DocumentPath(relative) {
            local.append(exact)
            if exact.name.pathExtension.isEmpty, let markdown = try? DocumentPath(relative + ".md") {
                local.append(markdown)
            }
        }
        let hasDirectories = rawTarget.contains("/")
        if link.syntax == .wiki, hasDirectories, !rawTarget.hasPrefix("/"), !rawTarget.hasPrefix("./"),
           !rawTarget.hasPrefix("../"), let root = try? DocumentPath(rawTarget), !local.contains(root) {
            local.append(root)
            if root.name.pathExtension.isEmpty, let markdown = try? DocumentPath(rawTarget + ".md") {
                local.append(markdown)
            }
        }
        paths = local
        name = link.syntax == .wiki && !hasDirectories ? Self.wikiName(rawTarget) : nil
    }

    static func wikiName(_ name: String) -> String {
        if name.lowercased().hasSuffix(".md") { return String(name.dropLast(3)) }
        return name
    }

    static func pendingPrefixes(changedBy path: DocumentPath) -> [String] {
        ["path:" + path.rawValue, "name:" + wikiName(path.name)].map(MetaBrainKeyspace.citationPendingPrefix)
    }

    private static func split(_ value: String) -> (path: String, fragment: String?) {
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "#", !escaped {
                return (String(value[..<index]), String(value[value.index(after: index)...]))
            }
            escaped = character == "\\" && !escaped
        }
        return (value, nil)
    }

    private static func decode(_ value: String) -> String {
        let unescaped = value.replacingOccurrences(of: #"\\([[:punct:]])"#, with: "$1", options: .regularExpression)
        return unescaped.removingPercentEncoding ?? unescaped
    }

    private static func isExternal(_ value: String) -> Bool {
        if value.hasPrefix("//") { return true }
        guard let colon = value.firstIndex(of: ":"), colon != value.startIndex else { return false }
        let scheme = value[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }
}

private extension String {
    var pathExtension: String { (self as NSString).pathExtension }
}

struct MarkdownCitationHeader: Sendable {
    let id: DocumentID
    let path: DocumentPath
}

struct MarkdownCitationCatalog: Sendable {
    private var paths: [DocumentPath: DocumentID] = [:]
    private var names: [String: Set<DocumentID>] = [:]

    init(_ headers: [MarkdownCitationHeader]) {
        for header in headers {
            paths[header.path] = header.id
            let prefix = MetaBrainKeyspace.citationNamePrefix(MarkdownDestination.wikiName(header.path.name))
            names[prefix, default: []].insert(header.id)
        }
    }

    func id(for path: DocumentPath) -> DocumentID? { paths[path] }

    func ids(named name: String) -> Set<DocumentID> { names[MetaBrainKeyspace.citationNamePrefix(name)] ?? [] }
}

struct MarkdownCitationEdit: Sendable {
    var removals: Set<String> = []
    var puts: [String: Data] = [:]

    mutating func remove(_ key: String) {
        puts.removeValue(forKey: key)
        removals.insert(key)
    }

    mutating func put(_ value: Data = Data(), for key: String) {
        removals.remove(key)
        puts[key] = value
    }

    mutating func remove(_ citation: MarkdownCitation) {
        remove(citation.key)
        for key in citation.secondaryKeys { remove(key) }
    }
}
