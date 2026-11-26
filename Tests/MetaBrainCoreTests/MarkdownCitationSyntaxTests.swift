import Foundation
import Testing
@testable import MetaBrainCore

@Test func wikiPathsResolveToMarkdownHeadingsAndExternalLinksStayOutsideTheGraph() async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let target = try await store.putDocument(DocumentInput(
            path: DocumentPath("/shelf/Guide.md"),
            body: "Overview\n========\n\nDetails\n-------\n\nA rule.\n\n# Appendix ###\n\nExtra."
        ))
        let literal = try await store.putDocument(DocumentInput(path: DocumentPath("/shelf/hash#100%.md"), body: "Literal."))
        let source = try await store.putDocument(DocumentInput(
            path: DocumentPath("/notes/source.md"),
            body: """
            [[shelf/Guide#Overview]] [[shelf/Guide#Details]] [[shelf/Guide#Appendix]]
            [literal](../shelf/hash\\#100%.md) [remote](//host.example/a.md)
            """
        ))
        let links = try await store.links(for: .documentID(source.id))
        #expect(links.map(\.targetID) == [target.id, target.id, target.id, literal.id, nil])
        #expect(links.map(\.status) == [.resolved, .resolved, .resolved, .resolved, .external])
        #expect(try await store.links(for: .documentID(target.id), direction: .incoming) == Array(links.prefix(3)))
        let passage = try await store.readPassage(.documentID(target.id), selector: .heading("Details"))
        #expect(passage?.passage.text == "Details\n-------\n\nA rule.")
    }
}

@Test func markdownCitationSyntaxKeepsCodeSpansWithinTheirBlocks() {
    let body = """
    Before \u{60}[[before-title]]
    # Heading
    After \u{60}[[after-title]]

    First \u{60}[[hidden-one]]
    [[hidden-two]]\u{60}, then [[after-code]].

    \\\u{60}\u{60}[[inside-surviving-tick]]\u{60} [[after-escape]].

    Paragraph continues
        [retained](continued.md).

        [[indented-code]]

    > ~~~
    > [[quoted-fence]]
    > ~~~
    > [[after-quoted-fence]]

    > ~~~
    > [[unclosed-quoted-fence]]
    [[outside-quote]]
    """
    let parsed = MarkdownDocument(body: body)

    #expect(parsed.links.map(\.destination) == [
        "before-title", "after-title", "after-code", "after-escape",
        "continued.md", "after-quoted-fence", "outside-quote"
    ])
}

@Test func markdownCitationSyntaxMasksOnlyLiteralHTMLAndCommentRegions() {
    let body = """
    Heading prep <!--
    [[inside-comment]]
    ~~~
    --> [[after-comment]]

    Opening %% [[hidden-obsidian]]
    \u{60}\u{60}\u{60}
    %% [[after-obsidian]]

    Preceding \u{60}example
    %% [[inside-code]]
    \u{60} [[after-code]].

    <span title="[[attribute]]">[[span-content]]</span>
    <CoDe data-quote=">">[[raw-code]]</CODE > [[after-html]]
    \\<code>[[escaped-tag]]
    <code /> [[after-self-closing-tag]]
    <code ?invalid> [[after-invalid-tag]]
    [code destination](<code>) and [spaced path](<pre draft>).
    """
    let parsed = MarkdownDocument(body: body)

    #expect(parsed.links.map(\.destination) == [
        "after-comment", "after-obsidian", "after-code", "span-content", "after-html",
        "escaped-tag", "after-self-closing-tag", "after-invalid-tag", "code", "pre draft"
    ])
}

@Test func markdownCitationSyntaxValidatesDefinitionsWithoutMaskingProse() {
    let body = """
    [Use][valid] then [other][second] or [valid][].

    [valid]: <Primary title.md> "Link title"
    [second]: alternate.md 'Another title'

    [not-definition]: explanatory prose [retained](good.md)

    Paragraph remains open
    [mid-paragraph]: error.md

    [mid-paragraph] and [not-definition].

    [anchor-definition]: existing.md

    ^not-a-block
    """
    let parsed = MarkdownDocument(body: body)

    #expect(parsed.links.map(\.label) == ["Use", "other", "valid", "retained"])
    #expect(parsed.links.map(\.destination) == ["Primary title.md", "alternate.md", "Primary title.md", "good.md"])
    #expect(!parsed.anchors.contains { $0.selector == .block("not-a-block") })
}

@Test func markdownCitationSyntaxPreservesOffsetsForQuotedSyntaxAndUnicode() throws {
    let body = """
    👩🏽‍💻 Cafe\u{0301}: [escaped \\] label](<A b.md#head> "A title") and ![[Target|🧑‍🔬]].
    """
    let parsed = MarkdownDocument(body: body, includeLinks: true)
    let characters = Array(body)
    try #require(parsed.links.count == 2)
    let markdown = parsed.links[0]
    let wiki = parsed.links[1]
    #expect(String(characters[markdown.start..<markdown.end]) == #"[escaped \] label](<A b.md#head> "A title")"#)
    #expect(String(characters[wiki.start..<wiki.end]) == "![[Target|🧑‍🔬]]")
    #expect(markdown.start == "👩🏽‍💻 Cafe\u{0301}: ".count)
    #expect(markdown.destination == "A b.md#head")
    #expect(wiki.embed == true)
}

@Test(arguments: ["", "\n"])
func fencedSourceCitationReopensLiteralEvidence(separator: String) async throws {
    try await withTemporaryStoreFixture { fixture in
        let store = try MetaBrainStore(url: fixture.storeURL)
        let excerpt = "# Source 👩🏽‍💻\n[[fake.md]]\n^fake\n" + String(repeating: "\u{60}", count: 3) + "\n"
        let fence = String(repeating: "\u{60}", count: 5)
        let body = "## Lines 17–37\n\n\(fence)markdown\n\(excerpt)\(fence)\n\(separator)^original\n\nLive paragraph. ^paragraph"
        let bytes = Data(excerpt.utf8)
        let chunk = try await store.stageSourceChunk(bytes)
        let blob = try await store.finishSourceBlob(chunks: [chunk])
        let sourcePath = try DocumentPath("/project/source.md")
        let captured = try await store.putDocument(DocumentInput(
            path: sourcePath, body: body,
            sourceCapture: SourceCapture(blob: blob, filename: "README.md", mediaType: "text/markdown", origin: "Fixture")
        ))
        let source = DocumentReference.documentID(captured.id)
        let ref = try EvidenceReference("\(captured.id.rawValue)@1#^original")
        let notePath = try DocumentPath("/project/decision.md")
        let decision = try await store.putDocument(DocumentInput(
            path: notePath,
            body: "[Original](source.md#^original) [[source.md#^original]] [[/project/source.md#Lines 17–37]]\n[Retained](metabrain-ref:\(ref.rawValue))"
        ))
        let passage = try #require(try await store.readPassage(source, selector: .block("original")))
        #expect(passage.passage.text == excerpt)
        let chars = Array(body)
        #expect(String(chars[passage.passage.start..<passage.passage.end]) == excerpt)
        #expect(try await store.readPassage(source, selector: .block("fake")) == nil)
        #expect(try await store.readPassage(source, selector: .block("paragraph"))?.passage.text == "Live paragraph.")
        #expect(try await store.links(for: source).isEmpty)
        #expect(try await store.links(for: .documentID(decision.id)).prefix(3).map(\.status) == [.resolved, .resolved, .resolved])
        #expect(try await store.links(for: source, direction: .incoming, block: "original").count == 2)
        #expect(try await store.lint(DocumentLintQuery(path: DocumentPath("/project"))).findings.isEmpty)

        _ = try await store.moveDocument(source, to: DocumentPath("/project/moved.md"))
        _ = try await store.putDocument(DocumentInput(path: DocumentPath("/project/moved.md"), body: "New revision."))
        #expect(try await store.getEvidence(ref).items.first?.text == excerpt)
        #expect(try await store.getDocument(source, version: 1)?.sourceCapture?.blob.sha256 == blob.sha256)
        #expect(try await store.getDocument(source, version: 1)?.body == body)
    }
}

@Test func fencedSourceMarkersRequireAClosedFenceAndRespectDuplicateIDs() throws {
    let body = "~~~\nliteral\n~~~\n^duplicate\n\nParagraph ^duplicate\n\n~~~\nsecond\n~~~\n\nIntervening text\n^paragraph\n\n~~~\n^open"
    let parsed = MarkdownDocument(body: body)
    #expect(throws: DocumentPassageError.ambiguousSelector("duplicate")) {
        try parsed.anchor(for: .block("duplicate"))
    }
    let paragraph = try #require(try parsed.anchor(for: .block("paragraph")))
    #expect(String(Array(body)[paragraph.range]) == "Intervening text")
    #expect(try parsed.anchor(for: .block("open")) == nil)
}
