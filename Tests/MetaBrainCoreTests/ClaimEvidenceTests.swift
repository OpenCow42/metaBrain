import Foundation
import Testing
@testable import MetaBrainCore

private let freshClaimDate = Date(timeIntervalSince1970: 4_102_444_800)

private func activeClaimSource(_ group: String) -> ClaimSourceProfile {
    ClaimSourceProfile(status: .active, synthetic: false, independenceGroup: group, freshUntil: freshClaimDate)
}

@Test func claimCanCiteRetainedRevisionWrittenBeforeSourceAssessment() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/atlas/results.md")
        let body = "The test passed. ^result"
        let original = try await store.putDocument(DocumentInput(path: path, body: body))
        let ref = try EvidenceReference("\(original.id.rawValue)@1#^result")
        _ = try await store.putDocument(DocumentInput(path: path, body: body, sourceProfile: activeClaimSource("lab")))

        let operation = ProjectOperation(operationID: UUID(), project: try DocumentPath("/atlas"), documents: [
            DocumentInput(path: try DocumentPath("/atlas/summary.md"), body: "Results confirmed.", claims: [
                ProjectClaim(id: UUID(), text: "The test passed.", state: .accepted, evidence: [
                    ClaimEvidence(relation: .supports, ref: ref)
                ])
            ])
        ])
        let preview = try await store.inspectOperation(operation)
        #expect(try await store.applyOperation(preview).results.first?.status == .created)
    }
}

private func claimFileCapture(_ store: MetaBrainStore, text: String, origin: String) async throws -> SourceCapture {
    let chunk = try await store.stageSourceChunk(Data(text.utf8))
    let blob = try await store.finishSourceBlob(chunks: [chunk])
    return SourceCapture(blob: blob, filename: "review.txt", mediaType: "text/plain", origin: origin)
}

@Test func reviewedOperationKeepsOpposingExactEvidenceAfterReopenAndMove() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let first = try DocumentPath("/atlas/local.md")
        let second = try DocumentPath("/atlas/replicated.md")
        let owner = try DocumentPath("/atlas/decision")
        let firstQuote = "Prefer local storage to keep working offline."
        let secondQuote = "Require replication to survive machine loss."
        let originalFirst = try await claimFileCapture(store, text: firstQuote, origin: "Local review")
        let originalSecond = try await claimFileCapture(store, text: secondQuote, origin: "Replication review")
        let operationID = UUID()
        let firstInput = DocumentInput(
            path: first, body: firstQuote + " ^evidence", sourceCapture: originalFirst, sourceProfile: activeClaimSource("local")
        )
        let secondInput = DocumentInput(
            path: second, body: secondQuote + " ^evidence", sourceCapture: originalSecond, sourceProfile: activeClaimSource("server")
        )
        let draft = ProjectOperation(operationID: operationID, project: project, documents: [firstInput, secondInput])
        let firstID = draft.creationID(for: first)
        let secondID = draft.creationID(for: second)
        let firstRef = try EvidenceReference("\(firstID.rawValue)@1#^evidence")
        let secondRef = try EvidenceReference("\(secondID.rawValue)@1#^evidence")
        let claim = ProjectClaim(id: UUID(), text: "Local storage should be preferred.", state: .contested, evidence: [
            ClaimEvidence(relation: .supports, ref: firstRef),
            ClaimEvidence(relation: .contradicts, ref: secondRef)
        ])
        let operation = ProjectOperation(operationID: operationID, project: project, documents: [
            DocumentInput(path: owner, body: "The reviewers disagree.", claims: [claim]), firstInput, secondInput
        ])
        let preview = try await store.inspectOperation(operation)
        #expect(preview.creations?.first { $0.path == first }?.documentID == firstID)
        #expect(preview.creations?.first { $0.path == second }?.documentID == secondID)
        let receipt = try await store.applyOperation(preview)
        #expect(receipt.results.first { $0.path == first }?.documentID == firstID)
        #expect(receipt.results.first { $0.path == second }?.documentID == secondID)
        #expect(try await store.getDocument(.path(owner), trackingRead: false)?.claims == [claim])
        #expect(try await store.getEvidence(firstRef).items.first?.text == firstQuote)
        #expect(try await store.getEvidence(secondRef).items.first?.text == secondQuote)
        #expect(try await store.lint(DocumentLintQuery(path: project)).findings.isEmpty)
        await store.close()

        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await reopened.applyOperation(preview) == receipt)
        _ = try await reopened.putDocument(DocumentInput(path: first, body: "Recommendation updated. ^evidence"))
        let moved = try DocumentPath("/atlas/archive/local.md")
        _ = try await reopened.moveDocument(.path(first), to: moved)
        #expect(try await reopened.getDocument(.documentID(firstID), trackingRead: false)?.path == moved)
        let pinned = try await reopened.getEvidence(firstRef)
        #expect(pinned.items.first?.text == firstQuote)
        #expect(pinned.items.first?.path == first.rawValue)
        let lint = try await reopened.lint(DocumentLintQuery(path: project))
        #expect(lint.findings.contains {
            $0.kind == .claimEvidence && $0.claimID == claim.id && $0.evidenceIssue == .stale && $0.evidenceRef == firstRef
        })

        _ = try await reopened.putDocument(DocumentInput(path: owner, body: "Decision revised after the review."))
        #expect(try await reopened.getDocument(.path(owner), version: 1)?.claims == [claim])
        #expect(try await reopened.removeVersion(documentID: firstID, sequence: 1))
        await #expect(throws: MetaBrainStoreError.documentVersionNotFound(reference: firstRef.rawValue, version: 1)) {
            try await reopened.getEvidence(firstRef)
        }
        let afterPrune = try await reopened.lint(DocumentLintQuery(path: project))
        #expect(afterPrune.findings.contains {
            $0.kind == .claimEvidence && $0.claimID == claim.id && $0.evidenceIssue == .missing && $0.evidenceRef == firstRef
        })
        #expect(try await reopened.lint(DocumentLintQuery(path: project)) == afterPrune)
    }
}

@Test func highRiskClaimRequiresIndependentGroupsAndDistinctOriginals() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let paths = try ["first", "mirror", "related", "independent"].map { try DocumentPath("/atlas/" + $0 + ".md") }
        let original = try await claimFileCapture(store, text: "First experiment", origin: "Lab A")
        let other = try await claimFileCapture(store, text: "Second experiment", origin: "Lab B")
        let sources = [
            (original, "lab-a"), (original, "lab-mirror"), (other, "lab-a"), (other, "lab-b")
        ]
        var evidence: [ClaimEvidence] = []
        for (path, source) in zip(paths, sources) {
            let document = try await store.putDocument(DocumentInput(
                path: path, body: "The test passed. ^result", sourceCapture: source.0, sourceProfile: activeClaimSource(source.1)
            ))
            evidence.append(ClaimEvidence(relation: .supports, ref: try EvidenceReference("\(document.id.rawValue)@1#^result")))
        }
        let owner = try DocumentPath("/atlas/decision")
        let related = try DocumentPath("/atlas/summary")
        for index in [1, 2, 3] {
            let claim = ProjectClaim(
                id: UUID(), text: "Use the tested configuration.", state: .accepted, highRisk: true,
                evidence: [evidence[0], evidence[index]]
            )
            let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
                DocumentInput(path: related, body: "Summary"),
                DocumentInput(path: owner, body: "Decision", claims: [claim])
            ])
            if index == 3 {
                let preview = try await store.inspectOperation(operation)
                _ = try await store.applyOperation(preview)
                #expect(try await store.getDocument(.path(owner), trackingRead: false)?.claims == [claim])
            } else {
                await #expect(throws: (any Error).self) {
                    let preview = try await store.inspectOperation(operation)
                    _ = try await store.applyOperation(preview)
                }
                #expect(try await store.getDocument(.path(owner), trackingRead: false) == nil)
                #expect(try await store.getDocument(.path(related), trackingRead: false) == nil)
            }
        }
        _ = try await store.putDocument(DocumentInput(
            path: paths[1], body: "The test passed. ^result", sourceCapture: other, sourceProfile: activeClaimSource("lab-b")
        ))
        _ = try await store.putDocument(DocumentInput(
            path: paths[2], body: "The test passed. ^result", sourceProfile: activeClaimSource("lab-b")
        ))
        for index in [1, 2] {
            let claim = ProjectClaim(
                id: UUID(), text: "Use the tested configuration.", state: .accepted, highRisk: true,
                evidence: [evidence[0], evidence[index]]
            )
            let reassessed = ProjectOperation(operationID: UUID(), project: project, documents: [
                DocumentInput(path: owner, body: "Decision", claims: [claim])
            ])
            await #expect(throws: ProjectOperationError.invalid(
                "Claim \(claim.id) in \(owner): A high-risk claim requires two independent supporting sources."
            )) {
                try await store.inspectOperation(reassessed)
            }
        }
    }
}

@Test func acceptedClaimRejectsIneligibleSourcesAndUngroundedWrites() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let owner = try DocumentPath("/atlas/decision")
        let source = try DocumentPath("/atlas/source.md")
        let capture = try await claimFileCapture(store, text: "Primary material", origin: "Review A")
        let expired = Date(timeIntervalSince1970: 1)
        let profiles: [ClaimSourceProfile] = [
            ClaimSourceProfile(status: .disputed, synthetic: false, independenceGroup: "team", freshUntil: freshClaimDate),
            ClaimSourceProfile(status: .superseded, synthetic: false, independenceGroup: "team", freshUntil: freshClaimDate),
            ClaimSourceProfile(status: .active, synthetic: true, independenceGroup: "team", freshUntil: freshClaimDate),
            ClaimSourceProfile(status: .active, synthetic: false, independenceGroup: "team", freshUntil: expired),
            activeClaimSource("team")
        ]
        for (index, profile) in profiles.enumerated() {
            let document = try await store.putDocument(DocumentInput(
                path: source, body: "The result held. ^result", sourceCapture: capture, sourceProfile: profile
            ))
            let ref = try EvidenceReference("\(document.id.rawValue)@\(document.currentVersion)#^result")
            let claim = ProjectClaim(id: UUID(), text: "The result held.", state: .accepted, evidence: [
                ClaimEvidence(relation: .supports, ref: ref)
            ])
            let input = DocumentInput(path: owner, body: "Decision", claims: [claim])
            let operation = ProjectOperation(operationID: UUID(), project: project, documents: [input])
            if index == profiles.count - 1 {
                let preview = try await store.inspectOperation(operation)
                _ = try await store.applyOperation(preview)
                #expect(try await store.getDocument(.path(owner), trackingRead: false)?.claims == [claim])
            } else {
                await #expect(throws: (any Error).self) {
                    let preview = try await store.inspectOperation(operation)
                    _ = try await store.applyOperation(preview)
                }
                await #expect(throws: (any Error).self) { try await store.putDocument(input) }
                #expect(try await store.getDocument(.path(owner), trackingRead: false) == nil)
            }
        }
    }
}

@Test func operationAssessesEvidenceAfterSameBatchSourceUpdateAndRetention() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let source = try DocumentPath("/atlas/review.md")
        let owner = try DocumentPath("/atlas/decision")
        let capture = try await claimFileCapture(store, text: "Review", origin: "Reviewer")
        let initial = try await store.putDocument(DocumentInput(
            path: source, body: "Initially recommended. ^result", sourceCapture: capture, sourceProfile: activeClaimSource("team")
        ))
        let pinned = try EvidenceReference("\(initial.id.rawValue)@1#^result")
        let planned = try EvidenceReference("\(initial.id.rawValue)@2#^result")
        let replacement = DocumentInput(path: source, body: "Recommended after review. ^result", retention: .keepMostRecent(1))
        func operation(evidence: EvidenceReference) -> ProjectOperation {
            let claim = ProjectClaim(id: UUID(), text: "Follow the recommendation.", state: .accepted, evidence: [
                ClaimEvidence(relation: .supports, ref: evidence)
            ])
            return ProjectOperation(operationID: UUID(), project: project, documents: [
                DocumentInput(path: owner, body: "Decision", claims: [claim]), replacement
            ])
        }
        await #expect(throws: (any Error).self) {
            let preview = try await store.inspectOperation(operation(evidence: pinned))
            _ = try await store.applyOperation(preview)
        }
        #expect(try await store.getDocument(.path(source), trackingRead: false)?.currentVersion == 1)
        #expect(try await store.getDocument(.path(owner), trackingRead: false) == nil)

        let preview = try await store.inspectOperation(operation(evidence: planned))
        let receipt = try await store.applyOperation(preview)
        #expect(receipt.results.map(\.version) == [1, 2])
        #expect(try await store.getEvidence(planned).items.first?.text == "Recommended after review.")
        await #expect(throws: MetaBrainStoreError.documentVersionNotFound(reference: pinned.rawValue, version: 1)) {
            try await store.getEvidence(pinned)
        }
    }
}

@Test func exactClaimEvidenceRejectsWrongRevisionAndAmbiguousBlocks() throws {
    let id = try DocumentID(rawValue: "source")
    let path = try DocumentPath("/atlas/source.md")
    let body = "🧑‍🔬 e\u{301}vidence. ^result"
    var source = StoredDocument(
        id: id, path: path, body: body, currentVersion: 1,
        createdAt: freshClaimDate, updatedAt: freshClaimDate
    )
    let block = try EvidenceReference("source@1#^result")
    let range = try EvidenceReference("source@1#0-2")
    #expect(try block.exactText(in: source) == "🧑‍🔬 e\u{301}vidence.")
    #expect(try range.exactText(in: source) == "🧑‍🔬 ")
    let invalid = try EvidenceReference("source@1#0-999")
    #expect(throws: EvidenceError.invalidRange(invalid)) { try invalid.exactText(in: source) }
    let missing = try EvidenceReference("source@1#^missing")
    #expect(throws: EvidenceError.blockNotFound(missing)) { try missing.exactText(in: source) }

    source.body += "\n\nAnother paragraph. ^result"
    #expect(throws: DocumentPassageError.ambiguousSelector("result")) { try block.exactText(in: source) }

    source.currentVersion = 2
    #expect(throws: MetaBrainStoreError.documentVersionNotFound(reference: block.rawValue, version: 1)) {
        try block.exactText(in: source)
    }
}

@Test func claimLintReportsInvalidPinnedPassageInsteadOfCurrentReplacement() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let sourcePath = try DocumentPath("/atlas/review.md")
        let decision = try DocumentPath("/atlas/decision")
        let text = "Experiment supports this result."
        let source = try await store.putDocument(DocumentInput(
            path: sourcePath, body: text + " ^result", sourceProfile: activeClaimSource("lab")
        ))
        let pinned = try EvidenceReference("\(source.id.rawValue)@1#^result")
        let claim = ProjectClaim(id: UUID(), text: "The result held.", state: .provisional, evidence: [
            ClaimEvidence(relation: .supports, ref: pinned)
        ])
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: decision, body: "Decision", claims: [claim])
        ])
        let preview = try await store.inspectOperation(operation)
        _ = try await store.applyOperation(preview)
        let versions = try await store.listVersions(of: .path(sourcePath))
        var corrupt = try #require(versions.first)
        let versionKey = MetaBrainKeyspace.version(id: source.id, sequence: 1)
        for (body, message) in [
            ("Deleted anchor.", "missing or ambiguous"),
            ("First ^result\n\nSecond ^result", "More than one passage")
        ] {
            corrupt.snapshot.body = body
            try await store.putCompressedRecord(corrupt, forKey: versionKey)
            let report = try await store.lint(DocumentLintQuery(path: decision))
            let finding = try #require(report.findings.first)
            #expect(report.counts["claimEvidence"] == 1)
            #expect(finding.claimID == claim.id)
            #expect(finding.evidenceRef == pinned)
            #expect(finding.evidenceIssue == .invalid)
            #expect(finding.message?.localizedCaseInsensitiveContains(message) == true)
            await #expect(throws: (any Error).self) { try await store.getEvidence(pinned) }
        }
        #expect(try await store.getDocument(.path(sourcePath), trackingRead: false)?.body == text + " ^result")
    }
}

@Test func claimAssessmentDistinguishesWriteErrorsFromReviewFindings() async throws {
    let id = try DocumentID(rawValue: "source")
    let path = try DocumentPath("/atlas/source.md")
    let source = StoredDocument(
        id: id, path: path, body: "Observed. ^result", currentVersion: 1,
        createdAt: freshClaimDate, updatedAt: freshClaimDate, sourceProfile: activeClaimSource("Lab")
    )
    let ref = try EvidenceReference("source@1#^result")
    let support = ClaimEvidence(relation: .supports, ref: ref)
    let contradiction = ClaimEvidence(relation: .contradicts, ref: ref)
    let claim = ProjectClaim(id: UUID(), text: "It held.", state: .accepted, evidence: [support, contradiction])
    let at = Date(timeIntervalSince1970: 100)
    let contradictory = try await ClaimAssessment.evaluate(claim, asOf: at) { _ in (source, source) }
    #expect(contradictory.map(\.kind) == [.contradiction])
    #expect(contradictory.first?.isWriteError == true)
    #expect(contradictory.first?.ref == ref)
    #expect(contradiction.sourceID == id)

    let priorRef = try EvidenceReference("source@1#0-9")
    let currentRef = try EvidenceReference("source@2#^result")
    var modified = source
    modified.currentVersion = 2
    modified.body = "Updated result. ^result"
    let current = modified
    let supported = ProjectClaim(id: UUID(), text: "Prefer the updated result.", state: .accepted, evidence: [
        ClaimEvidence(relation: .supports, ref: priorRef),
        ClaimEvidence(relation: .supports, ref: currentRef)
    ])
    let withStale = try await ClaimAssessment.evaluate(supported, asOf: at) { ref in
        (ref.version == 1 ? source : current, current)
    }
    #expect(withStale.map(\.kind) == [.stale])
    #expect(withStale.first?.ref == priorRef)
    #expect(withStale.first?.isWriteError == false)

    let malformed = ProjectClaim(id: UUID(), text: " ", state: .provisional, evidence: [support, support])
    let invalid = try await ClaimAssessment.evaluate(malformed, asOf: at) { _ in (source, source) }
    #expect(invalid.map(\.kind) == [.invalid, .invalid])
    #expect(invalid.filter { !$0.isWriteError }.isEmpty)

    var unassessed = source
    unassessed.sourceProfile = nil
    let provisional = ProjectClaim(id: UUID(), text: "Wait for review.", state: .provisional, evidence: [support])
    let ineligible = try await ClaimAssessment.evaluate(provisional, asOf: at) { _ in (unassessed, unassessed) }
    #expect(ineligible.map(\.kind) == [.ineligible])
    #expect(ineligible.first?.isWriteError == false)

    let emptyRange = try EvidenceReference("source@1#0-0")
    let empty = ProjectClaim(id: UUID(), text: "Empty evidence.", state: .provisional, evidence: [
        ClaimEvidence(relation: .supports, ref: emptyRange)
    ])
    let noText = try await ClaimAssessment.evaluate(empty, asOf: at) { _ in (source, source) }
    #expect(noText.map(\.kind) == [.invalid])
    #expect(noText.first?.message == "The cited passage is empty.")

    for state in [ClaimState.unsupported, .deprecated] {
        let inactive = ProjectClaim(id: UUID(), text: "No longer relied on.", state: state, evidence: [])
        #expect(try await ClaimAssessment.evaluate(inactive, asOf: at) { _ in (nil, nil) }.isEmpty)
    }
}

@Test func oldNoteEncodingsDecodeWithoutClaimFields() throws {
    let inputData = Data(#"{"path":{"rawValue":"/older/note"},"body":"Historical text","tags":[],"metadata":{},"references":[]}"#.utf8)
    let input = try JSONDecoder().decode(DocumentInput.self, from: inputData)
    #expect(input.body == "Historical text")
    #expect(input.claims == nil)
    #expect(input.sourceProfile == nil)

    let storedData = Data(#"{"id":{"rawValue":"older"},"path":{"rawValue":"/older/note"},"body":"Historical text","tags":[],"metadata":{},"references":[],"currentVersion":1,"createdAt":0,"updatedAt":0}"#.utf8)
    let stored = try JSONDecoder().decode(StoredDocument.self, from: storedData)
    #expect(stored.claims == nil)
    #expect(stored.sourceProfile == nil)
}

@Test func operationRechecksUnchangedTargetsAgainstNewSourceStandingAtApply() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let sourcePath = try DocumentPath("/atlas/source.md")
        let owner = try DocumentPath("/atlas/decision")
        let navigation = try DocumentPath("/atlas/index")
        let source = try await store.putDocument(DocumentInput(
            path: sourcePath, body: "Observed result. ^result", sourceProfile: activeClaimSource("lab")
        ))
        let ref = try EvidenceReference("\(source.id.rawValue)@1#^result")
        let claim = ProjectClaim(id: UUID(), text: "Use this result.", state: .accepted, evidence: [
            ClaimEvidence(relation: .supports, ref: ref)
        ])
        let operation = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: navigation, body: "Navigation update"),
            DocumentInput(path: owner, body: "Decision", claims: [claim])
        ])
        let preview = try await store.inspectOperation(operation)
        let disputed = ClaimSourceProfile(status: .disputed, synthetic: false, independenceGroup: "lab", freshUntil: freshClaimDate)
        _ = try await store.putDocument(DocumentInput(path: sourcePath, body: source.body, sourceProfile: disputed))
        await #expect(throws: ProjectOperationError.invalid(
            "Claim \(claim.id) in \(owner): An accepted claim requires eligible supporting evidence."
        )) {
            try await store.applyOperation(preview)
        }
        #expect(try await store.getDocument(.path(owner), trackingRead: false) == nil)
        #expect(try await store.getDocument(.path(navigation), trackingRead: false) == nil)
        #expect(try await store.rawValue(forKey: MetaBrainKeyspace.operationReceipt(operation.operationID)) == nil)
    }
}

@Test func reviewedClaimsRequireUniqueIDsAndEvidenceWithinTheirProject() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let project = try DocumentPath("/atlas")
        let owner = try DocumentPath("/atlas/decision")
        let external = try DocumentPath("/other/source.md")
        let source = try await store.putDocument(DocumentInput(
            path: external, body: "Outside evidence. ^result", sourceProfile: activeClaimSource("lab")
        ))
        let ref = try EvidenceReference("\(source.id.rawValue)@1#^result")
        let outside = ProjectClaim(id: UUID(), text: "Potential conclusion.", state: .provisional, evidence: [
            ClaimEvidence(relation: .supports, ref: ref)
        ])
        let externalEvidence = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: owner, body: "Decision", claims: [outside])
        ])
        await #expect(throws: ProjectOperationError.invalid(
            "Claim \(outside.id) in \(owner): Source \(external) is outside reviewed project \(project)."
        )) {
            try await store.inspectOperation(externalEvidence)
        }

        let unsupported = ProjectClaim(id: UUID(), text: "Needs evidence.", state: .unsupported, evidence: [])
        let duplicate = ProjectOperation(operationID: UUID(), project: project, documents: [
            DocumentInput(path: owner, body: "Decision", claims: [unsupported, unsupported])
        ])
        await #expect(throws: ProjectOperationError.invalid("Duplicate claim ID \(unsupported.id) in \(owner).")) {
            try await store.inspectOperation(duplicate)
        }

        let invalid = ClaimSourceProfile(status: .active, synthetic: false, independenceGroup: " ", freshUntil: freshClaimDate)
        let profile = DocumentInput(path: owner, body: "Decision", sourceProfile: invalid)
        let unassessed = ProjectOperation(operationID: UUID(), project: project, documents: [profile])
        await #expect(throws: ProjectOperationError.invalid("A source assessment requires an independence group and freshness deadline.")) {
            try await store.inspectOperation(unassessed)
        }
        #expect(try await store.getDocument(.path(owner), trackingRead: false) == nil)
    }
}
