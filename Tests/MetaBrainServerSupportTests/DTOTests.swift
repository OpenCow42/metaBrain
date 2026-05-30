import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test func jsonEncoderMatchesCLICompatibilitySettings() throws {
    let output = VersionOutput(currentTag: "9.8.7", releaseCheck: nil)
    let encoded = try encode(output)

    #expect(encoded == #"{"currentTag":"9.8.7","releaseCheck":null,"server":null}"#)

    let decoded = try MetaBrainJSON.decoder().decode(VersionOutput.self, from: Data(encoded.utf8))
    #expect(decoded == output)
}

@Test func outputDTOsEncodeStableJSONShapes() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-05-24T12:34:56Z"))
    let documentID = try DocumentID(rawValue: "abc123")
    let document = StoredDocument(
        id: documentID,
        path: try DocumentPath("/notes/today"),
        title: "Today",
        body: "body",
        tags: ["planning"],
        metadata: ["source": "agent"],
        references: [.path(try DocumentPath("/notes/other"))],
        currentVersion: 2,
        createdAt: date,
        updatedAt: date
    )
    let treeEntry = DocumentTreeEntry(
        path: try DocumentPath("/notes/today"),
        name: "today",
        hasChildren: false,
        documentID: documentID,
        createdAt: date,
        updatedAt: date
    )
    let searchResult = SearchResult(
        documentID: documentID,
        path: try DocumentPath("/notes/today"),
        title: "Today",
        chunkOrdinal: 0,
        snippet: "body",
        score: 1.5,
        context: [SearchContextChunk(ordinal: 0, text: "body")],
        linkedDocuments: [.documentID(documentID)],
        backlinks: [.path(try DocumentPath("/notes/source"))]
    )
    let dumpEntry = DocumentDumpEntry(
        documentID: documentID,
        path: try DocumentPath("/notes/today"),
        title: nil,
        body: "body",
        version: 2,
        versionCreatedAt: date,
        isCurrent: true,
        tags: ["planning"],
        metadata: ["source": "agent"],
        references: [DocumentDumpReference(kind: .externalURL, value: "https://example.com")]
    )
    let version = DocumentVersion(
        documentID: documentID,
        sequence: 2,
        snapshot: DocumentInput(path: try DocumentPath("/notes/today"), body: "body"),
        createdAt: date
    )

    #expect(try encode(InitializeOutput(storePath: "/tmp/store.leveldb")) == #"{"operation":"init","status":"initialized","storePath":"/tmp/store.leveldb"}"#)
    #expect(try encode(PutOutput(documentID: "abc123", path: "/notes/today", status: "created", version: 1)) == #"{"documentID":"abc123","operation":"put","path":"/notes/today","status":"created","version":1}"#)
    #expect(try encode(PatchOutput(documentID: "abc123", path: "/notes/today", version: 2)) == #"{"documentID":"abc123","operation":"patch","path":"/notes/today","status":"patched","version":2}"#)
    #expect(try encode(PatchCheckOutput()) == #"{"check":true,"operation":"patch","status":"applies","success":true}"#)
    #expect(try encode(ServerPatchOutput.patch(PatchOutput(documentID: "abc123", path: "/notes/today", version: 2))) == #"{"documentID":"abc123","operation":"patch","path":"/notes/today","status":"patched","version":2}"#)
    #expect(try encode(ServerPatchOutput.check(PatchCheckOutput())) == #"{"check":true,"operation":"patch","status":"applies","success":true}"#)
    #expect(try encode(MoveOutput(documentID: "abc123", from: "/old", path: "/new", status: "moved", version: 2)) == #"{"documentID":"abc123","from":"/old","operation":"move","path":"/new","status":"moved","version":2}"#)
    #expect(try encode(PruneOutput(prunedVersionCount: 1, retainedVersionCount: 2)) == #"{"operation":"prune","prunedVersionCount":1,"retainedVersionCount":2,"status":"completed"}"#)
    #expect(try encode(DeleteOutput(reference: "/notes/today", deleted: true)) == #"{"deleted":true,"operation":"delete","reference":"/notes/today","status":"completed"}"#)
    #expect(try encode(RemoveVersionOutput(reference: "/notes/today", removed: true, sequence: 1)) == #"{"operation":"remove-version","reference":"/notes/today","removed":true,"sequence":1,"status":"completed"}"#)

    #expect(try encode(GetOutput(document)).contains(#""title":"Today""#))
    #expect(try encode(GetOutput(document)).contains(#""references":[{"kind":"path","value":"/notes/other"}]"#))
    #expect(try encode(ListOutput(treeEntry)).contains(#""documentID":"abc123""#))
    #expect(try encode(TreeOutput(root: try DocumentPath("/"), hasChildren: false)) == #"{"createdAt":null,"documentID":null,"hasChildren":false,"kind":"root","name":"/","path":"/","updatedAt":null}"#)
    #expect(try encode(TreeOutput(treeEntry)).contains(#""kind":"entry""#))
    #expect(try encode(SearchOutput(searchResult)).contains(#""linkedDocuments":[{"kind":"documentID","value":"abc123"}]"#))
    #expect(!((try encode(DumpOutput(dumpEntry))).contains("fileSystemPath")))
    #expect(!((try encode(DumpOutput(dumpEntry))).contains(#""title""#)))
    #expect(try encode(VersionsOutput(version)) == #"{"createdAt":"2026-05-24T12:34:56Z","documentID":"abc123","isPinned":false,"path":"/notes/today","sequence":2}"#)
}

@Test func outputDTOInitializersMirrorCoreResults() throws {
    let date = Date(timeIntervalSince1970: 0)
    let document = StoredDocument(
        id: try DocumentID(rawValue: "abc123"),
        path: try DocumentPath("/notes/today"),
        body: "body",
        currentVersion: 1,
        createdAt: date,
        updatedAt: date
    )
    let move = DocumentMoveResult(
        document: document,
        sourcePath: try DocumentPath("/notes/old"),
        destinationPath: try DocumentPath("/notes/today"),
        moved: false
    )

    #expect(PutOutput(document, status: "created").status == "created")
    #expect(PatchOutput(document).operation == "patch")
    #expect(MoveOutput(move).status == "unchanged")
    #expect(PruneOutput(PruneResult(prunedVersionCount: 0, retainedVersionCount: 1)).retainedVersionCount == 1)
}

@Test func documentReferenceDTOConvertsRequestReferences() throws {
    let documentID = try DocumentID(rawValue: "abc123")
    let externalURL = try #require(URL(string: "https://example.com"))

    #expect(try DocumentReferenceDTO(kind: .documentID, value: "ABC123").documentReference() == .documentID(try DocumentID(rawValue: "abc123")))
    #expect(try DocumentReferenceDTO(kind: .path, value: "notes/today").documentReference() == .path(try DocumentPath("/notes/today")))
    #expect(try DocumentReferenceDTO(kind: .url, value: "https://example.com").documentReference() == .externalURL(try #require(URL(string: "https://example.com"))))
    #expect(DocumentReferenceDTO(.documentID(documentID)) == DocumentReferenceDTO(kind: .documentID, value: "abc123"))
    #expect(DocumentReferenceDTO(.externalURL(externalURL)) == DocumentReferenceDTO(kind: .url, value: "https://example.com"))
    #expect(DocumentReferenceListDTO().references == [])
    #expect(try DocumentReferenceListDTO([.path(try DocumentPath("/notes/today"))]).documentReferences() == [.path(try DocumentPath("/notes/today"))])

    #expect(throws: MetaBrainDTOError.invalidURLReference("relative/path")) {
        _ = try DocumentReferenceDTO(kind: .url, value: "relative/path").documentReference()
    }
    #expect(throws: MetaBrainDomainError.invalidDocumentID("bad/id")) {
        _ = try DocumentReferenceDTO(kind: .documentID, value: "bad/id").documentReference()
    }
}

@Test func retentionPolicyDTOConvertsAndValidatesPolicies() throws {
    #expect(try DocumentRetentionPolicyDTO(kind: .keepAll).retentionPolicy() == .keepAll)
    #expect(try DocumentRetentionPolicyDTO(kind: .keepLast, count: 2).retentionPolicy() == .keepMostRecent(2))
    #expect(try DocumentRetentionPolicyDTO(kind: .keepWithin, seconds: 3.5).retentionPolicy() == .keepWithin(3.5))
    #expect(DocumentRetentionPolicyDTO(VersionRetentionPolicy.keepAll).kind == .keepAll)
    #expect(DocumentRetentionPolicyDTO(VersionRetentionPolicy.keepMostRecent(4)).count == 4)
    #expect(DocumentRetentionPolicyDTO(VersionRetentionPolicy.keepWithin(5)).seconds == 5)

    #expect(throws: MetaBrainDTOError.invalidRetentionCount(nil)) {
        _ = try DocumentRetentionPolicyDTO(kind: .keepLast).retentionPolicy()
    }
    #expect(throws: MetaBrainDTOError.invalidRetentionCount(0)) {
        _ = try DocumentRetentionPolicyDTO(kind: .keepLast, count: 0).retentionPolicy()
    }
    #expect(throws: MetaBrainDTOError.invalidRetentionSeconds(nil)) {
        _ = try DocumentRetentionPolicyDTO(kind: .keepWithin).retentionPolicy()
    }
    #expect(throws: MetaBrainDTOError.invalidRetentionSeconds(-1)) {
        _ = try DocumentRetentionPolicyDTO(kind: .keepWithin, seconds: -1).retentionPolicy()
    }
}

@Test func dtoErrorDescriptionsAreStable() {
    #expect(MetaBrainDTOError.invalidURLReference("x").description == "Reference URL must be absolute: x")
    #expect(MetaBrainDTOError.invalidRetentionCount(nil).description == "keepLast retention count must be greater than zero, got nil")
    #expect(MetaBrainDTOError.invalidRetentionCount(0).description == "keepLast retention count must be greater than zero, got 0")
    #expect(MetaBrainDTOError.invalidRetentionSeconds(nil).description == "keepWithin retention seconds must be zero or greater, got nil")
    #expect(MetaBrainDTOError.invalidRetentionSeconds(-1).description == "keepWithin retention seconds must be zero or greater, got -1.0")
}

@Test func serverHTTPTypesExposeStableDefaults() throws {
    let request = ServerHTTPRequest(method: .get, path: "/health")
    let response = ServerHTTPResponse(statusCode: 200, body: Data("ok".utf8))

    #expect(request.method == .get)
    #expect(request.path == "/health")
    #expect(request.headers == [:])
    #expect(request.body.isEmpty)
    #expect(response.bodyText == "ok")
    #expect(ServerHealthPayload(version: "1.2.3") == ServerHealthPayload(service: "mbd", status: "ok", version: "1.2.3"))
    #expect(ServerErrorPayload(error: "invalid_request", message: "path is required.").message == "path is required.")
}

@Test func metabrainVersionHonorsEnvironmentOverride() {
    #expect(MetaBrainVersion.currentSoftwareTag(environment: [:]) == MetaBrainVersion.bundledTag)
    #expect(MetaBrainVersion.currentSoftwareTag(environment: ["METABRAIN_VERSION": "  "]) == MetaBrainVersion.bundledTag)
    #expect(MetaBrainVersion.currentSoftwareTag(environment: ["METABRAIN_VERSION": "9.8.7"]) == "9.8.7")
}

@Test func releaseCheckerMapsHTTPResponsesAndSemanticVersions() async throws {
    let releaseURL = "https://api.example.test/releases/latest"
    let success = await MetaBrainReleaseChecker.checkLatestRelease(
        currentTag: "1.1.2",
        releaseAPIURL: releaseURL,
        timeout: 1,
        fetch: { request in
            #expect(request.url?.absoluteString == releaseURL)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "metaBrain-cli")
            return (
                Data(#"{"html_url":"https://example.test/release","tag_name":"1.2.0"}"#.utf8),
                try httpResponse(statusCode: 200, url: releaseURL)
            )
        }
    )
    #expect(success == ReleaseCheckOutput(
        htmlURL: "https://example.test/release",
        latestTag: "1.2.0",
        message: nil,
        status: "checked",
        updateAvailable: true
    ))

    let nonHTTP = await MetaBrainReleaseChecker.checkLatestRelease(
        currentTag: "1.1.2",
        releaseAPIURL: releaseURL,
        timeout: 1,
        fetch: { _ in
            (Data(), URLResponse(url: try #require(URL(string: releaseURL)), mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
    )
    #expect(nonHTTP.status == "failed")
    #expect(nonHTTP.message == "GitHub releases response was not HTTP.")

    let httpFailure = await MetaBrainReleaseChecker.checkLatestRelease(
        currentTag: "1.1.2",
        releaseAPIURL: releaseURL,
        timeout: 1,
        fetch: { _ in
            (Data(), try httpResponse(statusCode: 503, url: releaseURL))
        }
    )
    #expect(httpFailure.message == "GitHub releases request returned HTTP 503.")

    let decodeFailure = await MetaBrainReleaseChecker.checkLatestRelease(
        currentTag: "1.1.2",
        releaseAPIURL: releaseURL,
        timeout: 1,
        fetch: { _ in
            (Data("{}".utf8), try httpResponse(statusCode: 200, url: releaseURL))
        }
    )
    #expect(decodeFailure.status == "failed")
    #expect(decodeFailure.message != nil)

    let transportFailure = await MetaBrainReleaseChecker.checkLatestRelease(
        currentTag: "1.1.2",
        releaseAPIURL: releaseURL,
        timeout: 1,
        fetch: { _ in throw SampleError() }
    )
    #expect(transportFailure.status == "failed")
    #expect(transportFailure.message != nil)

    let invalidURL = await MetaBrainReleaseChecker.checkLatestRelease(
        currentTag: "1.1.2",
        releaseAPIURL: "http://[::1",
        timeout: 1
    )
    #expect(invalidURL.message == "Invalid GitHub releases URL.")

    #expect(MetaBrainReleaseChecker.semanticVersionParts("v1.2.3-beta") == [1, 2, 3])
    #expect(MetaBrainReleaseChecker.semanticVersionParts("1.2") == [])
    #expect(MetaBrainReleaseChecker.semanticVersionParts("1.two.3") == [])
    #expect(MetaBrainReleaseChecker.isReleaseTag("1.1.2", newerThan: "1.1.2") == false)
    #expect(MetaBrainReleaseChecker.isReleaseTag("1.1.1", newerThan: "1.1.2") == false)
    #expect(MetaBrainReleaseChecker.isReleaseTag("nightly", newerThan: "1.1.2") == true)
}

private func encode<T: Encodable>(_ value: T) throws -> String {
    let data = try MetaBrainJSON.encoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

private struct SampleError: Error {}

private func httpResponse(statusCode: Int, url: String) throws -> HTTPURLResponse {
    let responseURL = try #require(URL(string: url))
    return try #require(HTTPURLResponse(
        url: responseURL,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    ))
}
