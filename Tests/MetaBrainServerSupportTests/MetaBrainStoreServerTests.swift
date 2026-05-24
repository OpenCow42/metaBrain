import Foundation
import MetaBrainCore
import Testing
@testable import MetaBrainServerSupport

@Test func storeServerOwnsOneStoreAndHandlesInitialRoutes() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-store-server")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }

    #expect((await server.initialize()).storePath.hasSuffix("store.leveldb"))
    #expect((await server.version()).releaseCheck == nil)

    let created = try await server.put(ServerPutRequest(path: "/notes/today", body: "first"))
    let updated = try await server.put(ServerPutRequest(path: "/notes/today", body: "second"))
    let fetched = try await server.get(ServerGetRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"),
        trackingRead: false
    ))

    #expect(created.status == "created")
    #expect(created.version == 1)
    #expect(updated.status == "updated")
    #expect(updated.documentID == created.documentID)
    #expect(fetched.body == "second")
    #expect(fetched.version == 2)
}

@Test func storeServerReportsMissingReferences() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-store-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }

    await #expect(throws: MetaBrainStoreError.documentNotFound("/missing")) {
        _ = try await server.get(ServerGetRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/missing")
        ))
    }
    await #expect(throws: MetaBrainStoreError.documentNotFound("abc123")) {
        _ = try await server.get(ServerGetRequest(
            reference: DocumentReferenceDTO(kind: .documentID, value: "abc123")
        ))
    }
    await #expect(throws: MetaBrainStoreError.documentNotFound("https://example.com")) {
        _ = try await server.get(ServerGetRequest(
            reference: DocumentReferenceDTO(kind: .url, value: "https://example.com")
        ))
    }
}
