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

@Test func storeServerHandlesReadSideRoutes() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-store-reads")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }

    _ = try await server.put(ServerPutRequest(
        path: "/notes/today",
        body: "alpha beta",
        title: "Today",
        tags: ["planning"],
        metadata: ["source": "agent"]
    ))
    _ = try await server.put(ServerPutRequest(path: "/notes/archive/yesterday", body: "alpha archive"))

    let list = try await server.list(ServerListRequest(path: "/notes", recursive: true))
    let tree = try await server.tree(ServerTreeRequest(path: "/notes", maxDepth: 2))
    let rootOnly = try await server.tree(ServerTreeRequest(path: "/missing", maxDepth: 0))
    let missingTree = try await server.tree(ServerTreeRequest(path: "/missing"))
    let search = try await server.search(ServerSearchRequest(
        query: "alpha",
        pathPrefix: "/notes",
        tags: ["planning"],
        metadata: ["source": "agent"],
        limit: 5
    ))
    let versions = try await server.versions(ServerVersionsRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/today")
    ))

    #expect(list.map(\.path).contains("/notes/today"))
    #expect(tree.first == TreeOutput(root: try DocumentPath("/notes"), hasChildren: true))
    #expect(rootOnly == [TreeOutput(root: try DocumentPath("/missing"), hasChildren: false)])
    #expect(missingTree == [])
    #expect(search.map(\.path) == ["/notes/today"])
    #expect(versions.map(\.sequence) == [1])
}

@Test func storeServerHandlesMutationRoutes() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-store-mutations")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try MetaBrainStoreServer(storePath: root.appendingPathComponent("store.leveldb").path)
    defer { server.closeBlocking() }

    let diff = """
    --- a/doc
    +++ b/doc
    @@ -1,2 +1,2 @@
    -old
    +new
     line
    """

    let created = try await server.put(ServerPutRequest(path: "/notes/today", body: "old\nline\n"))
    let check = try await server.patch(ServerPatchRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"),
        unifiedDiff: diff,
        check: true
    ))
    let patched = try await server.patch(ServerPatchRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"),
        unifiedDiff: diff
    ))
    let fetched = try await server.get(ServerGetRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/today"),
        trackingRead: false
    ))
    let moved = try await server.move(ServerMoveRequest(
        reference: DocumentReferenceDTO(kind: .documentID, value: created.documentID),
        destinationPath: "/notes/archive/today"
    ))
    let unchanged = try await server.move(ServerMoveRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/archive/today"),
        destinationPath: "/notes/archive/today"
    ))
    let missingDelete = try await server.delete(ServerDeleteRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/missing")
    ))
    let missingRemove = try await server.removeVersion(ServerRemoveVersionRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/missing"),
        sequence: 1
    ))

    await #expect(throws: MetaBrainStoreError.currentVersionCannotBeRemoved(
        try DocumentID(rawValue: created.documentID),
        sequence: 3
    )) {
        _ = try await server.removeVersion(ServerRemoveVersionRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/notes/archive/today"),
            sequence: 3
        ))
    }

    let removed = try await server.removeVersion(ServerRemoveVersionRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/archive/today"),
        sequence: 1
    ))
    let pruned = try await server.prune(ServerPruneRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/archive/today"),
        retention: DocumentRetentionPolicyDTO(kind: .keepLast, count: 1)
    ))
    let deleted = try await server.delete(ServerDeleteRequest(
        reference: DocumentReferenceDTO(kind: .path, value: "/notes/archive/today")
    ))

    #expect(check == .check(PatchCheckOutput()))
    #expect(patched == .patch(PatchOutput(
        documentID: created.documentID,
        path: "/notes/today",
        version: 2
    )))
    #expect(fetched.body == "new\nline\n")
    #expect(moved.status == "moved")
    #expect(moved.from == "/notes/today")
    #expect(moved.path == "/notes/archive/today")
    #expect(moved.version == 3)
    #expect(unchanged.status == "unchanged")
    #expect(!missingDelete.deleted)
    #expect(!missingRemove.removed)
    #expect(removed.removed)
    #expect(pruned.prunedVersionCount == 1)
    #expect(pruned.retainedVersionCount == 1)
    #expect(deleted.deleted)
}

@Test func serverAsyncBridgePropagatesOperationFailures() throws {
    #expect(throws: ServerAsyncBridgeTestError.sample) {
        let _: Void = try ServerAsyncBridge.run {
            throw ServerAsyncBridgeTestError.sample
        }
    }
}

private enum ServerAsyncBridgeTestError: Error, Equatable {
    case sample
}
