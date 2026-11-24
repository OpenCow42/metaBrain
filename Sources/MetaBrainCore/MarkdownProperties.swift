import Foundation
import Yams

/// Search projections from a Markdown note's initial YAML mapping. Keep the
/// source body and explicit document fields separate for lossless edits.
enum MarkdownProperties {
    static func filterKeys(for document: StoredDocument) -> Set<String> {
        let properties = project(
            document.body, isMarkdown: document.isMarkdown, tags: document.tags, metadata: document.metadata
        )
        var keys = Set(properties.tags.map { MetaBrainKeyspace.tag($0, id: document.id) })
        for (key, value) in properties.values {
            keys.insert(MetaBrainKeyspace.metadata(key: key, value: value, id: document.id))
        }
        return keys
    }

    static func project(
        _ body: String, isMarkdown: Bool, tags: [String], metadata: [String: String]
    ) -> (tags: [String], values: [(key: String, value: String)]) {
        var allTags = tags
        var properties = metadata.map { (key: $0.key, value: $0.value) }
        guard isMarkdown, let yaml = frontmatter(in: body),
              let mapping = (try? compose(yaml: String(yaml)))?.mapping else {
            return (allTags, properties)
        }

        let explicitKeys = Set(metadata.keys.map { $0.lowercased() })
        for (key, node) in mapping {
            guard let name = key.scalar?.string, !name.isEmpty else { continue }
            let property = name.lowercased()
            let values = node.sequence?.compactMap { $0.scalar?.string } ?? [node.scalar?.string].compactMap { $0 }
            if property == "tags" {
                allTags.append(contentsOf: values.filter { !$0.isEmpty })
            } else if !explicitKeys.contains(property) {
                properties.append(contentsOf: values.map { (key: name, value: $0) })
            }
        }
        return (allTags, properties)
    }

    private static func frontmatter(in body: String) -> Substring? {
        guard body.hasPrefix("---"), let newline = body.firstIndex(where: \.isNewline),
              body[..<newline] == "---" else { return nil }
        let start = body.index(after: newline)
        var lineStart = start
        while lineStart < body.endIndex {
            let end = body[lineStart...].firstIndex(where: \.isNewline) ?? body.endIndex
            let line = body[lineStart..<end]
            if line == "---" || line == "..." { return body[start..<lineStart] }
            guard end < body.endIndex else { break }
            lineStart = body.index(after: end)
        }
        return nil
    }
}
