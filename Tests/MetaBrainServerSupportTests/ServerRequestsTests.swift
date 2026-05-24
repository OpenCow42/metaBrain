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
