import Foundation
import Testing
@testable import MetaBrainCore

@Test func canvasPreviewPreservesStackingOrderAndResolvesPortableFileNodes() throws {
    let body = #"""
    {
      "nodes": [
        {"id":"group","type":"group","x":-20,"y":-10,"width":500,"height":300,"label":"Review","background":"images/bg.png","backgroundStyle":"cover"},
        {"id":"text","type":"text","x":0,"y":0,"width":100,"height":40,"text":"# Plan","color":"1","extra":{"nested":true}},
        {"id":"file","type":"file","x":120,"y":0,"width":100,"height":40,"file":"reviews/#notes.md","subpath":"#^result"},
        {"id":"link","type":"link","x":240,"y":0,"width":100,"height":40,"url":"https://example.test"}
      ],
      "edges": [{"id":"evidence","fromNode":"file","fromSide":"left","fromEnd":"none","toNode":"text","toSide":"right","toEnd":"arrow","label":"supports","color":"4"}],
      "extension":{"key":[1,2]}
    }
    """#
    let project = try DocumentPath("/wiki")
    let board = try WikiPreview.canvas(body: body, project: project)
    #expect(board.nodes.map(\.type) == [.group, .text, .file, .link])
    #expect(board.nodes.first?.x == -20)
    #expect(board.nodes.first?.label == "Review")
    #expect(board.nodes.first?.background == "images/bg.png")
    #expect(board.nodes.first?.backgroundStyle == "cover")
    #expect(board.nodes[1].text == "# Plan")
    #expect(board.nodes[1].color == "1")
    #expect(board.nodes[2].filePath?.rawValue == "/wiki/reviews/#notes.md")
    #expect(board.nodes[2].subpath == "#^result")
    #expect(board.nodes[3].url == "https://example.test")
    #expect(board.edges.first?.label == "supports")
    #expect(board.edges.first?.fromNode == "file")
    #expect(board.edges.first?.toNode == "text")
    #expect(board.edges.first?.fromSide == "left")
    #expect(board.edges.first?.fromEnd == "none")
    #expect(board.edges.first?.toSide == "right")
    #expect(board.edges.first?.toEnd == "arrow")
    #expect(board.edges.first?.color == "4")
    let preview = try JSONEncoder().encode(board)
    #expect(!String(decoding: preview, as: UTF8.self).contains("extension"))
    #expect(body.contains(#""extra":{"nested":true}"#))

    let rootBoard = try WikiPreview.canvas(body: body, project: DocumentPath("/"))
    #expect(rootBoard.nodes[2].filePath?.rawValue == "/reviews/#notes.md")
    let decoded = try JSONDecoder().decode(WikiCanvas.self, from: Data(body.utf8))
    #expect(decoded.nodes[2].filePath?.rawValue == "/reviews/#notes.md")
    let empty = try WikiPreview.canvas(body: "{}", project: project)
    #expect(empty.nodes.isEmpty)
    #expect(empty.edges.isEmpty)
}

@Test func canvasPreviewRejectsMalformedOrEscapingBoards() throws {
    let project = try DocumentPath("/wiki")
    func validate(_ body: String) throws -> WikiCanvas {
        try WikiPreview.canvas(body: body, project: project)
    }
    let group = #"{"id":"node","type":"group","x":0,"y":0,"width":1,"height":1}"#
    let edge = #"{"id":"edge","fromNode":"node","toNode":"node"}"#
    let duplicateNodes = #"{"nodes":[\#(group),\#(group)]}"#
    let duplicateEdges = #"{"nodes":[\#(group)],"edges":[\#(edge),\#(edge)]}"#
    let danglingEdge = #"{"edges":[\#(edge)]}"#
    let outsideBackground = #"{"nodes":[{"id":"g","type":"group","background":"../outside.png","x":0,"y":0,"width":1,"height":1}]}"#
    let emptyID = group.replacingOccurrences(of: #""node""#, with: #""""#)
    let emptyEdgeID = edge.replacingOccurrences(of: #""edge""#, with: #""""#)
    let zeroWidth = group.replacingOccurrences(of: #""width":1"#, with: #""width":0"#)
    let subpixel = group.replacingOccurrences(of: #""x":0"#, with: #""x":0.5"#)
    let badSubpath = #"{"id":"f","type":"file","file":"inside.md","subpath":"heading","x":0,"y":0,"width":1,"height":1}"#
    for (body, message) in [
        (duplicateNodes, "node IDs must be unique"),
        (duplicateEdges, "edge IDs must be unique"),
        (danglingEdge, "missing node"),
        (outsideBackground, "project-relative path"),
        (#"{"nodes":[\#(emptyID)]}"#, "node IDs cannot be empty"),
        (#"{"nodes":[\#(group)],"edges":[\#(emptyEdgeID)]}"#, "edge IDs cannot be empty"),
        (#"{"nodes":[\#(zeroWidth)]}"#, "positive width and height"),
        (#"{"nodes":[\#(badSubpath)]}"#, "subpath must start")
    ] {
        #expect(throws: WikiPreviewError.self) {
            do {
                _ = try validate(body)
            } catch {
                #expect(error.localizedDescription.contains(message))
                throw error
            }
        }
    }
    for body in ["[", "[]", #"{"nodes":null}"#, #"{"nodes":[\#(subpixel)]}"#,
                 #"{"nodes":[{"id":"text","type":"text","x":0,"y":0,"width":1,"height":1}]}"#] {
        #expect(throws: DecodingError.self) { try validate(body) }
    }
    for unsafe in ["", "/outside.md", "../outside.md", "inside/../../outside.md", "inside//name.md",
                   "inside/./name.md", "C:/name.md", "C:\\name.md", "https://example.test", "trimmed.md ", "null\u{0}.md"] {
        let file = String(decoding: try JSONEncoder().encode(unsafe), as: UTF8.self)
        let body = #"{"nodes":[{"id":"f","type":"file","file":\#(file),"x":0,"y":0,"width":1,"height":1}]}"#
        #expect(throws: WikiPreviewError.self) { try validate(body) }
    }
}

@Test func basePreviewCombinesFiltersAndProjectsSharedMarkdownProperties() throws {
    let body = #"""
    filters:
      and:
        - 'file.inFolder("reviews")'
        - 'file.hasTag("#Decision")'
    views:
      - type: table
        name: Ready decisions
        order: [file.name, note.Status, owners, absent, file.folder, file.path, file.ext, file.title, file.tags]
        limit: 1
        filters:
          and:
            - 'note.status == "ready"'
            - or:
                - "approved == true"
                - "priority == -2.5"
            - not:
                - "file.hasTag('blocked')"
                - 'status == "rejected"'
      - type: table
        name: All decisions
        order: [file.name]
      - type: table
        limit: 0
      - type: table
        name: Matching apostrophe
        filters: "owner == 'O\\'Reilly'"
      - type: table
        name: Matching escaped string
        filters: >-
          comment == 'A "quoted" line\n'
      - type: table
        name: Matching project folder
        filters: 'file.inFolder("")'
    """#
    let project = try DocumentPath("/wiki")
    let yaml = "---\nstatus: pending\ntags: [decision/offline, extra]\nowners: [A, B]\napproved: true\n---\n"
    let documents = try [
        WikiPreviewDocument(path: DocumentPath("/wiki/reviews/z.md"), body: yaml, metadata: ["status": "ready"]),
        WikiPreviewDocument(
            path: DocumentPath("/wiki/reviews/nested/a.md"), title: "A", body: yaml,
            tags: ["explicit", "extra"],
            metadata: ["STATUS": "READY", "owner": "O'Reilly", "comment": "A \"quoted\" line\n"]
        ),
        WikiPreviewDocument(path: DocumentPath("/wiki/reviews/blocked.md"), body: yaml, tags: ["blocked"],
                            metadata: ["status": "ready"]),
        WikiPreviewDocument(path: DocumentPath("/wiki/reviews/pending.md"), body: yaml),
        WikiPreviewDocument(path: DocumentPath("/wiki/reviews/prioritized"), body: yaml,
                            metadata: ["status": "ready", "approved": "false", "priority": "-2.5"], markdown: true),
        WikiPreviewDocument(path: DocumentPath("/wiki/reviews/plain"), body: yaml),
        WikiPreviewDocument(path: DocumentPath("/wiki/reviews-archive/old.md"), body: yaml),
        WikiPreviewDocument(path: DocumentPath("/wiki-other/reviews/outside.md"), body: yaml),
        WikiPreviewDocument(path: DocumentPath("/wiki"), body: yaml)
    ]
    let views = try WikiPreview.base(body: body, project: project).preview(documents: documents)
    #expect(views.map(\.name) == [
        "Ready decisions", "All decisions", "Table", "Matching apostrophe", "Matching escaped string", "Matching project folder"
    ])
    #expect(views[0].columns == [
        "file.name", "note.Status", "owners", "absent", "file.folder", "file.path", "file.ext", "file.title", "file.tags"
    ])
    #expect(views[0].rows.map(\.path.rawValue) == ["/wiki/reviews/nested/a.md"])
    #expect(views[0].rows.map(\.cells) == [
        ["a.md", "READY", "A, B", nil, "reviews/nested", "reviews/nested/a.md", "md", "A", "decision/offline, explicit, extra"]
    ])
    #expect(views[1].rows.map(\.cells) == [["blocked.md"], ["a.md"], ["pending.md"], ["prioritized"], ["z.md"]])
    #expect(views[2].columns == ["file.name"])
    #expect(views[2].rows.isEmpty)
    #expect(views[3].rows.map(\.cells) == [["a.md"]])
    #expect(views[4].rows.map(\.cells) == [["a.md"]])
    #expect(views[5].rows.map(\.path) == views[1].rows.map(\.path))

    let rootTable = try WikiPreview.base(
        body: "views: [{type: table, order: [file.folder, file.path]}]", project: DocumentPath("/")
    )
    let rootDocument = try WikiPreviewDocument(path: DocumentPath("/root.md"), body: "")
    #expect(rootTable.preview(documents: [rootDocument]).first?.rows.first?.cells == ["", "root.md"])
    #expect(try JSONEncoder().encode(views).count > 0)
}

@Test func basePreviewValidatesEveryFilterBeforeEvaluatingAnyRows() throws {
    let project = try DocumentPath("/wiki")
    let unsupported = #"""
    filters: {or: ['file.hasTag("decision")', 'formula.status == "ready"']}
    views: [{type: table, limit: 0}]
    """#
    let nested = #"""
    filters: 'status == "none"'
    views:
      - type: table
        limit: 0
      - type: table
        filters:
          not:
            - 'file.hasLink("external")'
    """#
    for (body, diagnostic) in [
        (unsupported, "formula.status"),
        (nested, "file.hasLink"),
        ("views: table", "requires a YAML mapping"),
        ("views: [{type: calendar}]", "Only table"),
        ("views: [{type: table, order: file.name}]", "requires an order list"),
        ("views: [{type: table, order: [file.size]}]", "unsupported column"),
        ("views: [{type: table, limit: -1}]", "nonnegative integer"),
        ("views: [{type: table, filters: {xor: []}}]", "filter operator 'xor'"),
        ("views: [{type: table, filters: [bad]}]", "Unsupported saved view filter"),
        (##"views: [{type: table, filters: 'file.hasTag("#")'}]"##, "Expected a tag"),
        (#"views: [{type: table, filters: 'file.inFolder("../outside")'}]"#, "project-relative path"),
        (#"views: [{type: table, filters: 'status == "\q"'}]"#, "Unsupported string literal"),
        (#"views: [{type: table, filters: 'this.file.name == "x"'}]"#, "Unsupported saved view filter")
    ] {
        #expect(throws: WikiPreviewError.self) {
            do {
                _ = try WikiPreview.base(body: body, project: project)
            } catch {
                #expect(error.localizedDescription.contains(diagnostic))
                throw error
            }
        }
    }
    #expect(throws: (any Error).self) {
        try WikiPreview.base(body: "[invalid yaml", project: project)
    }
}
