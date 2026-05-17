import Foundation
import PropertyBased
@testable import MetaBrainCore
import Testing

@Suite("MetaBrainCoreFuzzTests")
struct MetaBrainCoreFuzzTests {
    @Test func documentPathNormalizationProperties() async throws {
        try await runGeneratedCases(pathSegmentsGenerator, defaultCount: 160, seed: Seed.path) { segments in
            let canonical = "/" + segments.joined(separator: "/")
            let expected = segments.isEmpty ? "/" : canonical
            var variants = [
                expected,
                " \(expected)// ",
                expected.replacingOccurrences(of: "/", with: "\\")
            ]

            if !segments.isEmpty {
                variants.append(segments.joined(separator: "/"))
                variants.append("/./" + segments.joined(separator: "/./"))
            }

            for rawPath in variants {
                #expect(try DocumentPath.normalized(rawPath) == expected)
                #expect(try DocumentPath.normalized(try DocumentPath.normalized(rawPath)) == expected)
            }

            let path = try DocumentPath(expected)
            if expected == "/" {
                #expect(path.parent == nil)
                #expect(path.name == "/")
            } else {
                let parent = try #require(path.parent)
                #expect(expected.hasPrefix(parent.rawValue == "/" ? "/" : "\(parent.rawValue)/"))
                #expect(path.name == segments.last)
            }
        }

        await runGeneratedCases(invalidPathGenerator, defaultCount: 80, seed: Seed.invalidPath) { rawPath in
            #expect(throws: MetaBrainDomainError.invalidDocumentPath(rawPath)) {
                try DocumentPath.normalized(rawPath)
            }
        }
    }

    @Test func documentIDNormalizationAndRejectionProperties() async throws {
        try await runGeneratedCases(documentIDGenerator, defaultCount: 160, seed: Seed.documentID) { rawID in
            let uppercased = rawID.uppercased()
            let normalized = try DocumentID(rawValue: uppercased)

            #expect(normalized.rawValue == rawID.lowercased())
            #expect(normalized.rawValue.unicodeScalars.allSatisfy(Self.isDocumentIDScalar))
            #expect(try DocumentID(rawValue: normalized.rawValue) == normalized)
        }

        await runGeneratedCases(invalidDocumentIDGenerator, defaultCount: 80, seed: Seed.invalidDocumentID) { rawID in
            #expect(throws: MetaBrainDomainError.invalidDocumentID(rawID)) {
                try DocumentID(rawValue: rawID)
            }
        }
    }

    @Test func generatedUnifiedDiffsMatchSimpleModel() async throws {
        try await runGeneratedCases(patchCaseGenerator, defaultCount: 140, seed: Seed.patch) { patchCase in
            let actual = try UnifiedTextPatch(patchCase.diff).applying(to: patchCase.original)

            #expect(actual == patchCase.expected)
        }
    }

    @Test func malformedUnifiedDiffFuzzingRejectsOrAppliesSafely() async throws {
        await runGeneratedCases(malformedPatchGenerator, defaultCount: 180, seed: Seed.malformedPatch) { text in
            do {
                _ = try UnifiedTextPatch(text).applying(to: "alpha\nbeta\ngamma\n")
            } catch let error as MetaBrainPatchError {
                #expect(!error.description.isEmpty)
            } catch {
                Issue.record("Unexpected non-MetaBrainPatchError: \(error)")
            }
        }
    }

    @Test func generatedCodableModelsRoundTripThroughJSON() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        try await runGeneratedCases(codablePayloadGenerator, defaultCount: 120, seed: Seed.codable) { payload in
            let encoded = try encoder.encode(payload)
            let decoded = try decoder.decode(CodablePayload.self, from: encoded)

            #expect(decoded == payload)
        }
    }

    @Test func generatedStoreTracesPreserveModelInvariants() async throws {
        let traceCount = min(max(fuzzCaseCount(defaultCount: 20) / 20, 4), 50)

        try await runGeneratedCases(storeTraceGenerator, count: traceCount, seed: Seed.store) { trace in
            try await withTemporaryFuzzStore { fixture in
                let store = try MetaBrainStore(url: fixture.storeURL)
                var model = StoreModel()

                for operation in trace.operations {
                    try await apply(operation, to: store, model: &model)
                    try await assertStore(store, matches: model)
                }
            }
        }
    }

    private static func isDocumentIDScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar == "-" || scalar == "_" ||
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }
}

private enum Seed {
    static let path: (UInt64, UInt64, UInt64, UInt64) = (0x01, 0x20, 0x30, 0x40)
    static let invalidPath: (UInt64, UInt64, UInt64, UInt64) = (0x02, 0x20, 0x30, 0x40)
    static let documentID: (UInt64, UInt64, UInt64, UInt64) = (0x03, 0x20, 0x30, 0x40)
    static let invalidDocumentID: (UInt64, UInt64, UInt64, UInt64) = (0x04, 0x20, 0x30, 0x40)
    static let patch: (UInt64, UInt64, UInt64, UInt64) = (0x05, 0x20, 0x30, 0x40)
    static let malformedPatch: (UInt64, UInt64, UInt64, UInt64) = (0x06, 0x20, 0x30, 0x40)
    static let codable: (UInt64, UInt64, UInt64, UInt64) = (0x07, 0x20, 0x30, 0x40)
    static let store: (UInt64, UInt64, UInt64, UInt64) = (0x08, 0x20, 0x30, 0x40)
}

private func fuzzCaseCount(defaultCount: Int) -> Int {
    guard let rawValue = ProcessInfo.processInfo.environment["METABRAIN_FUZZ_COUNT"],
          let parsed = Int(rawValue),
          parsed > 0 else {
        return defaultCount
    }

    return parsed
}

private func runGeneratedCases<Value>(
    _ generator: Generator<Value, some Sequence>,
    defaultCount: Int,
    seed: (UInt64, UInt64, UInt64, UInt64),
    perform body: (Value) async throws -> Void
) async rethrows {
    try await runGeneratedCases(
        generator,
        count: fuzzCaseCount(defaultCount: defaultCount),
        seed: seed,
        perform: body
    )
}

private func runGeneratedCases<Value>(
    _ generator: Generator<Value, some Sequence>,
    count: Int,
    seed: (UInt64, UInt64, UInt64, UInt64),
    perform body: (Value) async throws -> Void
) async rethrows {
    var rng = Xoshiro(seed: seed)

    for _ in 0..<count {
        let value = generator.run(using: &rng)
        try await body(value)
    }
}

private let safeSegmentCharacterGenerator = Gen<Character?>
    .element(of: Array("abcdefghijklmnopqrstuvwxyz0123456789-_") as [Character])
    .map { $0! }

private let pathSegmentsGenerator = safeSegmentCharacterGenerator
    .string(of: 1...10)
    .array(of: 0...5)
    .map { segments in
        segments.map { segment in
            if segment == "." || segment == ".." {
                return "segment"
            }
            return segment
        }
    }

private let controlCharacterPathGenerator = Gen<Int>
    .int(in: 0...31)
    .map { codepoint in
        let scalar = UnicodeScalar(codepoint)!
        return "/bad\(String(scalar))path"
    }
    .eraseToAnySequence()

private let invalidPathGenerator = Gen<String>.oneOf(
    controlCharacterPathGenerator,
    Gen.always("../outside").eraseToAnySequence(),
    Gen.always("").eraseToAnySequence()
)

private let documentIDGenerator = safeSegmentCharacterGenerator
    .string(of: 1...24)
    .map { id in
        let trimmed = id.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "doc-\(id.count)" : trimmed
    }

private let invalidDocumentIDGenerator = Gen<String>.oneOf(
    Gen.always("").eraseToAnySequence(),
    Gen.always("has/slash").eraseToAnySequence(),
    Gen.always("cafe\u{0301}").eraseToAnySequence(),
    Gen<Int>.int(in: 0...31)
        .map { codepoint in "bad\(String(UnicodeScalar(codepoint)!))id" }
        .eraseToAnySequence()
)

private struct GeneratedPatchCase: Sendable {
    var original: String
    var diff: String
    var expected: String
}

private let patchCaseGenerator = Generator<GeneratedPatchCase, Shrink.None<GeneratedPatchCase>>(
    run: { rng in
        let count = Int.random(in: 1...8, using: &rng)
        var lines = (0..<count).map { index in "line\(index)-\(Int.random(in: 0...999, using: &rng))" }
        let operation = Int.random(in: 0...2, using: &rng)
        let index = Int.random(in: 0..<lines.count, using: &rng)
        let replacement = "new\(Int.random(in: 0...999, using: &rng))"
        let original = lines.joined(separator: "\n") + "\n"
        let diff: String

        switch operation {
        case 0:
            diff = """
            @@ -\(index + 1),1 +\(index + 1),1 @@
            -\(lines[index])
            +\(replacement)
            """
            lines[index] = replacement

        case 1:
            diff = """
            @@ -\(index + 1),1 +\(index + 1),0 @@
            -\(lines[index])
            """
            lines.remove(at: index)

        default:
            let insertionIndex = Int.random(in: 0...lines.count, using: &rng)
            let oldStart = insertionIndex == 0 ? 0 : insertionIndex + 1
            diff = """
            @@ -\(oldStart),0 +\(insertionIndex + 1),1 @@
            +\(replacement)
            """
            lines.insert(replacement, at: insertionIndex)
        }

        return GeneratedPatchCase(
            original: original,
            diff: diff,
            expected: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        )
    },
    shrink: { _ in Shrink.None() }
)

private let asciiPatchGenerator = Gen<Character>.ascii
    .string(of: 0...220)
    .eraseToAnySequence()

private let malformedPatchGenerator = Gen<String>.oneOf(
    asciiPatchGenerator,
    Gen.always("GIT binary patch\nliteral 0\n").eraseToAnySequence(),
    Gen.always("@@ -x +1 @@\n-one\n+two\n").eraseToAnySequence()
)

private enum CodablePayload: Codable, Equatable, Sendable {
    case input(DocumentInput)
    case search(SearchQuery)
    case tree(TreeQuery)
    case dump(DocumentDumpQuery)
    case reference(DocumentReference)
    case retention(VersionRetentionPolicy)
    case prune(PruneRequest)
}

private let codablePayloadGenerator = Generator<CodablePayload, Shrink.None<CodablePayload>>(
    run: { rng in
        let path = generatedPath(slot: Int.random(in: 0...12, using: &rng))
        let body = generatedBody(slot: Int.random(in: 0...12, using: &rng))
        let id = try! DocumentID(rawValue: "doc-\(Int.random(in: 0...12, using: &rng))")

        switch Int.random(in: 0...6, using: &rng) {
        case 0:
            return .input(DocumentInput(
                path: path,
                title: "Title \(Int.random(in: 0...12, using: &rng))",
                body: body,
                tags: ["tag\(Int.random(in: 0...3, using: &rng))"],
                metadata: ["group": "g\(Int.random(in: 0...3, using: &rng))"],
                references: [.documentID(id), .path(path), .externalURL(URL(string: "https://example.com/\(id.rawValue)")!)],
                retention: .keepMostRecent(Int.random(in: 1...5, using: &rng))
            ))
        case 1:
            return .search(SearchQuery(
                text: "needle\(Int.random(in: 0...12, using: &rng))",
                pathPrefix: path,
                tags: ["tag\(Int.random(in: 0...3, using: &rng))"],
                metadata: ["group": "g\(Int.random(in: 0...3, using: &rng))"],
                includeLinkedDocuments: Bool.random(using: &rng),
                includeBacklinks: Bool.random(using: &rng),
                limit: Int.random(in: 0...20, using: &rng)
            ))
        case 2:
            return .tree(TreeQuery(
                path: path,
                directoriesOnly: Bool.random(using: &rng),
                maxDepth: Bool.random(using: &rng) ? Int.random(in: 0...4, using: &rng) : nil
            ))
        case 3:
            return .dump(DocumentDumpQuery(
                path: path,
                versionSelection: Bool.random(using: &rng) ? .current : .allRetained
            ))
        case 4:
            return .reference([DocumentReference.documentID(id), .path(path), .externalURL(URL(string: "https://example.com/ref")!)].randomElement(using: &rng)!)
        case 5:
            return .retention([
                VersionRetentionPolicy.keepAll,
                .keepMostRecent(Int.random(in: 0...6, using: &rng)),
                .keepWithin(TimeInterval(Int.random(in: 0...86_400, using: &rng)))
            ].randomElement(using: &rng)!)
        default:
            return .prune(PruneRequest(reference: .path(path), policy: .keepMostRecent(Int.random(in: 0...6, using: &rng))))
        }
    },
    shrink: { _ in Shrink.None() }
)

private enum StoreTraceOperation: Sendable {
    case put(slot: Int, bodySeed: Int)
    case rename(from: Int, to: Int, bodySeed: Int)
    case appendPatch(slot: Int, token: Int)
    case prune(slot: Int, keep: Int)
    case observe
}

private struct StoreTrace: Sendable {
    var operations: [StoreTraceOperation]
}

private let storeTraceGenerator = Generator<StoreTrace, Shrink.None<StoreTrace>>(
    run: { rng in
        let length = Int.random(in: 12...24, using: &rng)
        let operations = (0..<length).map { _ in
            switch Int.random(in: 0...4, using: &rng) {
            case 0:
                return StoreTraceOperation.put(
                    slot: Int.random(in: 0...7, using: &rng),
                    bodySeed: Int.random(in: 0...200, using: &rng)
                )
            case 1:
                return StoreTraceOperation.rename(
                    from: Int.random(in: 0...7, using: &rng),
                    to: Int.random(in: 0...7, using: &rng),
                    bodySeed: Int.random(in: 0...200, using: &rng)
                )
            case 2:
                return StoreTraceOperation.appendPatch(
                    slot: Int.random(in: 0...7, using: &rng),
                    token: Int.random(in: 0...200, using: &rng)
                )
            case 3:
                return StoreTraceOperation.prune(
                    slot: Int.random(in: 0...7, using: &rng),
                    keep: Int.random(in: 0...4, using: &rng)
                )
            default:
                return StoreTraceOperation.observe
            }
        }
        return StoreTrace(operations: operations)
    },
    shrink: { _ in Shrink.None() }
)

private struct FuzzStoreFixture: Sendable {
    var rootURL: URL
    var storeURL: URL
}

private func withTemporaryFuzzStore(
    _ body: (FuzzStoreFixture) async throws -> Void
) async throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("MetaBrainCoreFuzzTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fixture = FuzzStoreFixture(
        rootURL: rootURL,
        storeURL: rootURL.appendingPathComponent("store.leveldb", isDirectory: true)
    )

    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }

    try await body(fixture)
}

private struct ModelDocument: Equatable {
    var id: DocumentID
    var path: DocumentPath
    var body: String
    var tags: [String]
    var metadata: [String: String]
}

private struct StoreModel {
    var documents: [DocumentID: ModelDocument] = [:]
    var pathAliases: [DocumentPath: DocumentID] = [:]

    func document(atSlot slot: Int) -> ModelDocument? {
        pathAliases[generatedPath(slot: slot)].flatMap { documents[$0] }
    }

    mutating func upsert(_ document: StoredDocument) {
        if let old = documents[document.id] {
            pathAliases[old.path] = nil
        }

        documents[document.id] = ModelDocument(
            id: document.id,
            path: document.path,
            body: document.body,
            tags: document.tags,
            metadata: document.metadata
        )
        pathAliases[document.path] = document.id
    }
}

private func apply(
    _ operation: StoreTraceOperation,
    to store: MetaBrainStore,
    model: inout StoreModel
) async throws {
    switch operation {
    case .put(let slot, let bodySeed):
        let written = try await store.putDocument(DocumentInput(
            path: generatedPath(slot: slot),
            body: generatedBody(slot: bodySeed, slot: slot),
            tags: ["tag\(slot % 3)", "shared"],
            metadata: ["slot": "\(slot)", "group": "g\(slot % 2)"],
            retention: .keepMostRecent(5)
        ))
        model.upsert(written)

    case .rename(let sourceSlot, let destinationSlot, let bodySeed):
        guard let existing = model.document(atSlot: sourceSlot) else {
            return
        }

        let destinationPath = generatedPath(slot: destinationSlot)
        if let occupiedID = model.pathAliases[destinationPath], occupiedID != existing.id {
            return
        }

        let renamed = try await store.updateDocument(.documentID(existing.id), with: DocumentInput(
            path: destinationPath,
            body: generatedBody(slot: bodySeed, slot: destinationSlot),
            tags: ["tag\(destinationSlot % 3)", "shared"],
            metadata: ["slot": "\(destinationSlot)", "group": "g\(destinationSlot % 2)"],
            retention: .keepMostRecent(5)
        ))
        model.upsert(renamed)

    case .appendPatch(let slot, let token):
        guard let existing = model.document(atSlot: slot) else {
            return
        }

        let appended = "patchneedle\(token)"
        let lineCount = existing.body.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        let diff = """
        @@ -\(lineCount + 1),0 +\(lineCount + 1),1 @@
        +\(appended)
        """
        let patched = try await store.patchDocument(DocumentPatchRequest(
            reference: .documentID(existing.id),
            unifiedDiff: diff,
            retention: .keepMostRecent(5)
        ))
        model.upsert(patched)

    case .prune(let slot, let keep):
        guard let existing = model.document(atSlot: slot) else {
            return
        }

        let result = try await store.prune(PruneRequest(
            reference: .documentID(existing.id),
            policy: .keepMostRecent(keep)
        ))
        #expect(result.retainedVersionCount >= 1)
        #expect(try await store.getDocument(.documentID(existing.id)) != nil)

    case .observe:
        break
    }
}

private func assertStore(
    _ store: MetaBrainStore,
    matches model: StoreModel
) async throws {
    let expectedDocuments = model.documents.values.sorted { $0.id < $1.id }

    for expected in expectedDocuments {
        let actual = try #require(try await store.getDocument(.documentID(expected.id)))
        #expect(actual.path == expected.path)
        #expect(actual.body == expected.body)
        #expect(actual.tags == expected.tags)
        #expect(actual.metadata == expected.metadata)
        #expect(try await store.getDocument(.path(expected.path))?.id == expected.id)
        #expect(!(try await store.listVersions(of: .documentID(expected.id))).isEmpty)

        let needleResults = try await store.search(SearchQuery(text: firstNeedle(in: expected.body), limit: 10))
        #expect(needleResults.contains { $0.documentID == expected.id })
    }

    let treeDocumentIDs = Set(
        try await store.listDirectory(recursive: true)
            .compactMap(\.documentID)
    )
    let dumpDocumentIDs = Set(
        try await store.dump(DocumentDumpQuery(path: try DocumentPath("/")))
            .map(\.documentID)
    )
    let expectedIDs = Set(expectedDocuments.map(\.id))

    #expect(treeDocumentIDs == expectedIDs)
    #expect(dumpDocumentIDs == expectedIDs)
}

private func generatedPath(slot: Int) -> DocumentPath {
    try! DocumentPath("/fuzz/group-\(slot % 3)/doc-\(slot)")
}

private func generatedBody(slot bodySeed: Int, slot: Int = 0) -> String {
    """
    needle\(slot) shared body\(bodySeed)
    group\(slot % 3) metabrain fuzz trace \(bodySeed)
    """
}

private func firstNeedle(in body: String) -> String {
    body.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .first { $0.hasPrefix("needle") || $0.hasPrefix("patchneedle") }
        .map(String.init) ?? "shared"
}
