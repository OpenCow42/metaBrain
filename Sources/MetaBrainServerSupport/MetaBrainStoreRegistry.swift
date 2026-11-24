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
        var opening: Task<MetaBrainStoreServer, Error>
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
        createIfMissing: Bool = true,
        operation: @Sendable (MetaBrainStoreServer) async throws -> Result
    ) async throws -> Result {
        try await withStore(
            at: storePath,
            createIfMissing: createIfMissing,
            initializingEmpty: nil,
            operation: operation
        )
    }

    func withStore<Result: Sendable>(
        at storePath: String,
        createIfMissing: Bool,
        initializingEmpty: Bool?,
        operation: @Sendable (MetaBrainStoreServer) async throws -> Result
    ) async throws -> Result {
        let key = Self.canonicalStorePath(storePath)
        let opening = try acquireStore(
            at: key,
            createIfMissing: createIfMissing,
            initializingEmpty: initializingEmpty
        )
        let storeServer: MetaBrainStoreServer
        do {
            storeServer = try await opening.value
        } catch {
            releaseStore(at: key, openFailed: true)
            throw error
        }

        do {
            let result = try await operation(storeServer)
            releaseStore(at: key)
            return result
        } catch {
            releaseStore(at: key)
            throw error
        }
    }

    public func closeAll() async {
        let pendingStores = entries.values.map(\.opening)
        entries.removeAll()
        for opening in pendingStores {
            await (try? opening.value)?.close()
        }
    }

    public nonisolated func closeAllBlocking() {
        try! ServerAsyncBridge.run {
            await self.closeAll()
        }
    }

    private func acquireStore(
        at key: String,
        createIfMissing: Bool,
        initializingEmpty: Bool?
    ) throws -> Task<MetaBrainStoreServer, Error> {
        if var entry = entries[key] {
            entry.activeRequestCount += 1
            entry.releaseGeneration &+= 1
            entries[key] = entry
            return entry.opening
        }

        let opening: Task<MetaBrainStoreServer, Error>
        if let initializingEmpty {
            // Publish the open task before awaiting it so all requests share initialization.
            opening = Task {
                try await MetaBrainStoreServer.openInitialized(storePath: key, empty: initializingEmpty)
            }
        } else {
            let storeServer = try MetaBrainStoreServer(storePath: key, createIfMissing: createIfMissing)
            opening = Task { storeServer }
        }
        entries[key] = Entry(
            opening: opening,
            activeRequestCount: 1,
            releaseGeneration: 1
        )
        return opening
    }

    private func releaseStore(at key: String, openFailed: Bool = false) {
        guard var entry = entries[key] else {
            return
        }

        entry.activeRequestCount = max(0, entry.activeRequestCount - 1)
        if openFailed && entry.activeRequestCount == 0 {
            entries.removeValue(forKey: key)
            return
        }
        entry.releaseGeneration &+= 1
        let generation = entry.releaseGeneration
        entries[key] = entry

        guard entry.activeRequestCount == 0 else {
            return
        }

        Task { @concurrent [idleTimeoutNanoseconds] in
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
        await (try? entry.opening.value)?.close()
    }

    private nonisolated static func canonicalStorePath(_ storePath: String) -> String {
        URL(fileURLWithPath: NSString(string: storePath).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .path
    }
}
