import Foundation
@testable import MetaBrainCore
import Testing

@Test func documentPathsNormalizeFilesystemLikeAliases() throws {
    #expect(try DocumentPath.normalized("notes/today") == "/notes/today")
    #expect(try DocumentPath.normalized(" /notes//./today/ ") == "/notes/today")
    #expect(try DocumentPath.normalized("/notes/archive/../today") == "/notes/today")
    #expect(try DocumentPath.normalized("\\notes\\today\\") == "/notes/today")
    #expect(try DocumentPath("/").parent == nil)
    #expect(try DocumentPath("/").name == "/")
    #expect(try DocumentPath("/notes").parent?.rawValue == "/")
    #expect(try DocumentPath("/notes/today").parent?.rawValue == "/notes")
    #expect(try DocumentPath("/notes/today").name == "today")
    #expect(try DocumentPath("/notes/today").description == "/notes/today")
    #expect(try DocumentPath("/") < DocumentPath("/notes"))
}

@Test func documentPathsRejectEmptyAndEscapingParentReferences() {
    #expect(throws: MetaBrainDomainError.invalidDocumentPath("")) {
        try DocumentPath.normalized("")
    }

    #expect(throws: MetaBrainDomainError.invalidDocumentPath("../outside")) {
        try DocumentPath.normalized("../outside")
    }

    #expect(throws: MetaBrainDomainError.invalidDocumentPath("/bad\u{0000}path")) {
        try DocumentPath.normalized("/bad\u{0000}path")
    }
}

@Test func documentIDsAreStableComparableAsciiValues() throws {
    let generated = DocumentID.generate()
    #expect(!generated.rawValue.isEmpty)
    #expect(generated.rawValue == generated.rawValue.lowercased())

    let id = try DocumentID(rawValue: "ABC-123_def")
    #expect(id.rawValue == "abc-123_def")
    #expect(id.description == "abc-123_def")
    #expect(try DocumentID(rawValue: "abc-000") < DocumentID(rawValue: "abc-001"))

    #expect(throws: MetaBrainDomainError.invalidDocumentID("")) {
        try DocumentID(rawValue: "")
    }

    #expect(throws: MetaBrainDomainError.invalidDocumentID("has/slash")) {
        try DocumentID(rawValue: "has/slash")
    }

    #expect(throws: MetaBrainDomainError.invalidDocumentID("cafe\u{0301}")) {
        try DocumentID(rawValue: "cafe\u{0301}")
    }
}

@Test func searchModelsExposeStableIdentities() throws {
    let id = try DocumentID(rawValue: "doc-1")
    let path = try DocumentPath("/notes/search")
    let result = SearchResult(
        documentID: id,
        path: path,
        chunkOrdinal: 7,
        snippet: "snippet",
        score: 42
    )
    let version = DocumentVersion(
        documentID: id,
        sequence: 3,
        snapshot: DocumentInput(path: path, body: "body"),
        createdAt: Date(timeIntervalSince1970: 0)
    )

    #expect(result.id == "doc-1:7")
    #expect(version.id == "doc-1:3")
}

@Test func retentionPolicyValuesModelDocumentVersionStrategies() {
    let policies: [VersionRetentionPolicy] = [
        .keepAll,
        .keepMostRecent(10),
        .keepWithin(86_400)
    ]

    #expect(policies.contains(.keepAll))
    #expect(policies.contains(.keepMostRecent(10)))
    #expect(policies.contains(.keepWithin(86_400)))
}

@Test func documentReferencesModelInternalPathAndExternalTargets() throws {
    let id = try DocumentID(rawValue: "doc-1")
    let path = try DocumentPath("/notes/linked")
    let url = try #require(URL(string: "https://example.com/reference"))

    let references: Set<DocumentReference> = [
        .documentID(id),
        .path(path),
        .externalURL(url)
    ]

    #expect(references.contains(.documentID(id)))
    #expect(references.contains(.path(path)))
    #expect(references.contains(.externalURL(url)))
}

@Test func keyspaceMatchesPlannedFamiliesAndBytewiseOrdering() throws {
    let id = try DocumentID(rawValue: "doc-a")
    let otherID = try DocumentID(rawValue: "doc-b")
    let path = try DocumentPath("/notes/today")

    #expect(MetaBrainKeyspace.document(id: id) == "doc/id/doc-a")
    #expect(MetaBrainKeyspace.documentPath(path) == "doc/path//notes/today")
    #expect(MetaBrainKeyspace.version(id: id, sequence: 7) == "ver/doc-a/00000000000000000007")
    #expect(MetaBrainKeyspace.currentChunk(id: id, ordinal: 3) == "chunk/current/doc-a/0000000003")
    #expect(MetaBrainKeyspace.term("Hello/World", id: id, ordinal: 2) == "idx/term/hello%2Fworld/doc-a/0000000002")
    #expect(MetaBrainKeyspace.tag("Swift Notes", id: id) == "idx/tag/swift%20notes/doc-a")
    #expect(MetaBrainKeyspace.metadata(key: "source/type", value: "Daily Note", id: id) == "idx/meta/source%2Ftype/daily%20note/doc-a")
    #expect(MetaBrainKeyspace.outboundReference(sourceID: id, targetID: otherID) == "idx/ref/out/doc-a/doc-b")
    #expect(MetaBrainKeyspace.inboundReference(targetID: otherID, sourceID: id) == "idx/ref/in/doc-b/doc-a")
    #expect(MetaBrainKeyspace.tree(parentPath: try DocumentPath("/notes"), name: "today") == "tree//notes/today")
    #expect(MetaBrainKeyspace.prefix(.documentID) == "doc/id/")

    let versionKeys = [10, 2, 1].map { MetaBrainKeyspace.version(id: id, sequence: UInt64($0)) }.sorted()
    #expect(versionKeys == [
        "ver/doc-a/00000000000000000001",
        "ver/doc-a/00000000000000000002",
        "ver/doc-a/00000000000000000010"
    ])

    let chunkKeys = [12, 1, 3].map { MetaBrainKeyspace.currentChunk(id: id, ordinal: UInt32($0)) }.sorted()
    #expect(chunkKeys == [
        "chunk/current/doc-a/0000000001",
        "chunk/current/doc-a/0000000003",
        "chunk/current/doc-a/0000000012"
    ])
}
