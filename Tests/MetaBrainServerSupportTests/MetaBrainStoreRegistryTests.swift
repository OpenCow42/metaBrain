import Foundation
import Testing
@testable import MetaBrainServerSupport

@Test func storeRegistryOpensAndReleasesIdleStores() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-store-registry-idle")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = MetaBrainStoreRegistry(idleTimeoutSeconds: 0.01)
    defer { registry.closeAllBlocking() }
    let storePath = root.appendingPathComponent("store.leveldb").path

    #expect(await registry.openStoreCount == 0)

    let initialized = try await registry.withStore(at: storePath) { storeServer in
        await storeServer.initialize()
    }

    #expect(initialized.storePath == storePath)
    #expect(await registry.openStoreCount == 1)

    #expect(await eventually(timeoutSeconds: 2) {
        await registry.openStoreCount == 0
    })

    let reopened = try MetaBrainStoreServer(storePath: storePath)
    await reopened.close()
}

private func eventually(
    timeoutSeconds: Double,
    intervalNanoseconds: UInt64 = 25_000_000,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return await condition()
}

@Test func storeRegistryKeepsDistinctStoreActorsByCanonicalPath() async throws {
    let root = try temporaryServerDirectory(prefix: "mbd-store-registry-multi")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = MetaBrainStoreRegistry(idleTimeoutSeconds: 10)
    defer { registry.closeAllBlocking() }
    let firstStore = root.appendingPathComponent("first.leveldb").path
    let secondStore = root.appendingPathComponent("second.leveldb").path

    _ = try await registry.withStore(at: firstStore) { storeServer in
        try await storeServer.put(ServerPutRequest(path: "/shared/path", body: "first body"))
    }
    _ = try await registry.withStore(at: secondStore) { storeServer in
        try await storeServer.put(ServerPutRequest(path: "/shared/path", body: "second body"))
    }

    let first = try await registry.withStore(at: firstStore) { storeServer in
        try await storeServer.get(ServerGetRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/shared/path"),
            trackingRead: false
        ))
    }
    let second = try await registry.withStore(at: secondStore) { storeServer in
        try await storeServer.get(ServerGetRequest(
            reference: DocumentReferenceDTO(kind: .path, value: "/shared/path"),
            trackingRead: false
        ))
    }

    #expect(first.body == "first body")
    #expect(second.body == "second body")
    #expect(await registry.openStoreCount == 2)
}

@Test func storeRegistryHeaderValueRoundTripsCanonicalPath() throws {
    let rawPath = "~/metabrain store.leveldb"
    let header = MetaBrainStoreRegistry.storePathHeaderValue(for: rawPath)
    let decoded = try #require(MetaBrainStoreRegistry.storePath(fromHeaderValue: header))

    #expect(decoded.hasSuffix("/metabrain store.leveldb"))
    #expect(MetaBrainStoreRegistry.storePath(fromHeaderValue: "not base64") == nil)
}
