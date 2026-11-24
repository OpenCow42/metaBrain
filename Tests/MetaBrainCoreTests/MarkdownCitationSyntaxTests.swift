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
