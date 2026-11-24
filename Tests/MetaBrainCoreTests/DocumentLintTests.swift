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
        let selfLinked = try await store.putDocument(DocumentInput(
            path: DocumentPath("/notes/self.md"), body: "# Intro\n\n[[#Intro]]\n"
        ))
        let plain = try await store.putDocument(DocumentInput(
            path: DocumentPath("/plain"), body: "Native reference.", references: [.documentID(native.id)]
        ))
        let outside = try await store.putDocument(DocumentInput(
            path: DocumentPath("/outside.md"), body: "[[/notes/cited.md#^missing]]"
        ))
        let scope = try DocumentPath("/notes")
        #expect(try await store.lint(DocumentLintQuery(path: scope)).findings.isEmpty)
        let report = try await store.lint(DocumentLintQuery(path: scope, includeOrphans: true))
        #expect(report.documentsChecked == 3)
        #expect(report.findings.map(\.kind) == [.orphan])
        #expect(report.findings.map(\.sourcePath) == [selfLinked.path.rawValue])
        #expect(report.findings.first?.start == nil)
        let wholeStore = try await store.lint()
        #expect(wholeStore.findings.map(\.sourcePath) == [outside.path.rawValue])
        #expect(wholeStore.findings.map(\.kind) == [.missingAnchor])
        #expect(try await store.lint(DocumentLintQuery(path: plain.path, includeOrphans: true)).documentsChecked == 0)
        #expect(try await store.lint(DocumentLintQuery(path: cited.path, includeOrphans: true)).findings.isEmpty)
        let missing = try DocumentPath("/note")
        await #expect(throws: MetaBrainStoreError.lintScopeNotFound(missing)) {
            try await store.lint(DocumentLintQuery(path: missing))
        }
    }
}

@Test func lintPreparesLegacyCitationsWithoutTrackingReadsOrChangingVersions() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try await MetaBrainStore.initialize(at: fixture.storeURL, empty: true)
        let source = try await store.putDocument(DocumentInput(path: DocumentPath("/source.md"), body: "[[Missing]]"))
        let reference = DocumentReference.documentID(source.id)
        let beforeMetadata = try await store.entryMetadata(for: reference)
        let beforeVersions = try await store.listVersions(of: reference)
        try await store.deleteRawValue(forKey: MetaBrainKeyspace.citationOutPrefix(source.id) + "0")
        try await store.writeRawValue(Data([1]), forKey: MetaBrainKeyspace.citationLayout)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        let report = try await reopened.lint()
        #expect(report.findings.map(\.kind) == [.missingTarget])
        #expect(try await reopened.rawValue(forKey: MetaBrainKeyspace.citationLayout) == Data([2]))
        #expect(try await reopened.entryMetadata(for: reference) == beforeMetadata)
        #expect(try await reopened.listVersions(of: reference) == beforeVersions)
    }
}
