import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func serverPutRequestDefaultsAndBuildsDocumentInput() throws {
    let decoded = try MetaBrainJSON.decoder().decode(
        ServerPutRequest.self,
        from: Data(#"{"path":"notes/today","body":"hello"}"#.utf8)
    )
    let input = try decoded.documentInput()

    #expect(decoded == ServerPutRequest(path: "notes/today", body: "hello"))
    #expect(input.path == (try DocumentPath("/notes/today")))
    #expect(input.body == "hello")
    #expect(input.title == nil)
    #expect(input.tags == [])
    #expect(input.metadata == [:])
    #expect(input.references == [])
    #expect(input.retention == nil)
}

@Test func serverPutRequestConvertsOptionalFields() throws {
    let request = ServerPutRequest(
        path: "/notes/today",
        body: "hello",
        title: "Today",
        tags: ["planning"],
        metadata: ["source": "agent"],
        references: [
            DocumentReferenceDTO(kind: .path, value: "/notes/source"),
            DocumentReferenceDTO(kind: .url, value: "https://example.com"),
        ],
        retention: DocumentRetentionPolicyDTO(kind: .keepLast, count: 2)
    )
    let input = try request.documentInput()

    #expect(input.title == "Today")
    #expect(input.tags == ["planning"])
    #expect(input.metadata == ["source": "agent"])
    #expect(input.references == [
        .path(try DocumentPath("/notes/source")),
        .externalURL(try #require(URL(string: "https://example.com"))),
    ])
    #expect(input.retention == .keepMostRecent(2))
}

@Test func serverGetRequestDefaultsTrackingRead() throws {
    let decoded = try MetaBrainJSON.decoder().decode(
        ServerGetRequest.self,
        from: Data(#"{"reference":{"kind":"path","value":"notes/today"}}"#.utf8)
    )
    let explicit = ServerGetRequest(
        reference: DocumentReferenceDTO(kind: .documentID, value: "abc123"),
        trackingRead: false
    )

    #expect(decoded.trackingRead)
    #expect(try decoded.documentReference() == .path(try DocumentPath("/notes/today")))
    #expect(!explicit.trackingRead)
    #expect(try explicit.documentReference() == .documentID(try DocumentID(rawValue: "abc123")))
}

@Test func serverPatchRequestDefaultsAndBuildsPatchRequest() throws {
    let decoded = try MetaBrainJSON.decoder().decode(
        ServerPatchRequest.self,
        from: Data(#"{"reference":{"kind":"path","value":"notes/today"},"unifiedDiff":"@@ -1 +1 @@\n-old\n+new\n"}"#.utf8)
    )
    let patch = try decoded.documentPatchRequest()

    #expect(!decoded.check)
    #expect(patch.reference == .path(try DocumentPath("/notes/today")))
    #expect(patch.unifiedDiff == "@@ -1 +1 @@\n-old\n+new\n")
    #expect(patch.retention == nil)
}

@Test func serverMutationRequestDTOsConvertOptionalFields() throws {
    let reference = DocumentReferenceDTO(kind: .path, value: "/notes/today")
    let retention = DocumentRetentionPolicyDTO(kind: .keepLast, count: 2)
    let patch = ServerPatchRequest(
        reference: reference,
        unifiedDiff: "@@ -1 +1 @@\n-old\n+new\n",
        check: true,
        retention: retention
    )
    let move = ServerMoveRequest(reference: reference, destinationPath: "/notes/archive/today")
    let prune = ServerPruneRequest(reference: reference, retention: retention)
    let delete = ServerDeleteRequest(reference: reference)
    let removeVersion = ServerRemoveVersionRequest(reference: reference, sequence: 1)

    #expect(try patch.documentPatchRequest().retention == .keepMostRecent(2))
    #expect(try move.documentReference() == .path(try DocumentPath("/notes/today")))
    #expect(try move.documentPath() == DocumentPath("/notes/archive/today"))
    #expect(try prune.pruneRequest() == PruneRequest(
        reference: .path(try DocumentPath("/notes/today")),
        policy: .keepMostRecent(2)
    ))
    #expect(try delete.documentReference() == .path(try DocumentPath("/notes/today")))
    #expect(try removeVersion.documentReference() == .path(try DocumentPath("/notes/today")))
    #expect(try removeVersion.validatedSequence() == 1)
}

@Test func serverReadRequestDTOsDefaultAndValidate() throws {
    let list = try MetaBrainJSON.decoder().decode(ServerListRequest.self, from: Data("{}".utf8))
    let tree = try MetaBrainJSON.decoder().decode(ServerTreeRequest.self, from: Data(#"{"maxDepth":0}"#.utf8))
    let search = try MetaBrainJSON.decoder().decode(ServerSearchRequest.self, from: Data(#"{"query":"hello"}"#.utf8))
    let versions = ServerVersionsRequest(reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"))
    let dump = try MetaBrainJSON.decoder().decode(ServerDumpRequest.self, from: Data("{}".utf8))

    #expect(list == ServerListRequest())
    #expect(try list.documentPath() == DocumentPath("/"))
    #expect(try tree.treeQuery() == TreeQuery(path: try DocumentPath("/"), directoriesOnly: false, maxDepth: 0))
    #expect(try search.searchQuery() == SearchQuery(text: "hello"))
    #expect(try versions.documentReference() == .path(try DocumentPath("/notes/today")))
    #expect(dump == ServerDumpRequest())
    #expect(try dump.dumpQuery() == DocumentDumpQuery(path: try DocumentPath("/")))
}

@Test func serverReadRequestDTOsConvertOptionalFields() throws {
    let list = ServerListRequest(path: "/notes", recursive: true, directoriesOnly: true)
    let tree = ServerTreeRequest(path: "/notes", directoriesOnly: true, maxDepth: 2)
    let search = ServerSearchRequest(
        query: "hello",
        pathPrefix: "/notes",
        tags: ["planning"],
        metadata: ["source": "agent"],
        includeLinkedDocuments: true,
        includeBacklinks: true,
        limit: 3
    )
    let dump = ServerDumpRequest(path: "/notes", versions: true)

    #expect(try list.documentPath() == DocumentPath("/notes"))
    #expect(try tree.treeQuery() == TreeQuery(path: try DocumentPath("/notes"), directoriesOnly: true, maxDepth: 2))
    #expect(try search.searchQuery() == SearchQuery(
        text: "hello",
        pathPrefix: try DocumentPath("/notes"),
        tags: ["planning"],
        metadata: ["source": "agent"],
        includeLinkedDocuments: true,
        includeBacklinks: true,
        limit: 3
    ))
    #expect(try dump.dumpQuery() == DocumentDumpQuery(
        path: try DocumentPath("/notes"),
        versionSelection: .allRetained
    ))
}

@Test func serverRequestDTOErrorsHaveStableDescriptions() {
    #expect(ServerRequestDTOError.invalidTreeMaxDepth(-1).description == "maxDepth must be zero or greater, got -1")
    #expect(ServerRequestDTOError.invalidSearchLimit(0).description == "limit must be greater than zero, got 0")
    #expect(ServerRequestDTOError.missingRetention.description == "retention is required")
    #expect(ServerRequestDTOError.invalidRemoveVersionSequence(0).description == "sequence must be greater than zero, got 0")
    #expect(
        ServerRequestDTOError.unsupportedDumpWithoutBodies.description
            == "includeBodies=false is not supported; dump responses use DumpOutput"
    )
}

@Test func serverReadRequestDTOsRejectInvalidValues() throws {
    #expect(throws: ServerRequestDTOError.invalidTreeMaxDepth(-1)) {
        _ = try ServerTreeRequest(maxDepth: -1).treeQuery()
    }
    #expect(throws: ServerRequestDTOError.invalidSearchLimit(0)) {
        _ = try ServerSearchRequest(query: "hello", limit: 0).searchQuery()
    }
    #expect(throws: MetaBrainDomainError.invalidDocumentPath("..")) {
        _ = try ServerListRequest(path: "..").documentPath()
    }
    #expect(throws: ServerRequestDTOError.unsupportedDumpWithoutBodies) {
        _ = try ServerDumpRequest(includeBodies: false).dumpQuery()
    }
    #expect(throws: ServerRequestDTOError.missingRetention) {
        _ = try ServerPruneRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/notes/today")
        ).pruneRequest()
    }
    #expect(throws: ServerRequestDTOError.invalidRemoveVersionSequence(0)) {
        _ = try ServerRemoveVersionRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"),
            sequence: 0
        ).validatedSequence()
    }
}
