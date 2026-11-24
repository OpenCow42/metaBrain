enum MetaBrainAgentGuide {
    static let document = DocumentInput(
        path: try! DocumentPath("/AGENTS.md"),
        title: "Working with metaBrain",
        body: """
        # Working with metaBrain

        Use metaBrain as this project's durable, searchable memory. Start in the project directory so `mb` discovers the nearest workspace store. Use `--store` to select a different store explicitly. Paths such as `/policies/Retention.md` refer to documents inside that store.

        ## 1. Search before you answer or write

        Check what the project already knows. Start with a path, tag, or metadata filter. Use `--view refs` to shortlist documents and `--view evidence` when you need verbatim passages for an answer.

        ```sh
        mb search --tag storage --meta status=current --view refs --limit 5
        mb search "nightly backups" --path-prefix /policies --view evidence --max-tokens 512
        ```

        ## 2. Verify and cite the passage

        Copy a returned `ref` into the command below. Read the surrounding section when conditions or exceptions could affect the answer. Keep the `ref` with your citation so another reader can reopen the same version while it is retained.

        ```sh
        mb get --ref "$ref" --context section --max-tokens 1024
        ```

        If `truncated` is true, narrow the query or raise the budget when you need more context. `--limit` caps distinct documents. `--max-tokens` counts one unit per UTF-8 byte of the entire compact JSON response, including the final newline.

        Use `mb recall "nightly backups" --tag storage --max-bytes 4096` when you need recorded source URLs and character offsets alongside passages. Reopen the full retained revision with `mb get --id "$document_id" --version "$cited_version"`, using the returned ID and version.

        ## 3. Save durable findings and link their sources

        Record decisions, findings, dates, and sources under descriptive `.md` paths. Use `--markdown` to index an extensionless note. Add tags and metadata with `--tag` and `--meta` or with simple YAML properties. Keep credentials and transient logs out of the store.

        ```sh
        mb put /decisions/backups.md 'Follow [[/policies/Retention.md#^keep-last]].' --tag storage --if-version 0
        mb links /decisions/backups.md
        mb links /policies/Retention.md --incoming --block keep-last
        mb get /policies/Retention.md --block keep-last
        ```

        The wikilink points to a paragraph marked `^keep-last`. A relative Markdown link such as `[Policy](../policies/Retention.md)` points to the policy document. If a link is unresolved, check the target and anchor. If a name is ambiguous, use its full path. A resolved link follows its target when it moves and reads against its current body. Use a versioned evidence `ref` to cite the exact text you verified.

        Use `--ref-id` for an explicit relationship to a document, `--ref-path` for a location, and `--ref-url` for an external source.

        ## 4. Update existing notes safely

        Read the current document before editing. Set `current_version` from that read and use `--body-only --if-version` to preserve the note's other fields and guard against concurrent edits. For a focused edit, check a unified diff before applying it.

        ```sh
        mb get /decisions/backups.md
        mb put /decisions/backups.md --body-file revised.md --body-only --if-version "$current_version"
        mb patch /decisions/backups.md --patch-file change.diff --check
        mb patch /decisions/backups.md --patch-file change.diff
        ```

        After editing linked notes, run `mb lint /decisions --format text` to find missing or ambiguous document targets and anchors. Omit the path to audit the whole store. Use `--orphans` to include Markdown notes with no indexed backlink from another document, or `--strict` to exit with status 3 when the selected checks find a problem.

        Record claims on the decision note with a stable UUID, state, and supporting or contradicting revision references. For sources created in the same operation, inspect the draft to obtain their IDs, add the claims, then inspect the completed proposal. Use `mb lint PROJECT --format text` to find stale or missing evidence.

        Preserve original bytes with `mb source stage FILE --origin ORIGIN`. Put the returned capture in the source document’s `sourceCapture` field. Recover it with `mb source export PATH --version N --output FILE`.

        For a source and decision that must appear together, inspect their full replacements with `mb operation inspect operation.json > preview.json`, review the target paths and versions, then use `mb operation apply preview.json`. Retry the original preview if the response was lost.

        ## 5. Work in a project wiki

        If the metaBrain skills are installed in your agent, start with `$metabrain-wiki` in Codex or `/metabrain-wiki` in Claude Code. Give it the virtual project root, such as `/projects/atlas`. It checks for project configuration, a project index, and a recent-activity note. For an existing project, it previews additions and identifies occupied paths. Read the store and project guidance before proposing changes.

        Use the same store, daemon endpoint or direct connection, and project root for the rest of the task. Keep the wiki's operation entry with the changes it describes in the reviewed operation.

        For example, ask `metabrain-wiki-ingest` to capture two design reviews and prepare a decision that cites both. Review their source captures and the single operation before applying it. In a fresh session, ask `metabrain-wiki-query` for a Deep answer using the same project root. It can reopen both retained passages, connect related notes, and identify unresolved disagreement. Ask `metabrain-save` separately if you want to preserve a specific conclusion.

        Use `mb preview /projects/atlas/decisions.base --project /projects/atlas` to preview a saved table. Pass `--body-file` to inspect a local draft before proposing any store changes. The same command checks JSON Canvas boards.

        Use `mb man search` for CLI options. Use `mb ensure-guide` to install this guide in an existing store that lacks it.
        """ + "\n",
        metadata: ["guide-revision": "9"]
    )
}
