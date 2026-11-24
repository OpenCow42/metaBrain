enum MetaBrainAgentGuide {
    static let document = DocumentInput(
        path: try! DocumentPath("/AGENTS.md"),
        title: "Working with metaBrain",
        body: """
        # Working with metaBrain

        Search before writing. Use `mb recall "release decision" --tag release --max-bytes 4096` to find passages you can cite. Cite the path, version, and passage offsets from the result. Set `document_id` and `cited_version` from recall. Before editing, set `current_version` from the current `mb get` result.

        Prefer Markdown for prose and use descriptive virtual paths such as `/notes/release.md`. Record durable findings, their date and sources, and enough context to verify them. Reuse tags and metadata keys that help you retrieve related work. Keep credentials and transient logs out of the store.

        ```sh
        mb put /notes/release.md --body-file release.md --tag release --meta date=2026-01-15
        mb recall "release decision" --tag release --max-bytes 4096
        mb get --id "$document_id" --version "$cited_version"
        mb get /notes/release.md
        mb put /notes/release.md --body-file revised.md --body-only --if-version "$current_version"
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
