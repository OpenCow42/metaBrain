# Project memory in metaBrain

**Proposed release.** Ship 15 independently callable skills for Codex and Claude Code. An agent uses the skills to turn sources into project knowledge, answer questions from that knowledge, and preserve selected conclusions. MetaBrainExplorer is the first optional viewer. A person can open the same store and inspect the evidence behind a decision. The complete workflow also runs through `mb` with Explorer closed.

## Engineering status

The core, CLI, and daemon support reviewed atomic writes, recovery of original file bytes, and claims with evidence pinned to retained revisions. MetaBrainExplorer can show the cited passage, open the source at its current path, and export the captured original. The 15 skill packages and the board and saved-table previews remain planned. [CLI workflows](../README.md#capture-and-recover-an-original-file) · [Worked decision example](claim-evidence.md)

## The first release scenario

Two design reviews disagree about how a client should store data. The agent ingests both originals, links their arguments to one decision note, and records which evidence supports each conclusion. In a fresh session, a user asks what changed and why. The agent answers from the stored passages and shows the disagreement. The user can choose to save that answer.

Later, someone revises and moves a source note. In Explorer, **Open current source** follows its stable document ID. **Show cited passage** opens the exact retained revision used in the decision. If that revision has been pruned, Explorer identifies the unavailable revision. The user can still retrieve the captured original while it is retained.

## Skill behavior and acceptance

Each name below takes the prefix `metabrain-`. Both hosts use the same skill definitions. A user can invoke a skill directly or ask `metabrain-wiki` to choose the right one.

| Skill | User intent and behavior | Acceptance check |
| --- | --- | --- |
| `wiki` | Set up or adopt a wiki under a virtual project path. Preview additions and route requests. | Adopt a project with existing notes and a customized guide. Preserve both and report path conflicts before applying. |
| `wiki-ingest` | Capture supplied material, find related notes, and record claims with evidence. | Ingest two disagreeing reviews into one decision. Both accounts remain traceable. Repeating an identical ingest adds no duplicate capture or note. |
| `wiki-query` | Answer from project knowledge. Quick follows direct evidence, Standard searches related notes, and Deep investigates competing evidence and gaps. | Ask the same question at each depth. Material claims cite verified passages. Notes and the operation log keep their prior versions. |
| `save` | Preserve the answer, decision, or insight the user selected. Search for an existing home and keep its supporting citations. | Save one conclusion from a longer conversation. The resulting note contains the selected conclusion and its evidence. |
| `wiki-lint` | Report broken links, ambiguous targets, missing anchors, orphans, incomplete wiki properties, empty sections, stale index entries, and invalid evidence records. | Run twice against the same fixture and obtain the same findings. Applying a selected repair is a separate reviewed operation. |
| `wiki-mode` | Suggest destinations under Generic, LYT, PARA, or Zettelkasten filing. Generic is the default. | Preview a destination, change the mode, and verify the new suggestion and the original paths of existing notes. |
| `wiki-retrieve` | Return ranked passages and versioned references using native lexical search, project filters, and an output budget. | Reopen a returned reference with `mb get --ref` and recover the exact passage. Report when the budget truncates results. |
| `wiki-cli` | Inspect the selected store, read documents, search, and follow links through `mb`. | Open the same fixture directly and through `mbd`. Report the selected store and connection and return equivalent content. |
| `wiki-fold` | Summarize a bounded range of operation-log entries. Preview the fold and cite each contributing entry. | Applying the same fold twice produces one summary. The child entries keep their original contents. |
| `autoresearch` | Research within an agreed topic, source scope, and stopping budget. Use authorized host research tools for public sources. | Produce a cited dossier with gaps and disagreements. Filing it and merging conclusions into existing notes are two independently reviewed operations. |
| `defuddle` | Describe how a supplied URL could be captured. Accept already available HTML or Markdown for local capture. | Inspecting a URL makes zero network requests. Retrieving a locally captured file returns the original bytes and records any extraction that actually ran. |
| `canvas` | Inspect and edit portable JSON Canvas boards. Validate node IDs, edge endpoints, and project-relative file targets. | Add one node to an existing board. Preserve unknown fields and stacking order, then open its linked document from Explorer. |
| `markdown` | Draft and validate notes using properties, wikilinks, headings, block references, and embeds. Document indexing and rendering separately. | Resolve a link to a named block, identify an embed occurrence, and verify that links inside a percent comment create no backlinks. |
| `bases` | Define saved views as portable `.base` documents and validate them against the project's note properties. | Preview a filtered table in Explorer. Identify an unsupported filter before showing results and preserve it when editing another field. |
| `think` | Review a consequential decision. Return the recommendation, evidence, strongest counterargument, verification step, and what would change the decision. | A review of conflicting sources cites both and identifies a test that could settle the disagreement. Saving the review requires a separate request. |

## Store and viewer contracts

- **Project boundary.** Each wiki has an explicit root, such as `/projects/atlas`. Setup previews its configuration, project index, and recent-activity summary. Multiple wikis share a store. Ingestion, filing, and maintenance target the selected root.
- **Reviewed writes.** One logical change commits its notes, claims, references, navigation updates, and operation record together. A preview identifies the store, project, changed paths, and expected revisions. A conflicting edit invalidates the preview. Retrying an identical completed operation returns its receipt.
- **Sources and claims.** Keep ingestion history, source provenance, and claim assessment distinct. Keep original bytes under a content hash. Extracted text records its origin and extraction method. A source with only binary bytes remains retrievable. Quotations require actual text. Represent claims as accepted, provisional, contested, unsupported, or deprecated. Acceptance requires fresh, active, non-synthetic evidence. A high-risk claim requires two independent sources for acceptance.
- **Citations.** Use the existing document identity for navigation and a versioned evidence reference for a quotation. The CLI and Explorer resolve both through the core. Show stale, superseded, disputed, or missing evidence explicitly.
- **Native previews.** Explorer uses its document browser and history view. Boards render text, files, groups, links, and edges. Saved views initially support tables, column order, row limits, folder and tag filters, property equality, and Boolean combinations. Apply global and view filters together. When a definition exceeds that subset, identify the unsupported expression and offer its source. [JSON Canvas format](https://jsoncanvas.org/spec/1.0/)

## Delivery and verification

1. Build a shared fixture from the two design reviews, a binary original, a decision, a board, and a saved view. Use the 15 checks above as the behavioral specification for both hosts.
2. Deliver project-scoped atomic operations, original-byte capture, and claim evidence in `MetaBrainCore`. Expose the same behavior through `mb` and `mbd`. Reuse document IDs, versioned passages, indexes, and lint. [Existing agent workflow](../README.md#agent-workflow) · [Daemon retrieval interfaces](../SERVER.md#agent-retrieval-routes)
3. Package the 15 skills with tested installation and invocation in both hosts. Add a worked example to the bundled store guide and preserve customized guides during adoption. Keep the shared rules for storage and retrieval in the core.
4. Deliver source navigation, cited-passage inspection, and board and table previews in the sibling MetaBrainExplorer project. Test direct and daemon-backed connections and preserve ordinary browsing on older stores.
5. Gate the release on the end-to-end decision scenario, byte-for-byte recovery, restart and retry tests, project isolation, and behavioral checks for every skill. Update command help, manual, API, architecture, and complexity documentation as each interface ships.
