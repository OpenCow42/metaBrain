enum MetaBrainAgentGuide {
    static let document = DocumentInput(
        path: try! DocumentPath("/AGENTS.md"),
        title: "Working with metaBrain",
        body: """
        # Working with metaBrain

        Search before writing. Use `mb search "release decision"` or `mb tree --max-depth 2` to find related notes. Read the relevant entries with `mb get` and update an existing note when the evidence changes.

        Prefer Markdown for prose and use descriptive virtual paths such as `/notes/release.md`. Record durable findings, their date and sources, and enough context to verify them. Reuse tags and metadata keys that help you retrieve related work. Keep credentials and transient logs out of the store.

        ```sh
        mb put /notes/release.md --body-file release.md --tag release --meta date=2026-01-15
        mb search "release decision" --tag release
        mb get /notes/release.md
        ```

        Use descriptive Markdown links such as `[Release notes](/notes/release.md)` in the body. Add an indexed reference with `--ref-id` for relationships that should survive a move. Get the stable `documentID` from `mb get`. Use `--ref-path` for a relationship to a location and `--ref-url` for an external source. Indexed document references support backlinks. Markdown links by themselves are body text.

        ```sh
        mb put /notes/follow-up.md --body-file follow-up.md --tag release --ref-path /notes/release.md
        ```

        Use `mb patch` for focused Markdown edits. It creates a new version and carries forward the document's tags, metadata, and references.

        ```sh
        mb patch /notes/release.md --patch-file change.diff --check
        mb patch /notes/release.md --patch-file change.diff
        ```
        """ + "\n"
    )
}
