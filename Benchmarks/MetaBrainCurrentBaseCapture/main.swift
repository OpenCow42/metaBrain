import Dispatch
import Foundation
import LevelDBTyped
import MetaBrainCore

@main
struct MetaBrainCurrentBaseCapture {
    static func main() async throws {
        let results = try await [
            putGetMixedFormatsScenario(),
            searchAndDumpScenario(),
            repeatedLocalEditsScenario(),
            versionsAndPruneScenario(),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func putGetMixedFormatsScenario() async throws -> ScenarioResult {
        try await runScenario(
            name: "put-get-large-markdown-json-jsonl",
            fixtureSummary: "20 large Markdown, 20 JSON object/array, and 20 JSONL stream documents"
        ) { store, recorder in
            var references: [DocumentReference] = []

            try await recorder.measure("put.largeMarkdown.20") {
                for index in 0..<20 {
                    let document = try await store.putDocument(DocumentInput(
                        path: try DocumentPath("/bench/markdown/doc-\(index)"),
                        title: "Markdown \(index)",
                        body: largeMarkdown(seed: index),
                        tags: ["markdown", "large"],
                        metadata: ["shape": "markdown", "bucket": "\(index % 5)"],
                        retention: .keepMostRecent(12)
                    ))
                    references.append(.documentID(document.id))
                }
            }

            try await recorder.measure("put.json.20") {
                for index in 0..<20 {
                    let document = try await store.putDocument(DocumentInput(
                        path: try DocumentPath("/bench/json/doc-\(index)"),
                        title: "JSON \(index)",
                        body: jsonDocument(seed: index),
                        tags: ["json", "structured"],
                        metadata: ["shape": "json", "bucket": "\(index % 5)"],
                        retention: .keepMostRecent(12)
                    ))
                    references.append(.documentID(document.id))
                }
            }

            try await recorder.measure("put.jsonl.20") {
                for index in 0..<20 {
                    let document = try await store.putDocument(DocumentInput(
                        path: try DocumentPath("/bench/jsonl/doc-\(index)"),
                        title: "JSONL \(index)",
                        body: jsonLines(seed: index, count: 450),
                        tags: ["jsonl", "stream"],
                        metadata: ["shape": "jsonl", "bucket": "\(index % 5)"],
                        retention: .keepMostRecent(12)
                    ))
                    references.append(.documentID(document.id))
                }
            }

            try await recorder.measure("get.allDocuments.noReadTracking") {
                for reference in references {
                    _ = try await store.getDocument(reference, trackingRead: false)
                }
            }

            return ScenarioShape(
                documentCount: references.count,
                operationCount: 120,
                bodyUTF8Bytes: 20 * largeMarkdown(seed: 0).utf8.count
                    + 20 * jsonDocument(seed: 0).utf8.count
                    + 20 * jsonLines(seed: 0, count: 450).utf8.count,
                retainedVersionCount: 60,
                notes: [
                    "Current base stores full v1 document/version snapshots and fixed 4000-character current chunks.",
                    "JSON and JSONL are stored as opaque bodies in v1; this scenario captures their baseline cost before format-aware chunking."
                ]
            )
        }
    }

    private static func searchAndDumpScenario() async throws -> ScenarioResult {
        try await runScenario(
            name: "search-dump-seeded-corpus",
            fixtureSummary: "160 mixed corpus documents with tags, metadata, and references"
        ) { store, recorder in
            let targets = try await seedTargets(in: store, count: 12)

            try await recorder.measure("seed.searchCorpus.160") {
                for index in 0..<160 {
                    try await store.putDocument(DocumentInput(
                        path: try DocumentPath("/bench/corpus/group-\(index % 8)/doc-\(index)"),
                        title: "Corpus \(index)",
                        body: corpusBody(seed: index),
                        tags: ["common", "tag\(index % 6)"],
                        metadata: ["group": "g\(index % 8)", "bucket": "\(index % 16)"],
                        references: [.documentID(targets[index % targets.count].id)],
                        retention: .keepMostRecent(8)
                    ))
                }
            }

            try await recorder.measure("search.commonRareFilteredLinked.90") {
                for iteration in 0..<30 {
                    _ = try await store.search(SearchQuery(text: "common", limit: 25))
                    _ = try await store.search(SearchQuery(text: "rare\(iteration % 160)", limit: 5))
                    _ = try await store.search(SearchQuery(
                        text: "common",
                        pathPrefix: try DocumentPath("/bench/corpus/group-\(iteration % 8)"),
                        tags: ["tag\(iteration % 6)"],
                        metadata: ["group": "g\(iteration % 8)"],
                        includeLinkedDocuments: true,
                        includeBacklinks: true,
                        limit: 25
                    ))
                }
            }

            try await recorder.measure("dump.current.root") {
                _ = try await store.dump(DocumentDumpQuery(path: try DocumentPath("/bench/corpus")))
            }

            try await recorder.measure("dump.allRetained.root") {
                _ = try await store.dump(DocumentDumpQuery(
                    path: try DocumentPath("/bench/corpus"),
                    versionSelection: .allRetained
                ))
            }

            return ScenarioShape(
                documentCount: 172,
                operationCount: 253,
                bodyUTF8Bytes: 160 * corpusBody(seed: 0).utf8.count
                    + 12 * targetBody(seed: 0).utf8.count,
                retainedVersionCount: 172,
                notes: [
                    "Search covers common terms, rare terms, tag/metadata filters, context assembly, linked documents, and backlinks.",
                    "Dump covers current and all-retained history export paths."
                ]
            )
        }
    }

    private static func repeatedLocalEditsScenario() async throws -> ScenarioResult {
        try await runScenario(
            name: "repeated-local-edits-large-markdown",
            fixtureSummary: "one 100KB-class Markdown document patched 80 times at one line with keepAll"
        ) { store, recorder in
            let path = try DocumentPath("/bench/repeated/large-markdown")
            let created = try await recorder.measure("put.largeMarkdown.seed") {
                try await store.putDocument(DocumentInput(
                    path: path,
                    title: "Repeated Local Edits",
                    body: largeMarkdown(seed: 42),
                    tags: ["markdown", "patch"],
                    metadata: ["shape": "markdown"],
                    retention: .keepAll
                ))
            }

            var currentLine = "Localized edit target: version 0"
            try await recorder.measure("patch.sameLine.keepAll.80") {
                for version in 1...80 {
                    let nextLine = "Localized edit target: version \(version)"
                    let diff = """
                    @@ -10,1 +10,1 @@
                    -\(currentLine)
                    +\(nextLine)
                    """
                    try await store.patchDocument(DocumentPatchRequest(
                        reference: .documentID(created.id),
                        unifiedDiff: diff,
                        retention: .keepAll
                    ))
                    currentLine = nextLine
                }
            }

            try await recorder.measure("get.afterRepeatedEdits.noReadTracking.20") {
                for _ in 0..<20 {
                    _ = try await store.getDocument(.documentID(created.id), trackingRead: false)
                }
            }

            try await recorder.measure("versions.afterRepeatedEdits") {
                _ = try await store.listVersions(of: .documentID(created.id))
            }

            return ScenarioShape(
                documentCount: 1,
                operationCount: 102,
                bodyUTF8Bytes: largeMarkdown(seed: 42).utf8.count,
                retainedVersionCount: 81,
                notes: [
                    "This is the main current-base retained-history growth baseline for localized patches.",
                    "Current base rewrites a full document record, full version snapshot, and all current chunks/indexes on each patch."
                ]
            )
        }
    }

    private static func versionsAndPruneScenario() async throws -> ScenarioResult {
        try await runScenario(
            name: "versions-dump-prune-long-history-jsonl",
            fixtureSummary: "one JSONL document with 70 retained versions, history listing, dump all, and explicit prune"
        ) { store, recorder in
            let path = try DocumentPath("/bench/history/jsonl")
            let created = try await store.putDocument(DocumentInput(
                path: path,
                title: "History JSONL",
                body: jsonLines(seed: 700, count: 600),
                tags: ["jsonl", "history"],
                metadata: ["shape": "jsonl"],
                retention: .keepAll
            ))

            try await recorder.measure("update.jsonl.keepAll.70") {
                for version in 1...70 {
                    try await store.updateDocument(.documentID(created.id), with: DocumentInput(
                        path: path,
                        title: "History JSONL",
                        body: jsonLines(seed: 700 + version, count: 600),
                        tags: ["jsonl", "history"],
                        metadata: ["shape": "jsonl", "version": "\(version)"],
                        retention: .keepAll
                    ))
                }
            }

            try await recorder.measure("versions.longHistory") {
                _ = try await store.listVersions(of: .documentID(created.id))
            }

            try await recorder.measure("dump.allRetained.singleDocument") {
                _ = try await store.dump(DocumentDumpQuery(path: path, versionSelection: .allRetained))
            }

            try await recorder.measure("prune.keepMostRecent.20") {
                _ = try await store.prune(PruneRequest(
                    reference: .documentID(created.id),
                    policy: .keepMostRecent(20)
                ))
            }

            try await recorder.measure("versions.afterPrune") {
                _ = try await store.listVersions(of: .documentID(created.id))
            }

            return ScenarioShape(
                documentCount: 1,
                operationCount: 74,
                bodyUTF8Bytes: jsonLines(seed: 700, count: 600).utf8.count,
                retainedVersionCount: 20,
                notes: [
                    "Uses current public listVersions API as the v1 baseline for the Mark II history command.",
                    "Prune deletes full retained v1 version snapshots; no v2 manifests or chunks exist in this baseline."
                ]
            )
        }
    }

    private static func runScenario(
        name: String,
        fixtureSummary: String,
        _ body: (MetaBrainStore, OperationRecorder) async throws -> ScenarioShape
    ) async throws -> ScenarioResult {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }

        let before = StoreStats.empty(directoryBytes: directoryByteSize(fixture.storeURL))
        let store = try MetaBrainStore(url: fixture.storeURL)
        let recorder = OperationRecorder()
        let shape = try await body(store, recorder)
        await store.close()
        let after = try await storeStats(for: fixture.storeURL)

        return ScenarioResult(
            name: name,
            fixtureSummary: fixtureSummary,
            shape: shape,
            timingsMilliseconds: recorder.timings,
            storeBefore: before,
            storeAfter: after
        )
    }

    private static func storeStats(for storeURL: URL) async throws -> StoreStats {
        let records = try LevelDBStore(
            path: storeURL.path,
            keyCodec: StringCodec(),
            valueCodec: DataCodec(),
            options: LevelDBStoreOptions(createIfMissing: false)
        )

        var families: [String: KeyFamilyStats] = [:]
        var keyCount = 0
        var keyBytes = 0
        var valueBytes = 0

        for (key, value) in try await records.scan() {
            keyCount += 1
            keyBytes += key.utf8.count
            valueBytes += value.count
            let family = keyFamily(for: key)
            families[family, default: KeyFamilyStats()].record(keyBytes: key.utf8.count, valueBytes: value.count)
        }

        return StoreStats(
            directoryBytes: directoryByteSize(storeURL),
            keyCount: keyCount,
            keyBytes: keyBytes,
            valueBytes: valueBytes,
            families: families
        )
    }

    private static func keyFamily(for key: String) -> String {
        for prefix in keyFamilyPrefixes where key.hasPrefix(prefix) {
            return prefix
        }

        return "other"
    }

    private static let keyFamilyPrefixes = [
        "doc/id/",
        "doc/meta/",
        "doc/path/",
        "ver/",
        "chunk/current/",
        "idx/term/",
        "idx/tag/",
        "idx/meta/",
        "idx/ref/out/",
        "idx/ref/in/",
        "tree/",
    ]

    private static func directoryByteSize(_ url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }

            total += values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
        }

        return total
    }
}

private final class OperationRecorder {
    var timings: [String: Double] = [:]

    func measure<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await body()
        let end = DispatchTime.now().uptimeNanoseconds
        timings[name] = Double(end - start) / 1_000_000
        return result
    }
}

private struct CaptureFixture {
    let rootURL: URL
    let storeURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MetaBrainCurrentBaseCapture", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storeURL = rootURL.appendingPathComponent("store.leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct ScenarioResult: Codable {
    var name: String
    var fixtureSummary: String
    var shape: ScenarioShape
    var timingsMilliseconds: [String: Double]
    var storeBefore: StoreStats
    var storeAfter: StoreStats
}

private struct ScenarioShape: Codable {
    var documentCount: Int
    var operationCount: Int
    var bodyUTF8Bytes: Int
    var retainedVersionCount: Int
    var notes: [String]
}

private struct StoreStats: Codable {
    var directoryBytes: Int
    var keyCount: Int
    var keyBytes: Int
    var valueBytes: Int
    var families: [String: KeyFamilyStats]

    static func empty(directoryBytes: Int) -> StoreStats {
        StoreStats(
            directoryBytes: directoryBytes,
            keyCount: 0,
            keyBytes: 0,
            valueBytes: 0,
            families: [:]
        )
    }
}

private struct KeyFamilyStats: Codable {
    var keyCount: Int = 0
    var keyBytes: Int = 0
    var valueBytes: Int = 0

    mutating func record(keyBytes: Int, valueBytes: Int) {
        keyCount += 1
        self.keyBytes += keyBytes
        self.valueBytes += valueBytes
    }
}

private func seedTargets(in store: MetaBrainStore, count: Int) async throws -> [StoredDocument] {
    var documents: [StoredDocument] = []
    for index in 0..<count {
        let document = try await store.putDocument(DocumentInput(
            path: try DocumentPath("/bench/targets/doc-\(index)"),
            body: targetBody(seed: index),
            tags: ["target"],
            metadata: ["target": "\(index)"]
        ))
        documents.append(document)
    }
    return documents
}

private func targetBody(seed: Int) -> String {
    "target\(seed) common backlink anchor reference body\n"
}

private func corpusBody(seed: Int) -> String {
    let prefix = "common rare\(seed) corpus seed \(seed) alpha beta gamma\n"
    let body = (0..<120)
        .map { line in
            "common group\(seed % 8) line \(line) value \(seed * 31 + line) linked context"
        }
        .joined(separator: "\n")
    return prefix + body + "\n"
}

private func largeMarkdown(seed: Int) -> String {
    let frontMatter = """
    ---
    title: Large Markdown \(seed)
    tags: [benchmark, markdown]
    ---

    # Large Markdown \(seed)

    Intro paragraph with common terms and seed \(seed).

    Localized edit target: version 0

    """

    let sections = (0..<260).map { section in
        """
        ## Section \(section)

        Paragraph \(section) seed \(seed) common alpha beta gamma. This line is intentionally repetitive to create a large Markdown baseline document.

        - item \(section).1 common marker
        - item \(section).2 rare\(seed)-\(section)
        - item \(section).3 structured bullet

        > Quote \(section) keeps block quote coverage in the fixture.

        | key | value |
        | --- | --- |
        | section | \(section) |
        | seed | \(seed) |

        ~~~swift
        let benchmark\(section) = "seed-\(seed)-section-\(section)"
        print(benchmark\(section))
        ~~~

        """
    }.joined(separator: "\n")

    return frontMatter + sections
}

private func jsonDocument(seed: Int) -> String {
    let items = (0..<180).map { index in
        """
        {
          "id": "item-\(seed)-\(index)",
          "group": \(index % 12),
          "name": "common json item \(index)",
          "values": [\(index), \(seed), \(index * seed + 7)],
          "nested": {
            "flag": \(index % 2 == 0),
            "description": "dense nested value \(seed)-\(index) alpha beta gamma"
          }
        }
        """
    }.joined(separator: ",\n")

    return """
    {
      "kind": "benchmark-json",
      "seed": \(seed),
      "metadata": {
        "common": true,
        "shape": "object-with-array"
      },
      "items": [
    \(items)
      ]
    }
    """
}

private func jsonLines(seed: Int, count: Int) -> String {
    (0..<count)
        .map { index in
            """
            {"seed":\(seed),"line":\(index),"group":\(index % 16),"message":"common jsonl record \(seed)-\(index) alpha beta gamma"}
            """
        }
        .joined(separator: "\n") + "\n"
}
