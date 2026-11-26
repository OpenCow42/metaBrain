---
name: metabrain-wiki-fold
description: Create or preview an append-only summary of a bounded range of raw entries in a selected wiki operation log.
---

# Select raw entries

1. Pin the store, connection, and project. Read the guides and confirm the wiki has usable configuration and navigation. From this skill directory, run:
   ```sh
   python3 scripts/select-fold.py --store "$store" --project "$root" --no-server
   ```
   Substitute `--server "$endpoint"` for the selected daemon. Use `--mb PATH` if needed. The helper inspects current Markdown UUID notes directly under `<root>/_wiki/operations/` using `mb list` and `mb dump`. It selects up to 16 most recent raw entries, reports any shortfall, and returns the selected entries in chronological order (creation time, then path). For an explicitly chosen inclusive range, add `--from FIRST_VIRTUAL_PATH --through LAST_VIRTUAL_PATH`. Unknown or reversed endpoints and entries marked `wiki-operation=fold` are rejected. If the default selection has fewer than 16 entries, report the shortfall and stop before drafting. An explicitly chosen shorter range can be folded. Report the selection and boundaries before summarizing.
2. Summarize meaningful changes, disputed or pending outcomes, and useful links in the selected entries. Include a source line for every contributing raw entry with a navigation link, the exact document ID, and its numeric version. Verify each citation against `mb get --id ID --version VERSION --format json`. The output path uses a SHA-256 digest of the ordered document ID and version pairs, so wording and timestamps of the fold do not affect its identity. Keep the summary and its log entry outside the raw source set.

# Preview and apply

1. At the selected `<root>/_wiki/folds/<digest>.md`, inspect for a collision, including a directory. Give the summary explicit metadata `wiki-fold=<digest>` and `wiki-fold-sources` containing the helper's exact `sources` JSON string. Add the human-readable source list to the body. Mark the record with `wiki-operation=fold` and `wiki-fold=<digest>`. The helper reports `complete` for a summary with the expected markers, one matching log which links to it, a resolved index link to the summary, and a resolved recent link to that log. Verify the visible source list and log marker. Report a complete fold as a no-op even if a newly drafted summary would read differently. A mismatched or missing piece of an apparently existing fold is a conflict. Show the affected paths and stop without overwriting a summary or historical log.
2. Use the [reviewed write workflow](../metabrain-wiki-cli/references/reviewed-write.md) to inspect one operation that adds the new summary, links it from the existing index, links the new operation record from recent activity, and adds one marked append-only `_wiki/operations/<operation-UUID>.md` record. Include the summary link, digest, ordered source revisions, date, and chosen bounds in the log. Check for file and directory collisions and that the source entries still match their observed IDs and versions before completing the operation. Raw source entries remain outside the operation payload. A newer source revision yields a different selection digest on fresh planning.
3. For preview, show the summary, contributing revisions, expected targets, and exact preview. Apply when the user requests the fold. If the write response is uncertain, retry the same preview to recover the receipt. Replanning the same selection after success sees the completed fold even if its new log entry is present, since the selection excludes marked fold logs.
