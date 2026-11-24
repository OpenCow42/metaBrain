---
name: metabrain-wiki-cli
description: Inspect a selected metaBrain wiki through mb. Use to list project notes, find evidence, reopen retained passages, or follow Markdown links.
---

# Pin the store and connection

Use an explicitly selected local store path and project root. If the task already chose a daemon, use its explicit Unix socket or loopback HTTP URL. Otherwise use direct access. Include the same store and connection on every command. Report both, plus the normalized absolute virtual project root below `/`. Verify the selected local store already exists before reading. Surface an unavailable store or daemon without initializing a store or falling back to another connection. Avoid `--server auto`.

Examples use a shell array for the common options. Fill in the actual values:

```bash
MB=(mb --store "$store" --no-server)
# For an explicitly chosen local daemon, use this array instead:
# MB=(mb --store "$store" --server "$endpoint")
"${MB[@]}" get /AGENTS.md --format json
"${MB[@]}" get "$root/AGENTS.md" --format json
"${MB[@]}" get "$root/_wiki/config.json" --format json
"${MB[@]}" list "$root" --recursive --format json
```

Normalize separators and reject dot segments in the virtual root. Read both virtual guides when present and load the config body when available. Distinguish an optional document missing from a failed connection. These commands work on projects before setup. Use `mb help COMMAND` without the store and connection flags for local command help.

# Inspect evidence and links

```bash
"${MB[@]}" search 'offline storage' --path-prefix "$root/" --view evidence --limit 8
"${MB[@]}" get --ref "$ref"
"${MB[@]}" get --ref "$ref" --context section
"${MB[@]}" get --id "$document_id" --format json
"${MB[@]}" links "$path" --format json
"${MB[@]}" links "$path" --incoming --format json
```

Filter to the exact root's descendants. Check returned paths against the project boundary before using a hit. Use `--view refs` to shortlist documents, and `--view evidence` for passages. Match the ID of an explicit or discovered `ref` to an in-project row from the scoped listing before reopening it. Check the returned path too before quoting. Read section context separately because it can widen the returned reference. A versioned reference reads the retained passage, while `--id` without a version reads the current document after a move. Report unavailable citations and inspect a link's resolved target before reading it. Links can lead outside the project. Ask before expanding scope. Read-only inspection does not update notes, navigation, or the operation log.

For wiki mutations, use the [reviewed write workflow](references/reviewed-write.md).
