import Foundation

struct TemporaryStoreFixture: Sendable {
    let rootURL: URL
    let storeURL: URL

    init(testName: String = #function) throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MetaBrainCoreTests", isDirectory: true)
        let uniqueName = "\(Self.sanitized(testName))-\(UUID().uuidString)"

        rootURL = baseURL.appendingPathComponent(uniqueName, isDirectory: true)
        storeURL = rootURL.appendingPathComponent("store.leveldb", isDirectory: true)

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func createStoreDirectory() throws {
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
    }

    func cleanUp() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
    }

    private static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
    }
}

func withTemporaryStoreFixture(
    testName: String = #function,
    _ body: (TemporaryStoreFixture) async throws -> Void
) async throws {
    let fixture = try TemporaryStoreFixture(testName: testName)
    defer {
        try? fixture.cleanUp()
    }

    try await body(fixture)
}
