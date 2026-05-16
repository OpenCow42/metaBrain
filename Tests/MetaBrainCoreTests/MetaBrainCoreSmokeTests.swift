import Foundation
import MetaBrainCore
import Testing

@Test func metaBrainCoreTestTargetRuns() {
    let brain = MetaBrain()

    #expect(brain.respond(to: "") == "MetaBrain is ready.")
    #expect(brain.respond(to: "hello") == "MetaBrain heard: hello")
}

@Test func temporaryStoreFixtureProvidesIsolatedStoreLocation() async throws {
    try await withTemporaryStoreFixture { fixture in
        #expect(FileManager.default.fileExists(atPath: fixture.rootURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.storeURL.path))
        #expect(fixture.storeURL.lastPathComponent == "store.leveldb")

        try fixture.createStoreDirectory()

        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: fixture.storeURL.path,
            isDirectory: &isDirectory
        )

        #expect(exists)
        #expect(isDirectory.boolValue)
    }
}
