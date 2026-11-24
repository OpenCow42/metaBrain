import Foundation
import Testing
@testable import MetaBrainCore

@Test func additiveCreationListKeepsExistingPreviewsUsableAndRejectsAlteredIDs() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/atlas/new")
        let operation = ProjectOperation(operationID: UUID(), project: try DocumentPath("/atlas"),
                                         documents: [DocumentInput(path: path, body: "Created")])
        #expect(UUID(uuidString: operation.creationID(for: path).rawValue) != nil)
        let preview = try await store.inspectOperation(operation)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
        json["creations"] = [["path": ["rawValue": path.rawValue], "documentID": ["rawValue": "another-id"]]]
        func decode(_ json: [String: Any]) throws -> OperationPreview {
            try JSONDecoder().decode(OperationPreview.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let changed = try decode(json)
        await #expect(throws: ProjectOperationError.invalid("The operation differs from the inspected preview.")) {
            try await store.applyOperation(changed)
        }
        json.removeValue(forKey: "creations")
        let older = try decode(json)
        let receipt = try await store.applyOperation(older)
        #expect(receipt.results.first?.documentID == operation.creationID(for: path))
        #expect(try await store.applyOperation(preview) == receipt)
    }
}

@Test func claimFreshnessMatchesWireTimestampPrecision() {
    let deadline = Date(timeIntervalSince1970: 1_900_000_000.875)
    let profile = ClaimSourceProfile(status: .active, synthetic: false, independenceGroup: "research", freshUntil: deadline)
    #expect(profile.freshUntil == Date(timeIntervalSince1970: 1_900_000_000))
}
