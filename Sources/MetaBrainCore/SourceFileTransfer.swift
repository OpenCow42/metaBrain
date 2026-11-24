import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Transfers an original through bounded chunks. Direct and remote clients use the same integrity checks.
public enum SourceFileTransfer {
    public static func stage(
        file: URL,
        put: @Sendable (Data) async throws -> String,
        finish: @Sendable ([String]) async throws -> SourceBlob
    ) async throws -> SourceBlob {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var chunks: [String] = []
        var hash = SHA256()
        var length = 0
        var chunk = Data()
        while let part = try input.read(upToCount: SourceBlob.chunkSize - chunk.count), !part.isEmpty {
            try Task.checkCancellation()
            chunk.append(part)
            hash.update(data: part)
            length += part.count
            if chunk.count == SourceBlob.chunkSize {
                chunks.append(try await put(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { chunks.append(try await put(chunk)) }
        try Task.checkCancellation()
        let result = try await finish(chunks)
        guard result == SourceBlob(sha256: hash.finalize().hexString, byteCount: length) else {
            throw ProjectOperationError.invalid("The stored bytes differ from the local original.")
        }
        return result
    }

    public static func export(
        _ blob: SourceBlob,
        to destination: URL,
        read: @Sendable (Int) async throws -> Data
    ) async throws {
        try blob.validate()
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".metabrain-export-" + UUID().uuidString)
        try Data().write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            var hash = SHA256()
            for index in 0..<blob.chunkCount {
                try Task.checkCancellation()
                let part = try await read(index)
                let expected = min(SourceBlob.chunkSize, blob.byteCount - index * SourceBlob.chunkSize)
                guard part.count == expected else {
                    throw ProjectOperationError.invalid("The original contains an incomplete chunk.")
                }
                hash.update(data: part)
                try output.write(contentsOf: part)
            }
            guard hash.finalize().hexString == blob.sha256 else {
                throw ProjectOperationError.invalid("The exported bytes differ from the captured original.")
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        try Task.checkCancellation()
        #if canImport(Darwin) || canImport(Glibc)
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #else
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        #endif
    }
}
