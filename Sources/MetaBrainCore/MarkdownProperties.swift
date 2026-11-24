import Foundation
import Yams

/// Search projections from a Markdown note's initial YAML mapping. Keep the
/// source body and explicit document fields separate for lossless edits.
enum MarkdownProperties {
    static func filterKeys(for document: StoredDocument) -> Set<String> {
        var keys = Set(document.tags.map { MetaBrainKeyspace.tag($0, id: document.id) })
        for (key, value) in document.metadata {
            keys.insert(MetaBrainKeyspace.metadata(key: key, value: value, id: document.id))
        }
        guard document.isMarkdown, let yaml = frontmatter(in: document.body),
              let mapping = (try? compose(yaml: String(yaml)))?.mapping else {
            return keys
        }

        let explicitKeys = Set(document.metadata.keys.map { $0.lowercased() })
        for (key, node) in mapping {
            guard let name = key.scalar?.string, !name.isEmpty else { continue }
            let property = name.lowercased()
            let values = node.sequence?.compactMap { $0.scalar?.string } ?? [node.scalar?.string].compactMap { $0 }
            if property == "tags" {
                for tag in values where !tag.isEmpty {
                    keys.insert(MetaBrainKeyspace.tag(tag, id: document.id))
                }
            } else if !explicitKeys.contains(property) {
                for value in values {
                    keys.insert(MetaBrainKeyspace.metadata(key: name, value: value, id: document.id))
                }
            }
        }
        return keys
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
