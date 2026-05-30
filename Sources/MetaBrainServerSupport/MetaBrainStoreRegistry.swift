import Foundation

public actor MetaBrainStoreRegistry {
    public static let storePathHeader = "X-MetaBrain-Store-Path"
    public static let defaultIdleTimeoutSeconds = 30.0

    public nonisolated static func storePathHeaderValue(for storePath: String) -> String {
        Data(canonicalStorePath(storePath).utf8).base64EncodedString()
    }

    public nonisolated static func storePath(fromHeaderValue value: String) -> String? {
        guard let data = Data(base64Encoded: value),
              let path = String(data: data, encoding: .utf8),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return canonicalStorePath(path)
    }

    private struct Entry {
        var storeServer: MetaBrainStoreServer
        var activeRequestCount: Int
        var releaseGeneration: UInt64
    }

    private let idleTimeoutNanoseconds: UInt64
    private var entries: [String: Entry] = [:]

    public init(idleTimeoutSeconds: Double = MetaBrainStoreRegistry.defaultIdleTimeoutSeconds) {
        let clampedSeconds = max(0.001, idleTimeoutSeconds)
        self.idleTimeoutNanoseconds = UInt64((clampedSeconds * 1_000_000_000).rounded(.up))
    }

    public var openStoreCount: Int {
        entries.count
    }

    public func withStore<Result: Sendable>(
        at storePath: String,
        operation: @Sendable (MetaBrainStoreServer) async throws -> Result
    ) async throws -> Result {
        let key = Self.canonicalStorePath(storePath)
        let storeServer = try await acquireStore(at: key)

        do {
            let result = try await operation(storeServer)
            await releaseStore(at: key)
            return result
        } catch {
            await releaseStore(at: key)
            throw error
        }
    }

    public func closeAll() async {
        let servers = entries.values.map(\.storeServer)
        entries.removeAll()
        for server in servers {
            await server.close()
        }
    }

    public nonisolated func closeAllBlocking() {
        try! ServerAsyncBridge.run {
            await self.closeAll()
        }
    }

    private func acquireStore(at key: String) async throws -> MetaBrainStoreServer {
        if var entry = entries[key] {
            entry.activeRequestCount += 1
            entry.releaseGeneration &+= 1
            entries[key] = entry
            return entry.storeServer
        }

        let storeServer = try MetaBrainStoreServer(storePath: key)
        entries[key] = Entry(
            storeServer: storeServer,
            activeRequestCount: 1,
            releaseGeneration: 1
        )
        return storeServer
    }

    private func releaseStore(at key: String) async {
        guard var entry = entries[key] else {
            return
        }

        entry.activeRequestCount = max(0, entry.activeRequestCount - 1)
        entry.releaseGeneration &+= 1
        let generation = entry.releaseGeneration
        entries[key] = entry

        guard entry.activeRequestCount == 0 else {
            return
        }

        Task { [idleTimeoutNanoseconds] in
            try? await Task.sleep(nanoseconds: idleTimeoutNanoseconds)
            await self.closeStoreIfIdle(at: key, generation: generation)
        }
    }

    private func closeStoreIfIdle(at key: String, generation: UInt64) async {
        guard let entry = entries[key],
              entry.activeRequestCount == 0,
              entry.releaseGeneration == generation
        else {
            return
        }

        entries.removeValue(forKey: key)
        await entry.storeServer.close()
    }

    private nonisolated static func canonicalStorePath(_ storePath: String) -> String {
        URL(fileURLWithPath: NSString(string: storePath).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .path
    }
}
