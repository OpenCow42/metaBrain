import Foundation
import Testing
@testable import MetaBrainCore

@Test func projectOperationRejectsReplacementStoreAtSamePath() async throws {
    try await withTemporaryStoreFixture { fixture in
        let original = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let path = try DocumentPath("/atlas/proposed.md")
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: path, body: "Decision")
        ])
        let preview = try await original.inspectOperation(operation)
        await original.close()
        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.inspectOperation(operation) == preview)
        await reopened.close()
        try FileManager.default.removeItem(at: fixture.storeURL)

        let replacement = try MetaBrainStore(url: fixture.storeURL)
        let replacementPreview = try await replacement.inspectOperation(operation)
        #expect(replacementPreview.storePath == preview.storePath)
        #expect(replacementPreview.targets == preview.targets)
        #expect(replacementPreview.storeIdentity != preview.storeIdentity)
        await #expect(throws: ProjectOperationError.conflict("The preview identifies a different store.")) {
            try await replacement.applyOperation(preview)
        }
        #expect(try await replacement.getDocument(.path(path), trackingRead: false) == nil)
        #expect(try await replacement.applyOperation(replacementPreview).results.first?.status == .created)
    }
}

@Test(arguments: ["invalid UUID", "directory"])
func projectOperationIdentityFailureKeepsOrdinaryReadsAvailable(_ failure: String) async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let existing = try DocumentPath("/atlas/existing.md")
        let proposed = try DocumentPath("/atlas/proposed.md")
        let document = try await store.putDocument(DocumentInput(path: existing, body: "Retained"))
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: proposed, body: "Pending")
        ])
        let preview = try await store.inspectOperation(operation)
        await store.close()

        let identityURL = fixture.storeURL.appendingPathComponent("metabrain-identity")
        let originalIdentity = try Data(contentsOf: identityURL)
        if failure == "invalid UUID" {
            try Data("invalid".utf8).write(to: identityURL)
        } else {
            try FileManager.default.removeItem(at: identityURL)
            try FileManager.default.createDirectory(at: identityURL, withIntermediateDirectories: false)
        }

        let damaged = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await damaged.getDocument(.path(existing), trackingRead: false) == document)
        let expectedMessage = failure == "invalid UUID"
            ? "Invalid project operation store identity."
            : "Unable to read project operation store identity:"
        await #expect {
            try await damaged.inspectOperation(operation)
        } throws: { error in
            guard let failure = error as? MetaBrainStoreError, case .operationFailed(let message) = failure else { return false }
            return message.hasPrefix(expectedMessage)
        }
        await #expect {
            try await damaged.applyOperation(preview)
        } throws: { error in
            guard let failure = error as? MetaBrainStoreError, case .operationFailed(let message) = failure else { return false }
            return message.hasPrefix(expectedMessage)
        }
        #expect(try await damaged.getDocument(.path(proposed), trackingRead: false) == nil)
        await damaged.close()

        try FileManager.default.removeItem(at: identityURL)
        try originalIdentity.write(to: identityURL)
        let repaired = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await repaired.applyOperation(preview).results.first?.status == .created)
    }
}
