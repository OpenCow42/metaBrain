import Crypto
import Foundation
import LevelDBTyped
import LevelDBZstd
import Testing
@testable import MetaBrainCore

@Test func stagedOriginalsDeduplicateAndKeepIndependentProvenanceAfterReopen() async throws {
    try await withTemporaryStoreFixture { fixture in
        let project = try DocumentPath("/atlas")
        let first = try DocumentPath("/atlas/sources/local")
        let second = try DocumentPath("/atlas/sources/remote")
        let bytes = Data([0, 255, 13, 10, 0, 165])
        let store = try MetaBrainStore(url: fixture.storeURL)
        let firstChunk = try await store.stageSourceChunk(bytes)
        #expect(try await store.stageSourceChunk(bytes) == firstChunk)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.sourceChunk(firstChunk)) == bytes)
        let blob = try await store.finishSourceBlob(chunks: [firstChunk])
        #expect(try await store.finishSourceBlob(chunks: [firstChunk]) == blob)
        #expect(blob.sha256 == SHA256.hash(data: bytes).hexString)
        #expect(blob.byteCount == bytes.count)
        #expect(blob.chunkCount == 1)

        await #expect(throws: (any Error).self) { try await store.sourceDescriptor(.path(first)) }
        let local = SourceCapture(blob: blob, filename: "report.bin", mediaType: "application/octet-stream", origin: "local review")
        let remote = SourceCapture(
            blob: blob, filename: "review.bin", mediaType: "application/octet-stream", origin: "remote review",
            extraction: "Reviewer-supplied transcription"
        )
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: first, body: "", sourceCapture: local),
            DocumentInput(path: second, body: "Reviewer describes replication.", sourceCapture: remote)
        ])
        let preview = try await store.inspectOperation(operation)
        await #expect(throws: (any Error).self) {
            try await store.sourceChunk(.path(first), version: 1, index: 0)
        }
        let receipt = try await store.applyOperation(preview)
        #expect(receipt.results.map(\.status) == [.created, .created])
        #expect(try await store.sourceDescriptor(.path(first)).capture == local)
        #expect(try await store.sourceDescriptor(.path(second)).capture == remote)
        #expect(try await store.getDocument(.path(first), trackingRead: false)?.body == "")
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.applyOperation(preview) == receipt)
        #expect(try await reopened.sourceChunk(.path(first), version: 1, index: 0) == bytes)
        #expect(try await reopened.sourceChunk(.path(second), version: 1, index: 0) == bytes)
        let moved = try DocumentPath("/atlas/archive/local")
        _ = try await reopened.moveDocument(.path(first), to: moved)
        let firstID = try #require(receipt.results.first?.documentID)
        #expect(try await reopened.sourceDescriptor(.path(moved)).capture == local)
        #expect(try await reopened.sourceDescriptor(.documentID(firstID), version: 1).capture == local)
        #expect(try await reopened.sourceChunk(.documentID(firstID), version: 1, index: 0) == bytes)
        #expect(try await reopened.sourceChunk(.path(moved), version: 2, index: 0) == bytes)

        _ = try await reopened.putDocument(DocumentInput(path: moved, body: "Added analysis of the original."))
        #expect(try await reopened.sourceDescriptor(.path(moved)).capture == local)
        #expect(try await reopened.sourceDescriptor(.path(moved)).version == 3)
        let recaptured = try await reopened.writeDocument(DocumentInput(
            path: moved, body: "Added analysis of the original.", sourceCapture: remote
        ))
        #expect(recaptured.status == .updated)
        #expect(try await reopened.sourceDescriptor(.path(moved)).capture == remote)
        #expect(try await reopened.sourceDescriptor(.path(moved), version: 3).capture == local)
        await #expect(throws: MetaBrainStoreError.invalidDocumentVersion(0)) {
            try await reopened.sourceDescriptor(.path(moved), version: 0)
        }

        #expect(try await reopened.removeVersion(documentID: firstID, sequence: 1))
        await #expect(throws: (any Error).self) {
            try await reopened.sourceChunk(.documentID(firstID), version: 1, index: 0)
        }
        #expect(try await reopened.sourceChunk(.path(moved), version: 2, index: 0) == bytes)
        let withoutCapture = try DocumentPath("/atlas/plain")
        _ = try await reopened.putDocument(DocumentInput(path: withoutCapture, body: "Ordinary note"))
        await #expect(throws: (any Error).self) { try await reopened.sourceDescriptor(.path(withoutCapture)) }
    }
}

@Test func sourceCaptureRejectsMissingAndInconsistentManifestsAtomically() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let decision = try DocumentPath("/atlas/decision")
        let captured = try DocumentPath("/atlas/source")
        let bytes = Data("Uncommitted original".utf8)
        let chunk = try await store.stageSourceChunk(bytes)
        let hash = SHA256.hash(data: bytes).hexString
        let missing = SourceBlob(sha256: hash, byteCount: bytes.count)
        let operationID = UUID()
        func operation(_ blob: SourceBlob) -> ProjectOperation {
            ProjectOperation(operationID: operationID, project: project, documents: [
                DocumentInput(path: decision, body: "Decision"),
                DocumentInput(path: captured, body: "", sourceCapture: SourceCapture(
                    blob: blob, filename: "source.txt", mediaType: "text/plain", origin: "review"
                ))
            ])
        }

        await #expect(throws: (any Error).self) { try await store.inspectOperation(operation(missing)) }
        #expect(try await store.getDocument(.path(decision), trackingRead: false) == nil)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.operationReceipt(operationID)) == nil)

        let staged = try await store.finishSourceBlob(chunks: [chunk])
        #expect(staged == missing)
        let incorrectBytes = SourceBlob(sha256: hash, byteCount: bytes.count + 1)
        await #expect(throws: (any Error).self) { try await store.inspectOperation(operation(incorrectBytes)) }
        #expect(try await store.getDocument(.path(decision), trackingRead: false) == nil)

        let valid = try await store.inspectOperation(operation(staged))
        let manifestKey = MetaBrainKeyspace.sourceBlob(staged.sha256)
        let manifest = try #require(try await store.rawValue(forKey: manifestKey))
        try await store.deleteRawValue(forKey: manifestKey)
        await #expect(throws: (any Error).self) { try await store.applyOperation(valid) }
        #expect(try await store.getDocument(.path(decision), trackingRead: false) == nil)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.operationReceipt(operationID)) == nil)
        try await store.writeRawValue(manifest, forKey: manifestKey)
        #expect(try await store.applyOperation(valid).results.map(\.status) == [.created, .created])
        #expect(try await store.sourceChunk(.path(captured), version: 1, index: 0) == bytes)
    }
}

@Test func sourceChunksRejectMissingOversizedAndNonfinalShortChunks() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let short = try await store.stageSourceChunk(Data([0, 255]))
        let emptyHash = SHA256.hash(data: Data()).hexString
        let empty = try await store.finishSourceBlob(chunks: [])
        #expect(empty == SourceBlob(sha256: emptyHash, byteCount: 0))
        #expect(empty.chunkCount == 0)
        await #expect(throws: (any Error).self) { try await store.stageSourceChunk(Data()) }
        await #expect(throws: (any Error).self) {
            try await store.stageSourceChunk(Data(repeating: 0, count: SourceBlob.chunkSize + 1))
        }
        await #expect(throws: (any Error).self) { try await store.finishSourceBlob(chunks: ["bad"]) }
        await #expect(throws: (any Error).self) { try await store.finishSourceBlob(chunks: [emptyHash]) }
        await #expect(throws: (any Error).self) { try await store.finishSourceBlob(chunks: [short, short]) }

        let project = try DocumentPath("/atlas")
        let note = try DocumentPath("/atlas/empty")
        let source = SourceCapture(blob: empty, filename: "empty.bin", mediaType: "application/octet-stream", origin: "empty review")
        let operation = ProjectOperation(
            operationID: UUID(), project: project, documents: [DocumentInput(path: note, body: "", sourceCapture: source)]
        )
        let preview = try await store.inspectOperation(operation)
        _ = try await store.applyOperation(preview)
        #expect(try await store.sourceDescriptor(.path(note)).capture == source)
        await #expect(throws: (any Error).self) { try await store.sourceChunk(.path(note), version: 1, index: 0) }
    }
}

private struct SourceManifestFixture: Codable, Sendable {
    let blob: SourceBlob
    let chunks: [String]
}

@Test func corruptedSourceRecordsFailVerificationAtReadAndRestage() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let original = Data([1, 2, 3])
        let chunk = try await store.stageSourceChunk(original)
        let blob = try await store.finishSourceBlob(chunks: [chunk])
        let capture = SourceCapture(blob: blob, filename: "source.bin", mediaType: "application/octet-stream", origin: "test")
        let path = try DocumentPath("/atlas/source")
        _ = try await store.putDocument(DocumentInput(path: path, body: "", sourceCapture: capture))
        let manifestKey = MetaBrainKeyspace.sourceBlob(blob.sha256)
        let chunkKey = MetaBrainKeyspace.sourceChunk(chunk)
        let chunkError = MetaBrainStoreError.operationFailed(message: "Stored source chunk differs from its digest.")
        try await store.writeRawValue(Data([4, 5, 6]), forKey: chunkKey)
        await #expect(throws: chunkError) { try await store.stageSourceChunk(original) }
        await #expect(throws: chunkError) { try await store.sourceChunk(.path(path), version: 1, index: 0) }
        try await store.writeRawValue(original, forKey: chunkKey)

        let missingChunk = SourceManifestFixture(blob: blob, chunks: [])
        try await store.putCompressedRecord(missingChunk, forKey: manifestKey)
        await store.close()
        let reopened = try MetaBrainStore(url: fixture.storeURL)
        await #expect(throws: MetaBrainStoreError.operationFailed(message: "Source manifest has an invalid chunk count.")) {
            try await reopened.sourceChunk(.path(path), version: 1, index: 0)
        }
        await #expect(throws: MetaBrainStoreError.operationFailed(message: "Stored source manifest differs from the verified original.")) {
            try await reopened.finishSourceBlob(chunks: [chunk])
        }

        let tooShort = try await reopened.stageSourceChunk(Data([1]))
        let mismatchedChunk = SourceManifestFixture(blob: blob, chunks: [tooShort])
        try await reopened.putCompressedRecord(mismatchedChunk, forKey: manifestKey)
        await #expect(throws: MetaBrainStoreError.operationFailed(message: "Stored source chunk length disagrees with the manifest.")) {
            try await reopened.sourceChunk(.path(path), version: 1, index: 0)
        }

        let codec = ZstdCodec(
            wrapping: JSONCodec<MetaBrainRecordEnvelope<SourceManifestFixture>>(),
            compressionLevel: reopened.options.zstdCompressionLevel
        )
        let future = SourceManifestFixture(blob: blob, chunks: [chunk])
        let encoded = try codec.encode(MetaBrainRecordEnvelope(schemaVersion: 2, payload: future))
        try await reopened.writeRawValue(encoded, forKey: manifestKey)
        await #expect(throws: MetaBrainStoreError.newerRecordSchemaVersion(2, operation: "reuse verified source manifest")) {
            try await reopened.finishSourceBlob(chunks: [chunk])
        }
        let reviewed = ProjectOperation(operationID: UUID(), project: try DocumentPath("/atlas"), documents: [
            DocumentInput(path: path, body: "A new draft", sourceCapture: capture)
        ])
        await #expect(throws: MetaBrainStoreError.newerRecordSchemaVersion(2, operation: "read verified source manifest")) {
            try await reopened.inspectOperation(reviewed)
        }
    }
}

@Test func sourceCaptureValidationRejectsMalformedIdentityAndProvenance() throws {
    let hash = SHA256.hash(data: Data()).hexString
    let blob = SourceBlob(sha256: hash, byteCount: 0)
    try blob.validate()
    for invalid in [
        SourceBlob(sha256: hash, byteCount: -1),
        SourceBlob(sha256: hash.uppercased(), byteCount: 0),
        SourceBlob(sha256: "short", byteCount: 0),
        SourceBlob(sha256: String(repeating: "g", count: 64), byteCount: 0)
    ] {
        #expect(throws: ProjectOperationError.invalid("Expected a nonnegative byte count and lowercase SHA-256 digest.")) {
            try invalid.validate()
        }
    }
    for filename in ["", ".", "..", "/nested/name", "nested\\name", "line\nbreak"] {
        let capture = SourceCapture(blob: blob, filename: filename, mediaType: "text/plain", origin: "review")
        #expect(throws: ProjectOperationError.invalid("Expected an original filename without directory components.")) {
            try capture.validate()
        }
    }
    for capture in [
        SourceCapture(blob: blob, filename: "review", mediaType: "text", origin: "review"),
        SourceCapture(blob: blob, filename: "review", mediaType: "/plain", origin: "review"),
        SourceCapture(blob: blob, filename: "review", mediaType: "text/", origin: "review"),
        SourceCapture(blob: blob, filename: "review", mediaType: "text /plain", origin: "review"),
        SourceCapture(blob: blob, filename: "review", mediaType: "text/plain;\ncharset=utf-8", origin: "review"),
        SourceCapture(blob: blob, filename: "review", mediaType: "text/plain", origin: " "),
        SourceCapture(blob: blob, filename: "review", mediaType: "text/plain", origin: "review", extraction: " ")
    ] {
        #expect(throws: ProjectOperationError.invalid("Provide a media type, an origin and, when specified, a nonempty extraction method.")) {
            try capture.validate()
        }
    }
    try SourceCapture(
        blob: blob, filename: "review", mediaType: "text/plain; charset=utf-8", origin: "review", extraction: "OCR"
    ).validate()
}

@Test func sourceFileTransferStreamsAndPreservesDestinationOnFailure() async throws {
    try await withTemporaryStoreFixture { fixture in
        let original = fixture.rootURL.appendingPathComponent("original.bin")
        let empty = fixture.rootURL.appendingPathComponent("empty.bin")
        let destination = fixture.rootURL.appendingPathComponent("export.bin")
        let bytes = Data(repeating: 165, count: SourceBlob.chunkSize) + Data([0, 13, 10, 255])
        let oldOutput = Data("Existing output".utf8)
        try bytes.write(to: original)
        try Data().write(to: empty)
        try oldOutput.write(to: destination)

        let store = try MetaBrainStore(url: fixture.storeURL)
        let blob = try await SourceFileTransfer.stage(file: original, put: store.stageSourceChunk, finish: store.finishSourceBlob)
        #expect(blob.sha256 == SHA256.hash(data: bytes).hexString)
        #expect(blob.byteCount == bytes.count)
        #expect(blob.chunkCount == 2)
        let emptyBlob = try await SourceFileTransfer.stage(file: empty, put: store.stageSourceChunk, finish: store.finishSourceBlob)
        #expect(emptyBlob.byteCount == 0)
        #expect(emptyBlob.chunkCount == 0)
        await #expect(throws: ProjectOperationError.invalid("The stored bytes differ from the local original.")) {
            try await SourceFileTransfer.stage(file: original, put: store.stageSourceChunk) { _ in emptyBlob }
        }

        let project = try DocumentPath("/atlas")
        let path = try DocumentPath("/atlas/blob")
        let capture = SourceCapture(blob: blob, filename: original.lastPathComponent, mediaType: "application/octet-stream", origin: "test")
        let preview = try await store.inspectOperation(ProjectOperation(
            operationID: UUID(), project: project, documents: [DocumentInput(path: path, body: "", sourceCapture: capture)]
        ))
        _ = try await store.applyOperation(preview)
        let read: @Sendable (Int) async throws -> Data = { index in
            try await store.sourceChunk(.path(path), version: 1, index: index)
        }
        for bogus in [SourceBlob(sha256: String(repeating: "0", count: 64), byteCount: blob.byteCount),
                      SourceBlob(sha256: blob.sha256, byteCount: blob.byteCount - 1)] {
            await #expect(throws: (any Error).self) {
                try await SourceFileTransfer.export(bogus, to: destination, read: read)
            }
            #expect(try Data(contentsOf: destination) == oldOutput)
        }
        await #expect(throws: (any Error).self) {
            try await SourceFileTransfer.export(blob, to: destination) { index in
                if index == 1 { throw CocoaError(.fileReadUnknown) }
                return try await read(index)
            }
        }
        #expect(try Data(contentsOf: destination) == oldOutput)

        let canceled = Task {
            try await SourceFileTransfer.export(blob, to: destination) { index in
                let part = try await read(index)
                if index == blob.chunkCount - 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return part
            }
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(try Data(contentsOf: destination) == oldOutput)

        let successfulDestination = fixture.rootURL.appendingPathComponent("successful.bin")
        try await SourceFileTransfer.export(blob, to: successfulDestination, read: read)
        #expect(try Data(contentsOf: successfulDestination) == bytes)
        let emptyDestination = fixture.rootURL.appendingPathComponent("export-empty.bin")
        try await SourceFileTransfer.export(emptyBlob, to: emptyDestination) { _ in
            Issue.record("A zero-byte original must not request a chunk.")
            return Data()
        }
        #expect(try Data(contentsOf: emptyDestination).isEmpty)
        let directory = fixture.rootURL.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await SourceFileTransfer.export(emptyBlob, to: directory) { _ in Data() }
        }
    }
}

@Test func sourceByteCountChecksBothOverflowBoundaries() throws {
    let largestFullChunkCount = Int.max / SourceBlob.chunkSize
    let largestTail = Int.max % SourceBlob.chunkSize
    #expect(try SourceBlob.verifiedByteCount(chunkCount: 0, finalChunkSize: 0) == 0)
    #expect(try SourceBlob.verifiedByteCount(chunkCount: largestFullChunkCount + 1, finalChunkSize: largestTail) == Int.max)
    #expect(throws: ProjectOperationError.invalid("The original source is too large.")) {
        try SourceBlob.verifiedByteCount(chunkCount: largestFullChunkCount + 1, finalChunkSize: largestTail + 1)
    }
    #expect(throws: ProjectOperationError.invalid("The original source is too large.")) {
        try SourceBlob.verifiedByteCount(chunkCount: largestFullChunkCount + 2, finalChunkSize: 1)
    }
}
