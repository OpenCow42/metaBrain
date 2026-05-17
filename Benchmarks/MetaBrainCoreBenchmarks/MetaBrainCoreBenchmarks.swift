import Benchmark
import Foundation
import MetaBrainCore

let benchmarks: @Sendable () -> Void = {
    let configuration = Benchmark.Configuration(
        metrics: [.wallClock, .throughput],
        warmupIterations: 0,
        maxDuration: .seconds(1),
        maxIterations: 5
    )

    Benchmark("MetaBrainStore put small documents", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)

        for iteration in benchmark.scaledIterations {
            try await store.putDocument(DocumentInput(
                path: benchmarkPath("small", iteration),
                body: smallBody(iteration),
                tags: ["small", "tag\(iteration % 4)"],
                metadata: ["group": "g\(iteration % 3)"]
            ))
        }
    }

    Benchmark("MetaBrainStore put multi-chunk documents", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)

        for iteration in benchmark.scaledIterations {
            try await store.putDocument(DocumentInput(
                path: benchmarkPath("large", iteration),
                body: largeBody(iteration),
                tags: ["large", "tag\(iteration % 4)"],
                metadata: ["group": "g\(iteration % 3)"]
            ))
        }
    }

    Benchmark("MetaBrainStore put metadata and reference heavy documents", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)
        let targets = try await seedReferenceTargets(in: store, count: 12)

        for iteration in benchmark.scaledIterations {
            try await store.putDocument(DocumentInput(
                path: benchmarkPath("rich", iteration),
                body: "rich needle\(iteration) common reference body",
                tags: (0..<8).map { "tag\($0)" },
                metadata: Dictionary(uniqueKeysWithValues: (0..<8).map { ("key\($0)", "value\((iteration + $0) % 5)") }),
                references: targets.prefix(6).map { .documentID($0.id) }
            ))
        }
    }

    Benchmark("MetaBrainStore update existing large document", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/bench/update/large")
        let document = try await store.putDocument(DocumentInput(path: path, body: largeBody(0)))

        for iteration in benchmark.scaledIterations {
            try await store.updateDocument(.documentID(document.id), with: DocumentInput(
                path: path,
                body: largeBody(iteration + 1),
                tags: ["updated", "tag\(iteration % 4)"],
                metadata: ["iteration": "\(iteration)"],
                retention: .keepMostRecent(12)
            ))
        }
    }

    Benchmark("MetaBrainStore patch one line in large document", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/bench/patch/large")
        let document = try await store.putDocument(DocumentInput(path: path, body: largeBody(0)))
        var currentFirstLine = "needle0 large body line 0 alpha beta gamma"

        for iteration in benchmark.scaledIterations {
            let nextFirstLine = "needle0 large body line 0 patched \(iteration)"
            let diff = """
            @@ -1,1 +1,1 @@
            -\(currentFirstLine)
            +\(nextFirstLine)
            """
            try await store.patchDocument(DocumentPatchRequest(
                reference: .documentID(document.id),
                unifiedDiff: diff,
                retention: .keepMostRecent(12)
            ))
            currentFirstLine = nextFirstLine
        }
    }

    Benchmark("MetaBrainStore search seeded corpus", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)
        try await seedSearchCorpus(in: store, count: 120)
        let filteredPath = try DocumentPath("/bench/corpus/group-1")

        for iteration in benchmark.scaledIterations {
            blackHole(try await store.search(SearchQuery(text: "common", limit: 20)))
            blackHole(try await store.search(SearchQuery(text: "rare\(iteration % 120)", limit: 5)))
            blackHole(try await store.search(SearchQuery(
                text: "common",
                pathPrefix: filteredPath,
                tags: ["tag\(iteration % 4)"],
                metadata: ["group": "g1"],
                includeLinkedDocuments: true,
                includeBacklinks: true,
                limit: 20
            )))
        }
    }

    Benchmark("MetaBrainStore tree list and dump nested corpus", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)
        try await seedSearchCorpus(in: store, count: 120)
        let root = try DocumentPath("/bench/corpus")

        for _ in benchmark.scaledIterations {
            blackHole(try await store.listDirectory(path: root, recursive: true))
            blackHole(try await store.tree(TreeQuery(path: root, maxDepth: 3)))
            blackHole(try await store.dump(DocumentDumpQuery(path: root)))
        }
    }

    Benchmark("MetaBrainStore versions and prune long history", configuration: configuration) { benchmark in
        let fixture = try BenchmarkStoreFixture()
        defer { fixture.cleanUp() }
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/bench/history/doc")
        let created = try await store.putDocument(DocumentInput(path: path, body: "history v0", retention: .keepAll))
        for version in 1...40 {
            try await store.updateDocument(.documentID(created.id), with: DocumentInput(
                path: path,
                body: "history v\(version) common",
                retention: .keepAll
            ))
        }

        for _ in benchmark.scaledIterations {
            blackHole(try await store.listVersions(of: .documentID(created.id)))
            blackHole(try await store.prune(PruneRequest(reference: .documentID(created.id), policy: .keepMostRecent(20))))
        }
    }
}

private struct BenchmarkStoreFixture {
    let rootURL: URL
    let storeURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MetaBrainCoreBenchmarks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storeURL = rootURL.appendingPathComponent("store.leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func seedReferenceTargets(
    in store: MetaBrainStore,
    count: Int
) async throws -> [StoredDocument] {
    var documents: [StoredDocument] = []
    for index in 0..<count {
        let document = try await store.putDocument(DocumentInput(
            path: benchmarkPath("targets", index),
            body: "target needle\(index) common"
        ))
        documents.append(document)
    }
    return documents
}

private func seedSearchCorpus(
    in store: MetaBrainStore,
    count: Int
) async throws {
    let targets = try await seedReferenceTargets(in: store, count: 8)
    for index in 0..<count {
        try await store.putDocument(DocumentInput(
            path: try DocumentPath("/bench/corpus/group-\(index % 4)/doc-\(index)"),
            body: "\(smallBody(index))\n\(largeBody(index % 8))",
            tags: ["tag\(index % 4)", "common"],
            metadata: ["group": "g\(index % 4)", "bucket": "\(index % 12)"],
            references: [.documentID(targets[index % targets.count].id)]
        ))
    }
}

private func benchmarkPath(_ group: String, _ index: Int) -> DocumentPath {
    try! DocumentPath("/bench/\(group)/doc-\(index)")
}

private func smallBody(_ index: Int) -> String {
    "needle\(index) rare\(index) common small body alpha beta gamma"
}

private func largeBody(_ seed: Int) -> String {
    (0..<260)
        .map { "needle\(seed) large body line \($0) alpha beta gamma" }
        .joined(separator: "\n") + "\n"
}
