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

    var bindableTarget: Data? {
        guard !isExternal, !rawTarget.isEmpty else { return nil }
        return Data(rawTarget.utf8)
    }

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

/// Preserves surviving occurrences across source edits while leaving newly authored links to resolve afresh.
enum MarkdownCitationBindings {
    private struct Target: Hashable {
        let syntax: DocumentLinkSyntax
        let rawTarget: Data
    }

    private struct Signature: Hashable {
        var destination: Data? = nil
        var label: Data? = nil
        let embed: Bool
        var sourceBlock: String? = nil
    }

    static func preserve(from previous: [MarkdownCitation], in next: inout [MarkdownCitation]) {
        guard !previous.isEmpty, !next.isEmpty else { return }
        let oldTargets = groups(in: previous)
        for (target, newOffsets) in groups(in: next) {
            guard let oldOffsets = oldTargets[target] else { continue }
            let pairs = if oldOffsets.count == 1, newOffsets.count == 1 {
                [(oldOffsets[0], newOffsets[0])]
            } else {
                match(previous, oldOffsets, next, newOffsets)
            }
            for (old, new) in pairs {
                guard let targetID = previous[old].targetID else { continue }
                next[new].targetID = targetID
                next[new].status = previous[old].status
            }
        }
    }

    private static func groups(in citations: [MarkdownCitation]) -> [Target: [Int]] {
        var groups: [Target: [Int]] = [:]
        for index in citations.indices.sorted(by: { citations[$0].link.start < citations[$1].link.start }) {
            let citation = citations[index]
            if let rawTarget = citation.destination.bindableTarget {
                groups[Target(syntax: citation.link.syntax, rawTarget: rawTarget), default: []].append(index)
            }
        }
        return groups
    }

    private static func match(
        _ previous: [MarkdownCitation], _ oldOffsets: [Int],
        _ next: [MarkdownCitation], _ newOffsets: [Int]
    ) -> [(Int, Int)] {
        var usedOld: Set<Int> = []
        var usedNew: Set<Int> = []
        var pairs: [(Int, Int)] = []

        func pair<Key: Hashable>(by signature: (MarkdownLink) -> Key?) {
            var queues: [Key: [Int]] = [:]
            var consumed: [Key: Int] = [:]
            for old in oldOffsets where !usedOld.contains(old) {
                if let key = signature(previous[old].link) { queues[key, default: []].append(old) }
            }
            for new in newOffsets where !usedNew.contains(new) {
                guard let key = signature(next[new].link), let matching = queues[key] else { continue }
                let index = consumed[key, default: 0]
                guard index < matching.count else { continue }
                let old = matching[index]
                consumed[key] = index + 1
                usedOld.insert(old)
                usedNew.insert(new)
                pairs.append((old, new))
            }
        }

        // Named source blocks can distinguish repeated text even after a source is reordered.
        pair { link -> Signature? in
            guard let block = link.sourceBlock else { return nil }
            return Signature(destination: Data(link.destination.utf8), label: link.label.map { Data($0.utf8) },
                             embed: link.embed == true, sourceBlock: block)
        }
        pair { link in
            Signature(destination: Data(link.destination.utf8), label: link.label.map { Data($0.utf8) }, embed: link.embed == true)
        }
        pair { link -> Signature? in
            guard let label = link.label else { return nil }
            return Signature(label: Data(label.utf8), embed: link.embed == true)
        }
        pair { link in Signature(destination: Data(link.destination.utf8), embed: link.embed == true) }
        pair { $0.start }

        // Indistinguishable or fully edited repeats pair in body order. Each prior edge is consumed once.
        pairs.append(contentsOf: zip(oldOffsets.filter { !usedOld.contains($0) }, newOffsets.filter { !usedNew.contains($0) }))
        return pairs
    }
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
