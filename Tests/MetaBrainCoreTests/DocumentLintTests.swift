import Foundation
import Testing
@testable import MetaBrainCore

@Test func lintReportsEachBrokenCitationInSourceOrder() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: true)
        for path in ["/other/Shared.md", "/policy/Shared.md"] {
            _ = try await store.putDocument(DocumentInput(path: DocumentPath(path), body: "Shared."))
        }
        let policy = try await store.putDocument(DocumentInput(
            path: DocumentPath("/policy/Retention.md"),
            body: "# Exceptions\n\nFirst exception.\n\n# Exceptions\n\nSecond exception.\n"
        ))
        let body = "👩🏽‍💻 ![[Missing]] [[Missing]] [[Shared]] [[/policy/Retention.md#^keep]] "
            + "[[/policy/Retention.md#Exceptions]] [[/policy/Retention.md]] "
            + "[outside](https://example.test/#fragment) and `[[Literal]]`.\n"
        let source = try await store.putDocument(DocumentInput(
            path: DocumentPath("/decisions"), body: body, markdown: true
        ))
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/decisions/child.md"), body: "[[Absent]]"))
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/decisions/plain"), body: "[[Ignored]]"))
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/decisions-old/a.md"), body: "[[Ignored]]"))

        let report = try await store.lint(DocumentLintQuery(path: source.path))
        #expect(report.path == "/decisions")
        #expect(report.documentsChecked == 2)
        #expect(report.counts == [
            "missingTarget": 3, "ambiguousTarget": 1, "missingAnchor": 1, "ambiguousAnchor": 1, "orphan": 0
        ])
        #expect(report.findings.map(\.kind) == [
            .missingTarget, .missingTarget, .ambiguousTarget, .missingAnchor, .ambiguousAnchor, .missingTarget
        ])
        let sourceFindings = report.findings.filter { $0.sourcePath == "/decisions" }
        #expect(sourceFindings.allSatisfy { $0.sourceID == source.id.rawValue && $0.sourceVersion == source.currentVersion })
        let characters = Array(body)
        let locations = try sourceFindings.map { finding in
            let start = try #require(finding.start)
            let end = try #require(finding.end)
            return String(characters[start..<end])
        }
        #expect(locations == [
            "![[Missing]]", "[[Missing]]", "[[Shared]]", "[[/policy/Retention.md#^keep]]", "[[/policy/Retention.md#Exceptions]]"
        ])
        #expect(sourceFindings[0].start == 2)
        #expect(sourceFindings[2].candidatePaths == ["/other/Shared.md", "/policy/Shared.md"])
        #expect(sourceFindings[3].targetPath == policy.path.rawValue)
        #expect(sourceFindings[3].fragment == "^keep")
        #expect(sourceFindings[4].fragment == "Exceptions")

        _ = try await store.moveDocument(.documentID(policy.id), to: DocumentPath("/archive/Retention.md"))
        _ = try await store.putDocument(DocumentInput(path: policy.path, body: "Replacement. ^keep"))
        let moved = try await store.lint(DocumentLintQuery(path: source.path))
        #expect(moved.findings[3].targetPath == "/archive/Retention.md")
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/archive/Retention.md"), body: "Restored. ^keep"))
        let restored = try await store.lint(DocumentLintQuery(path: source.path))
        #expect(restored.counts["missingAnchor"] == 1) // Only the Exceptions heading is now missing.
        #expect(restored.findings.allSatisfy { $0.fragment != "^keep" })
        #expect(try await store.deleteDocument(.documentID(policy.id)))
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/archive/Retention.md"), body: "Another replacement. ^keep"))
        let deleted = try await store.lint(DocumentLintQuery(path: source.path))
        #expect(deleted.findings[3].kind == .missingTarget)
        #expect(deleted.findings[3].targetPath == nil)
    }
}

@Test func lintOrphansUseIncomingIndexesAcrossScopeAndIgnoreSelfLinks() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: true)
        #expect(try await store.lint().documentsChecked == 0)
        #expect(try await store.lint().findings.isEmpty)
        let native = try await store.putDocument(DocumentInput(path: DocumentPath("/notes/native.md"), body: "Native."))
        let cited = try await store.putDocument(DocumentInput(path: DocumentPath("/notes/cited.md"), body: "Cited."))
        let pathLinked = try await store.putDocument(DocumentInput(path: DocumentPath("/notes/path-linked.md"), body: "Path reference."))
        let selfLinked = try await store.putDocument(DocumentInput(
            path: DocumentPath("/notes/self.md"), body: "# Intro\n\n[[#Intro]]\n"
        ))
        let plain = try await store.putDocument(DocumentInput(
            path: DocumentPath("/plain"), body: "Native references.", references: [.documentID(native.id), .path(pathLinked.path)]
        ))
        let outside = try await store.putDocument(DocumentInput(
            path: DocumentPath("/outside.md"), body: "[[/notes/cited.md#^missing]]"
        ))
        let scope = try DocumentPath("/notes")
        #expect(try await store.lint(DocumentLintQuery(path: scope)).findings.isEmpty)
        let report = try await store.lint(DocumentLintQuery(path: scope, includeOrphans: true))
        #expect(report.documentsChecked == 4)
        #expect(report.findings.map(\.kind) == [.orphan])
        #expect(report.findings.map(\.sourcePath) == [selfLinked.path.rawValue])
        #expect(report.findings.first?.start == nil)
        let wholeStore = try await store.lint()
        #expect(wholeStore.findings.map(\.sourcePath) == [outside.path.rawValue])
        #expect(wholeStore.findings.map(\.kind) == [.missingAnchor])
        #expect(try await store.lint(DocumentLintQuery(path: plain.path, includeOrphans: true)).documentsChecked == 0)
        #expect(try await store.lint(DocumentLintQuery(path: cited.path, includeOrphans: true)).findings.isEmpty)
        #expect(try await store.deleteDocument(.documentID(plain.id)))
        #expect(try await store.deleteDocument(.documentID(outside.id)))
        let disconnected = try await store.lint(DocumentLintQuery(path: scope, includeOrphans: true))
        #expect(disconnected.findings.map(\.sourcePath) == [
            cited.path.rawValue, native.path.rawValue, pathLinked.path.rawValue, selfLinked.path.rawValue
        ])
        #expect(disconnected.findings.allSatisfy { $0.kind == .orphan })
        let missing = try DocumentPath("/note")
        await #expect(throws: MetaBrainStoreError.lintScopeNotFound(missing)) {
            try await store.lint(DocumentLintQuery(path: missing))
        }
    }
}

@Test(arguments: [false, true])
func lintPreparesLegacyCitationsWithoutTrackingReadsOrChangingVersions(hasOldLayout: Bool) async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: true)
        let source = try await store.putDocument(DocumentInput(path: DocumentPath("/source.md"), body: "[[Missing]]"))
        let reference = DocumentReference.documentID(source.id)
        let beforeMetadata = try await store.entryMetadata(for: reference)
        let beforeVersions = try await store.listVersions(of: reference)
        let key = MetaBrainKeyspace.citationOutPrefix(source.id) + "0"
        let citation = try #require(try await store.compressedRecord(forKey: key, as: MarkdownCitation.self))
        try await store.deleteRawValue(forKey: key)
        for secondaryKey in citation.secondaryKeys { try await store.deleteRawValue(forKey: secondaryKey) }
        if hasOldLayout {
            try await store.writeRawValue(Data([1]), forKey: MetaBrainKeyspace.citationLayout)
        } else {
            let nameKey = MetaBrainKeyspace.citationNamePrefix("source") + source.id.rawValue
            try await store.deleteRawValue(forKey: nameKey)
            try await store.deleteRawValue(forKey: MetaBrainKeyspace.citationPath(source.id))
            try await store.deleteRawValue(forKey: MetaBrainKeyspace.citationLayout)
        }
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let report = try await reopened.lint()
        #expect(report.findings.map(\.kind) == [.missingTarget])
        #expect(try await reopened.rawValue(forKey: MetaBrainKeyspace.citationPath(source.id)) == Data("/source.md".utf8))
        #expect(try await reopened.rawValue(forKey: MetaBrainKeyspace.citationLayout) == Data([2]))
        #expect(try await reopened.entryMetadata(for: reference) == beforeMetadata)
        #expect(try await reopened.listVersions(of: reference) == beforeVersions)
    }
}

@Test func lintScopesUseExactPathBytesAndIncludeTheRootDocument() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: true)
        let paths = ["/", "/Caf\u{00E9}/note.md", "/Cafe\u{0301}/note.md", "/caf\u{00E9}/note.md"]
        var ids: [String] = []
        for path in paths {
            let source = try await store.putDocument(DocumentInput(path: DocumentPath(path), body: "[[Missing]]", markdown: true))
            ids.append(source.id.rawValue)
        }

        let wholeStore = try await store.lint()
        #expect(wholeStore.documentsChecked == 4)
        #expect(wholeStore.findings.map(\.sourceID) == [ids[0], ids[2], ids[1], ids[3]])
        #expect(try await store.lint(DocumentLintQuery(path: DocumentPath("/"))) == wholeStore)

        let composed = try await store.lint(DocumentLintQuery(path: DocumentPath("/Caf\u{00E9}")))
        #expect(composed.documentsChecked == 1)
        #expect(composed.findings.map(\.sourceID) == [ids[1]])
        let decomposed = try await store.lint(DocumentLintQuery(path: DocumentPath("/Cafe\u{0301}")))
        #expect(decomposed.documentsChecked == 1)
        #expect(decomposed.findings.map(\.sourceID) == [ids[2]])
    }
}

@Test func lintKeepsScopeAndSourceRevisionConsistentDuringMoves() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: true)
        let scopedPath = try DocumentPath("/notes/moving.md")
        let outsidePath = try DocumentPath("/archive/moving.md")
        let source = try await store.putDocument(DocumentInput(path: scopedPath, body: "Read [[Missing]].", retention: .keepAll))
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/notes/stable.md"), body: "Stable."))
        let reference = DocumentReference.documentID(source.id)
        let query = DocumentLintQuery(path: try DocumentPath("/notes"))

        let initial = try await store.lint(query)
        try #require(initial.findings.count == 1)
        _ = try await store.moveDocument(reference, to: outsidePath)
        let archived = try await store.lint(query)
        #expect(archived.findings.isEmpty)
        async let moving: Void = {
            for move in 1...23 {
                _ = try await store.moveDocument(reference, to: move.isMultiple(of: 2) ? outsidePath : scopedPath)
                await Task.yield()
            }
        }()
        var reports = [initial, archived]
        for _ in 1...32 {
            reports.append(try await store.lint(query))
            await Task.yield()
        }
        try await moving
        let final = try await store.lint(query)
        #expect(final.findings.first?.sourceVersion == 25)
        reports.append(final)

        let versions = try await store.listVersions(of: reference)
        for report in reports {
            #expect(report.documentsChecked == report.findings.count + 1)
            #expect(report.findings.count <= 1)
            for finding in report.findings {
                #expect(finding.kind == .missingTarget)
                #expect(finding.sourceID == source.id.rawValue)
                #expect(finding.sourcePath == scopedPath.rawValue)
                let snapshot = try #require(versions.first { $0.sequence == finding.sourceVersion }?.snapshot)
                #expect(snapshot.path == scopedPath)
                #expect(finding.start == 5)
                #expect(finding.end == 16)
            }
        }
    }
}
