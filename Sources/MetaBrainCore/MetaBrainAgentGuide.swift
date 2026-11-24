enum MetaBrainAgentGuide {
    static let document = DocumentInput(
        path: try! DocumentPath("/AGENTS.md"),
        title: "Working with metaBrain",
        body: """
        # Working with metaBrain

        ## Find evidence with a small context budget

        Start with a scoped search. Use refs when choosing documents and evidence when answering a question. Each evidence item contains a verbatim passage and a reference to its stored revision.

        ```sh
        mb search --tag release --meta status=current --view refs --limit 5
        mb search "rollback trigger" --path-prefix /releases --view evidence --max-tokens 512
        mb get --ref "$ref" --context section --max-tokens 1024
        ```

        Copy a returned `ref` into the last command if you need the surrounding section. Read any conditions and exceptions before quoting. A `truncated` response means the limit or budget omitted material. Narrow the query, or increase the budget when you need more context. The budget covers the complete compact JSON response plus its newline. It conservatively counts one token per UTF-8 byte. `--limit` caps the number of distinct documents in these views.

        Use `mb recall "release decision" --tag release --max-bytes 4096` for passages with external source URLs and character offsets. To read the full cited revision, use `mb get --id "$document_id" --version "$cited_version"`. Historical citations depend on version retention.

        ## Write and follow citations

        Prefer descriptive Markdown paths such as `/notes/release.md`. Use `--markdown` on an extensionless note to enable Markdown indexing. A link such as `[[Policy#^rollback]]` cites a paragraph marked with `^rollback`. A relative Markdown link such as `[Policy](Policy.md)` cites a document. Inspect outgoing or incoming citations with:

        ```sh
        mb links /notes/release.md
        mb links /notes/Policy.md --incoming --block rollback
        mb get /notes/Policy.md --block rollback
        ```

        Qualify an ambiguous name with its path. Use explicit `--ref-id` for a document relationship, `--ref-path` for a location, and `--ref-url` for an external source. Add tags and metadata with `--tag` and `--meta` or with simple YAML properties at the top of a Markdown note.

        ## Edit safely

        Record durable findings, dates, and sources. Keep credentials and transient logs out of the store. Read the current version before replacing a body. Use a patch for a focused edit.

        ```sh
        mb get /notes/release.md
        mb put /notes/release.md --body-file revised.md --body-only --if-version "$current_version"
        mb patch /notes/release.md --patch-file change.diff --check
        mb patch /notes/release.md --patch-file change.diff
        ```

        Use `mb man search` for CLI options. Use `mb ensure-guide` to install this guide in an existing store that lacks it.
        """ + "\n",
        metadata: ["guide-revision": "2"]
    )
}
