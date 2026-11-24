import Foundation
import Testing
@testable import MetaBrainCore

@Test func citationGraphStaysSymmetricAcrossRepeatedWritesMovesAndReopen() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let native = try await store.putDocument(DocumentInput(
            path: DocumentPath("/Native.md"), body: "The native reference. ^home"
        ))
        let targetPath = try DocumentPath("/notes/near/Policy.md")
        let target = try await store.putDocument(DocumentInput(path: targetPath, body: "Old policy. ^rule"))
        let alternate = try await store.putDocument(DocumentInput(
            path: DocumentPath("/other/Policy.md"), body: "Alternate policy. ^rule"
        ))
        let first = "[one](near/Policy.md#^rule)"
        let second = "[two](near/Policy.md#^rule)"
        let choice = "[[Policy#^rule|choice]]"
        let nativeCitation = "[[Native#^home|native]]"
        let remaining = "[[Next#^next|next]] \(nativeCitation) [[#^local|self]]\n\nPremise. ^local"
        let sourcePath = try DocumentPath("/notes/decision.md")
        var source = try await store.putDocument(DocumentInput(
            path: sourcePath, body: [first, second, choice, remaining].joined(separator: " "),
            references: [.documentID(native.id)]
        ))
        let sourceRef = DocumentReference.documentID(source.id)
        var nodes = [target.id, alternate.id]
        var graph = try await citationLifecycleGraph(store, source: source, nativeID: native.id, nodes: nodes)
        try #require(graph.count == 6)
        #expect(graph.map(\.status) == [.resolved, .resolved, .ambiguous, .unresolved, .resolved, .resolved])
        #expect(graph.map(\.targetID) == [target.id, target.id, nil, nil, native.id, source.id])
        #expect(Set(graph[2].candidates.map(\.documentID)) == Set([target.id, alternate.id]))

        let future = try await store.putDocument(DocumentInput(
            path: DocumentPath("/future/Next.md"), body: "This appeared later. ^next"
        ))
        nodes.append(future.id)
        _ = try await store.moveDocument(.documentID(alternate.id), to: DocumentPath("/other/Renamed.md"))
        graph = try await citationLifecycleGraph(store, source: source, nativeID: native.id, nodes: nodes)
        #expect(graph.map(\.targetID) == [target.id, target.id, target.id, future.id, native.id, source.id])
        #expect(graph.allSatisfy { $0.status == .resolved && $0.candidates.isEmpty })

        let decoy = try await store.putDocument(DocumentInput(
            path: DocumentPath("/moved/near/Policy.md"), body: "A different relative target. ^rule"
        ))
        nodes.append(decoy.id)
        let movedPath = try DocumentPath("/moved/decision.md")
        source = try await store.moveDocument(sourceRef, to: movedPath).document
        graph = try await citationLifecycleGraph(store, source: source, nativeID: native.id, nodes: nodes)
        #expect(graph.prefix(3).allSatisfy { $0.targetID == target.id && $0.targetPath == targetPath })
        #expect(try await store.links(for: .documentID(decoy.id), direction: .incoming).isEmpty)

        for (body, expected) in [
            ("Rule removed.", DocumentLinkStatus.unresolved),
            ("Rule duplicate one. ^rule\n\nRule duplicate two. ^rule", .ambiguous),
            ("Rule restored. ^rule", .resolved)
        ] {
            _ = try await store.putDocument(DocumentInput(path: targetPath, body: body))
            graph = try await citationLifecycleGraph(store, source: source, nativeID: native.id, nodes: nodes)
            #expect(graph.prefix(3).allSatisfy { $0.targetID == target.id && $0.status == expected })
        }

        let revised = "Reordered: \(second); \(choice); \(remaining)"
        source = try await store.writeDocument(DocumentInput(path: movedPath, body: revised), bodyOnly: true).document
        graph = try await citationLifecycleGraph(store, source: source, nativeID: native.id, nodes: nodes)
        #expect(graph.map(\.label) == ["two", "choice", "next", "native", "self"])
        #expect(graph.prefix(2).allSatisfy { $0.targetID == target.id && $0.status == .resolved })
        #expect(try await store.deleteDocument(.documentID(target.id)))
        let replacement = try await store.putDocument(DocumentInput(path: targetPath, body: "A newly created policy. ^rule"))
        nodes.append(replacement.id)
        graph = try await citationLifecycleGraph(store, source: source, nativeID: native.id, nodes: nodes)
        #expect(graph.prefix(2).allSatisfy { $0.targetID == nil && $0.status == .unresolved })

        await store.close()
        let reopened = try MetaBrainStore(url: fixture.storeURL)
        #expect(try await citationLifecycleGraph(reopened, source: source, nativeID: native.id, nodes: nodes) == graph)
        source = try await reopened.writeDocument(DocumentInput(path: movedPath, body: "Again: " + revised), bodyOnly: true).document
        graph = try await citationLifecycleGraph(reopened, source: source, nativeID: native.id, nodes: nodes)
        #expect(graph.prefix(2).allSatisfy { $0.targetID == nil && $0.status == .unresolved })

        let withoutNativeCitation = remaining.replacingOccurrences(of: nativeCitation + " ", with: "")
        source = try await reopened.writeDocument(DocumentInput(path: movedPath, body: withoutNativeCitation), bodyOnly: true).document
        graph = try await citationLifecycleGraph(reopened, source: source, nativeID: native.id, nodes: nodes)
        #expect(graph.map(\.label) == ["next", "self"])
        source = try await reopened.moveDocument(sourceRef, to: sourcePath).document
        let reintroduced = [first, choice, remaining].joined(separator: " ")
        source = try await reopened.writeDocument(DocumentInput(path: source.path, body: reintroduced), bodyOnly: true).document
        graph = try await citationLifecycleGraph(reopened, source: source, nativeID: native.id, nodes: nodes)
        try #require(graph.count == 5)
        #expect(graph.prefix(2).map(\.status) == [.resolved, .ambiguous])
        #expect(graph.first?.targetID == replacement.id)
        #expect(Set(graph[1].candidates.map(\.documentID)) == Set([decoy.id, replacement.id]))
        #expect(try await reopened.deleteDocument(.documentID(decoy.id)))
        graph = try await citationLifecycleGraph(reopened, source: source, nativeID: native.id, nodes: nodes)
        #expect(graph.prefix(2).allSatisfy { $0.targetID == replacement.id && $0.status == .resolved })

        #expect(try await reopened.deleteDocument(sourceRef))
        #expect(try await reopened.links(for: sourceRef).isEmpty)
        #expect(try await reopened.outboundReferences(from: source.id).isEmpty)
        for node in nodes + [source.id, native.id] {
            #expect(try await reopened.links(for: .documentID(node), direction: .incoming).isEmpty)
            #expect(try await reopened.inboundReferences(to: node).isEmpty)
        }
    }
}

@Test func citationRebindingDoesNotTurnAnExternalDestinationIntoALocalReference() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let note = try await store.putDocument(DocumentInput(path: DocumentPath("/notes/https:work.md"), body: "Local."))
        let path = try DocumentPath("/notes/source.md")
        let body = "[local](https%3Awork.md) [external](https:work.md)"
        let source = try await store.putDocument(DocumentInput(path: path, body: body))
        let reference = DocumentReference.documentID(source.id)
        let initial = try await store.links(for: reference)
        #expect(initial.map(\.status) == [.resolved, .external])
        #expect(initial.map(\.targetID) == [note.id, nil])

        _ = try await store.writeDocument(DocumentInput(path: path, body: "Updated: " + body), bodyOnly: true)
        _ = try await store.moveDocument(reference, to: DocumentPath("/moved/source.md"))
        let updated = try await store.links(for: reference)
        #expect(updated.map(\.status) == [.resolved, .external])
        #expect(updated.map(\.targetID) == [note.id, nil])
        #expect(try await store.links(for: .documentID(note.id), direction: .incoming) == Array(updated.prefix(1)))
    }
}

@Test func citationSchemesRequireASCIIAndAValidFirstCharacter() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let names = ["2notes:report.md", "n_otes:report.md", "nötés:report.md"]
        var ids: [DocumentID] = []
        for name in names {
            let document = try await store.putDocument(DocumentInput(path: DocumentPath("/notes/" + name), body: "Local."))
            ids.append(document.id)
        }
        let body = (names + ["https+notes-1.0:report.md"]).map { "[report](\($0))" }.joined(separator: " ")
        let source = try await store.putDocument(DocumentInput(path: DocumentPath("/notes/source.md"), body: body))
        let links = try await store.links(for: .documentID(source.id))
        #expect(links.map(\.status) == [.resolved, .resolved, .resolved, .external])
        #expect(links.map(\.targetID) == ids.map(Optional.some) + [nil])
    }
}

@Test func repeatedCitationsPreserveSeparateTargetGenerations() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let policyPath = try DocumentPath("/Policy.md")
        let original = try await store.putDocument(DocumentInput(path: policyPath, body: "Original. ^rule"))
        let sourcePath = try DocumentPath("/notes/source.md")
        let originalLink = "[[Policy#^rule|original]]"
        let source = try await store.putDocument(DocumentInput(path: sourcePath, body: originalLink))
        let sourceRef = DocumentReference.documentID(source.id)
        let originalRef = DocumentReference.documentID(original.id)
        _ = try await store.moveDocument(originalRef, to: DocumentPath("/archive/old"))
        let pendingLink = "[[Policy#^rule|pending]]"
        _ = try await store.writeDocument(DocumentInput(path: sourcePath, body: pendingLink + " " + originalLink))
        #expect(try await store.links(for: sourceRef).map(\.targetID) == [nil, original.id])

        let replacement = try await store.putDocument(DocumentInput(
            path: policyPath, body: "Replacement. ^rule\n\nCurrent details. ^current"
        ))
        let replacementRef = DocumentReference.documentID(replacement.id)
        let appended = originalLink + " [[Policy#^rule|replacement]] " + pendingLink
        _ = try await store.writeDocument(DocumentInput(path: sourcePath, body: appended))
        var links = try await store.links(for: sourceRef)
        #expect(links.map(\.status) == [.resolved, .resolved, .resolved])
        #expect(links.map(\.targetID) == [original.id, replacement.id, replacement.id])

        let replacementEdit = "[[Policy#^current|replacement]]"
        let originalEdit = "[[Policy#^rule|former]]"
        let edited = "Policy review:\n\n" + replacementEdit + " " + pendingLink + " " + originalEdit
        _ = try await store.writeDocument(DocumentInput(path: sourcePath, body: edited))
        links = try await store.links(for: sourceRef)
        #expect(links.map(\.label) == ["replacement", "pending", "former"])
        #expect(links.map(\.targetID) == [replacement.id, replacement.id, original.id])
        #expect(try await store.links(for: originalRef, direction: .incoming) == Array(links.suffix(1)))
        #expect(try await store.links(for: replacementRef, direction: .incoming) == Array(links.prefix(2)))

        #expect(try await store.deleteDocument(originalRef))
        _ = try await store.writeDocument(DocumentInput(path: sourcePath, body: edited + " " + originalEdit))
        links = try await store.links(for: sourceRef)
        #expect(links.map(\.status) == [.resolved, .resolved, .unresolved, .resolved])
        #expect(links.map(\.targetID) == [replacement.id, replacement.id, nil, replacement.id])
        #expect(try await store.links(for: replacementRef, direction: .incoming) == links.filter { $0.status == .resolved })

        // The two identical "former" occurrences keep their identities in body order.
        let repeated = originalEdit + " " + originalEdit + " " + replacementEdit + " " + pendingLink
        _ = try await store.writeDocument(DocumentInput(path: sourcePath, body: repeated))
        links = try await store.links(for: sourceRef)
        #expect(links.map(\.status) == [.unresolved, .resolved, .resolved, .resolved])
        #expect(links.map(\.targetID) == [nil, replacement.id, replacement.id, replacement.id])
        #expect(try await store.links(for: originalRef, direction: .incoming).isEmpty)
        #expect(try await store.links(for: replacementRef, direction: .incoming) == Array(links.dropFirst()))
    }
}

@Test(arguments: ["[[policy]]", "[[policy|Policy details]]"])
func namedBlocksKeepIdenticalCitationsBoundWhenParagraphsSwap(_ citation: String) async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let path = try DocumentPath("/policy.md")
        let original = try await store.putDocument(DocumentInput(path: path, body: "Original."))
        let first = citation + " ^old"
        let second = citation + " ^new"
        let source = try await store.putDocument(DocumentInput(path: DocumentPath("/notes.md"), body: first))
        _ = try await store.moveDocument(.documentID(original.id), to: DocumentPath("/archive/policy-old.md"))
        let replacement = try await store.putDocument(DocumentInput(path: path, body: "Replacement."))
        _ = try await store.putDocument(DocumentInput(path: source.path, body: first + "\n\n" + second))
        _ = try await store.putDocument(DocumentInput(path: source.path, body: second + "\n\n" + first))
        let links = try await store.links(for: .documentID(source.id))
        #expect(links.map(\.sourceBlock) == ["new", "old"])
        #expect(links.map(\.targetID) == [replacement.id, original.id])
    }
}

private func citationLifecycleGraph(
    _ store: MetaBrainStore,
    source: StoredDocument,
    nativeID: DocumentID,
    nodes: [DocumentID]
) async throws -> [DocumentLinkOccurrence] {
    let outgoing = try await store.links(for: .documentID(source.id))
    let characters = Array(source.body)
    let offsets = outgoing.map(\.start)
    #expect(offsets == offsets.sorted())
    #expect(Set(offsets).count == outgoing.count)
    for occurrence in outgoing {
        #expect(occurrence.sourceID == source.id)
        #expect(occurrence.sourcePath == source.path)
        #expect(occurrence.sourceVersion == source.currentVersion)
        try #require(occurrence.start >= 0 && occurrence.start < occurrence.end && occurrence.end <= characters.count)
        #expect(String(characters[occurrence.start..<occurrence.end]).contains(occurrence.destination))
    }

    let documentTargets = Set(outgoing.compactMap(\.targetID)).union([nativeID])
    #expect(try await store.outboundReferences(from: source.id) == documentTargets.sorted())
    for node in Set(nodes + [source.id, nativeID]).sorted() {
        let expected = outgoing.filter { $0.targetID == node }
        #expect(try await store.links(for: .documentID(node), direction: .incoming) == expected)
        #expect(try await store.inboundReferences(to: node) == (documentTargets.contains(node) ? [source.id] : []))
    }
    return outgoing
}
