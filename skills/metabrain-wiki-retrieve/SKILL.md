---
name: metabrain-wiki-retrieve
description: Retrieve ranked passages and versioned references from a selected metaBrain wiki with project filters and an output budget.
---

Use the [CLI skill](../metabrain-wiki-cli/SKILL.md) to pin the selected store, connection and project, and load its guides. Use native BM25 lexical ranking with the user's search terms and exact project prefix. Use tags and metadata filters when applicable. For reference lists, `--view refs` also supports filters without a query.

```bash
"${MB[@]}" search "$query" --path-prefix "$root/" --view evidence --limit "$limit" --max-tokens "$budget"
"${MB[@]}" get --ref "$ref" --max-tokens "$budget"
"${MB[@]}" get --ref "$ref" --context section --max-tokens "$budget"
```

Check that each result is a descendant of `"$root/"`. Before opening an explicit or discovered reference, match its document ID against an in-project row from `mb list "$root" --recursive --format json`. This checks scope before loading a body. Recheck the path returned by `get --ref`, and use the exact retained passage for any quote. Surface missing or out-of-scope evidence without quoting it. Read the exact reference first. Use a separate section read to check qualifiers because it can return a wider reference. Identify when the surrounding context was truncated.

Return passages in ranked order with path and unchanged versioned `ref`. Honor the requested output budget. The CLI counts one unit per serialized UTF-8 byte, including JSON and the final newline. Report any CLI truncation or omissions made to meet the overall budget. If producing combined output from several reads, measure that serialized response as a whole and omit complete items as necessary. Keep a reference and its passage together. Retrieval uses read-only commands and the selected project.
