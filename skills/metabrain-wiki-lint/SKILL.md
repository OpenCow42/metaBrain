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
2. Use the native `referenceChecks` to distinguish store documents, current passages, retained evidence, and external URLs. For a request to check public URLs live, pass `--check-external` to the helper. Its `externalChecks` report reachability, redirects, missing pages, restricted access, and inconclusive results. A redirect or success is not evidence that the new URL contains the same source material. Never rewrite a captured origin to clear an HTTP finding.
3. Report the pinned selection, the native report, and the supplemental findings. Keep native counts and details intact. Native lint checks broken or ambiguous links and anchors, notes without incoming links, and invalid claim evidence. Resolution considers the whole store, so a resolved cross-project citation is not presumed stale. A navigation entry is stale when the native outgoing edge of the project index, recent summary, or a declared additional index is unresolved. Ambiguities stay in native lint for review. The helper uses current note bodies from `mb dump`, with no access-counting reads of the audited notes.
4. Supplemental properties apply to nonblank project Markdown content, including explicitly enabled files, and exclude the guides, administrative paths, and known navigation. Blank bodies may represent opaque captures. The default title can come from the document title, a top-level Markdown H1, or a simple YAML title declaration. Other required properties check explicit document metadata. If project rules require a more complex frontmatter property, inspect it directly and report the evidence. Empty-section findings use top-level ATX and Setext headings, with source line numbers. Descendant text and nonblank fenced code count as content. Comments, fence delimiters, and horizontal rules do not. Findings describe the current versions and do not change adopted notes.

# Repair a selected finding

An audit leaves the store untouched. For a repair request, use the [versioned write workflow](../metabrain-wiki-cli/references/reviewed-write.md).

1. Audit the requested scope with `mb lint PATH --references --format json`. Read the exact affected revision by ID and version. For a Markdown occurrence, reopen the reported `start` and `end` with `mb get --ref 'SOURCE_ID@VERSION#START-END'` and check the returned reference and truncation flag. The offsets are Swift Characters. Use the returned text and unambiguous surrounding context when preparing the replacement. For a native reference, use the returned index. Preserve shared link definitions unless the intended edit covers every use.
2. Verify document fixes by the same stable document ID. For a broken heading or block, first try its current selector. If it fails, establish the intended excerpt from retained or supplied evidence and verify its exact text inside a specific replacement passage. Compare returned text, including any meaningful whitespace. Keep a retained citation pinned to its exact revision. Report ambiguous targets, pruned revisions, or cases where the original evidence cannot be established. A reachable or redirected URL alone never authorizes a replacement.
3. Inspect one focused operation with `--check-citations`. Verify the expected target IDs, versions, and returned passages against the repair plan. Correct any `blocksApply` rows before applying. For a preview, report the diff. For a repair, apply the exact preview, reopen the cited passages, and run scoped lint again. Reuse the current state on repeat runs. Preserve unrelated findings, source captures, and historical operation notes.
