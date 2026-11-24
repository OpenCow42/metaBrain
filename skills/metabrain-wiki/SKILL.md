---
name: metabrain-wiki
description: Preview setup or adoption of a metaBrain project wiki, load its rules, or route a wiki request to an available metaBrain skill.
---

# Select the wiki

- Establish the store, connection, and absolute virtual project root below `/`. Use the user's selection or a clearly established selection for this task. Normalize path separators and trailing slashes, reject dot segments, and use the exact root plus a slash to establish descendants. Confirm ambiguous selections before scanning or writing. Use `metabrain-wiki-cli` for connection and read commands.
- Read the virtual `/AGENTS.md`, then `<root>/AGENTS.md` if present. Preserve both documents. Read `<root>/_wiki/config.json` when present and use its version and mode. Treat unreadable documents, connection failures, and malformed configuration as errors. A missing optional guide is fine.
- Verify the selected store exists before inspecting it. A missing store requires a separate initialization request. Use the selected store and connection for the whole workflow. Network research requires the user's authorization. Routing, setup, and adoption use local store inspection.

# Preview setup or adoption

1. List the selected subtree recursively, including virtual folders. The config is a JSON document body with `{"version":1,"mode":"generic"}` for a new wiki. The recognized mode values are `generic`, `lyt`, `para`, and `zettelkasten`. Report an invalid config or unsupported version before proposing changes. Preserve a valid config and its existing mode.
2. Reserve `<root>/index.md` for project navigation, `<root>/_wiki/recent.md` for an activity summary, and `<root>/_wiki/operations/` for append-only operation notes. Preserve an existing Markdown project index as-is and identify it as adopted in the preview. Preserve an existing Markdown recent summary when the project has a valid config. For first-time adoption, an occupied recent path or operation directory requires the user to resolve the conflict before setup. An unexpected file at a required directory (including the root or its ancestors), directory at a required file path, content at the new operation path, or conflicting content in a reserved location blocks setup. Inspect exact paths as well as the listing. Report conflicts with their paths and preserve all existing project notes. If a config and both navigation documents already exist and are usable, report setup as complete without a write.
3. Propose only missing setup documents. Use a plain Markdown index and recent summary when creating them. Add one ordinary Markdown record at `<root>/_wiki/operations/<operation-UUID>.md` in the same operation. Use the operation's UUID in its name, record the date, purpose and changed paths, and link to related notes. Link the new recent summary to this record. Historical operation notes are never changed by this workflow.
4. Draft a JSON operation with `operationID` (a fresh UUID), `project` (`{"rawValue":"<root>"}`), and a `documents` array. Each entry contains `path` (`{"rawValue":"/full/virtual/path"}`), `body` (a string, including for JSON content), `tags` (array), `metadata` (object), and `references` (array). Save the draft and preview outside the store in local temporary files.
5. Run `mb operation inspect` with the selected options and draft filename, saving its JSON output. Verify its `storePath` identifies the selected store (accounting for filesystem aliases), and review its `storeIdentity`, project, and targets. Setup creates documents only: every target must be version zero with no document ID. If a target appeared during planning, stop and report the new collision. Present the additions, adopted documents, conflicts, and selected store, connection, and root.
6. Apply the reviewed preview only after user authorization for that preview, using `mb operation apply` on its file. A conflict requires fresh inspection and review. For an uncertain response, retry the same preview to obtain the committed receipt. Setup never uses `put`, moves, deletes, or pruning to resolve a collision.

# Route a request

Use this skill for setup. Check the active host's available skills before handing off.

- `metabrain-wiki-cli` for inspection and navigation.
- `metabrain-wiki-ingest` for supplied originals and claim evidence.
- `metabrain-wiki-query` for an answer grounded in the selected project.
- `metabrain-wiki-retrieve` for ranked passages and versioned references.
- `metabrain-save` for preserving the user's selected answer or insight.

If the requested skill is unavailable, say so and identify any supported local read that matches the request.
