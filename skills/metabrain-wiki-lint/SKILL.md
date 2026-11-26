---
name: metabrain-wiki-lint
description: Audit a selected metaBrain wiki for link and evidence defects and missing wiki properties. Repair a specified finding on request.
---

# Audit the project

1. Use [the CLI skill](../metabrain-wiki-cli/SKILL.md) to pin the existing store, explicit connection, and virtual project root, then read the guides and config. If the guides define required properties or additional navigation indexes, pass those explicitly. Use the local helper from this skill directory:
   ```sh
   python3 scripts/lint.py --store "$store" --project "$root" --no-server
   ```
   Substitute `--server "$endpoint"` for the selected daemon. The helper runs `mb` by default. Use `--mb PATH` to select another executable. Repeat `--require-property NAME` to replace the default title check, `--no-required-properties` for an explicitly empty contract, and `--index VIRTUAL_PATH` for each additional known navigation document.
2. Report the pinned selection, the native report, and the supplemental findings. Keep native counts and details intact. Native lint checks broken or ambiguous links and anchors, notes without incoming links, and invalid claim evidence. Resolution considers the whole store, so a resolved cross-project citation is not presumed stale. A navigation entry is stale when the native outgoing edge of the project index, recent summary, or a declared additional index is unresolved. Ambiguities stay in native lint for review. The helper uses current note bodies from `mb dump`, with no access-counting reads of the audited notes.
3. Supplemental properties apply to nonblank project Markdown content, including explicitly enabled files, and exclude the guides, administrative paths, and known navigation. Blank bodies may represent opaque captures. The default title can come from the document title, a top-level Markdown H1, or a simple YAML title declaration. Other required properties check explicit document metadata. If project rules require a more complex frontmatter property, inspect it directly and report the evidence. Empty-section findings use top-level ATX and Setext headings, with source line numbers. Descendant text and nonblank fenced code count as content. Comments, fence delimiters, and horizontal rules do not. Findings describe the current versions and do not change adopted notes.

# Repair a selected finding

Audit alone never repairs. If the user requests a specific repair, reread the affected revision, verify the location and replacement against the resolved evidence or project rule, and inspect the exact proposed edit with `--check-citations`. Keep ambiguous alternatives visible until the target is settled. Use the [reviewed write workflow](../metabrain-wiki-cli/references/reviewed-write.md) for a fresh operation and its recent and log records. If setup is missing, route to setup before writing. Apply the inspected preview when asked to repair. For a preview request, show the proposed edit. Leave unrelated findings and append-only historical records alone.
