# Mark II Subagent Contract

This document defines the contract for any subagent assigned to Mark II work.
Each subagent should finish one bounded task, validate it with tests, and return
a precise handoff to the orchestrator.

## Operating Rules

- Work only on the assigned task.
- Preserve user and other-agent changes already present in the tree.
- Do not rename public CLI behavior unless the task explicitly asks for it.
- Keep `MetaBrainCore` as the owner of shared behavior.
- Keep `MetaBrainCLI` thin over core APIs.
- Add or update tests with every behavior change.
- Update [COMPLEXITY.md](COMPLEXITY.md) when scan patterns or asymptotic behavior
  change.
- Add progress entries to [MARK2_PROGRESS.md](MARK2_PROGRESS.md) as the assigned
  task moves through implementation, validation, review, or blockage.
- Prefer small local helpers over broad refactors.
- Do not mark the task complete if validation did not run.

## Required Task Packet

The orchestrator should give each subagent:

```text
Task ID:
Title:
Goal:
Relevant spec sections:
Files/directories to inspect first:
Allowed write scope:
Non-goals:
Required tests:
Validation commands:
Expected final report:
Progress reporting:
```

The subagent should ask for clarification only when the task cannot be completed
safely from the packet and the repository context.

## Standard Implementation Loop

1. Read the assigned spec sections and nearby implementation.
2. Identify the smallest code surface that satisfies the task.
3. Add failing or characterization tests first when practical.
4. Implement the behavior.
5. Run focused validation.
6. Run broader validation if the change touches shared storage, indexing,
   migration, or CLI compatibility.
7. Update docs only when the implementation changes the agreed model.
8. Update [MARK2_PROGRESS.md](MARK2_PROGRESS.md) with validation status and
   review handoff state.
9. Return a concise final report with files changed, tests run, and residual
   risks.

Subagents should also add progress entries when they receive the task, start
implementation, discover a blocker, start validation, and finish validation.

## Validation Expectations

Use these defaults unless the task packet says otherwise:

- Every task must leave the full automated test suite passing, including full
  `swift test`.
- Every task must keep coverage at 100% for touched `MetaBrainCore` and
  CLI-facing behavior.
- Data type or pure helper: focused unit tests.
- Chunker: fixture tests for exact reconstruction, boundaries, fallback, and
  hash stability.
- Storage write path: write/read/reconstruct tests plus retained history tests.
- Indexing: duplicate content tests and stale-index cleanup tests.
- Migration: v1 fixture read tests and lazy v2 write tests.
- CLI: command smoke tests and output-shape tests.
- Performance task: benchmark command, fixture shape, and recorded result path.

For Mark II, tests should prefer exact byte/string fixtures over loose contains
assertions when reconstruction or hashing is involved.

If the repository coverage command is unavailable, the subagent should say so in
the final report and explain how new or changed behavior was otherwise covered.
If a temporary coverage gap is unavoidable, the subagent must name the uncovered
path and propose a follow-up; the task should not be marked complete without
orchestrator approval.

## Mark II Invariants

Every subagent should protect these invariants:

- `chunkID == chunkSHA256 == sha256(exact chunk body bytes)`.
- Chunk hashes exclude record metadata, ordinals, offsets, paths, timestamps,
  parser diagnostics, token hints, and debug labels.
- Current-version search/reference/metadata postings identify occurrences with
  `documentID + ordinal + chunkID`.
- `segmentID == segmentSHA256` for canonical ordered chunk-pointer runs.
- Segment hashes exclude segment ordinal, debug labels, and cache fields.
- `fileSHA256` is optional lazy metadata and should be refreshed only when an
  operation already streams the whole reconstructed body.
- v2 document and version records must not duplicate the full document body.
- `get` and `dump` reconstruct exact source text.
- `versions` is removed in Mark II; `history` is the command.
- `version` reports `2.0.0` for the Mark II release.
- ZSTD defaults to level 9 for content-bearing values.

## Final Report Template

Subagents should return:

```text
Task:
Summary:
Files changed:
Tests run:
Validation result:
Docs updated:
Complexity impact:
Progress entries:
Follow-ups or risks:
```

If validation failed or could not run, say so plainly and include the exact
command and failure. Do not bury failed tests under a success summary.

## Handoff Quality Bar

A task is ready for orchestrator review when:

- the diff is scoped to the assigned task;
- tests or benchmarks were added where the task changed behavior;
- focused validation passes;
- the full automated test suite passes, including full `swift test`;
- touched `MetaBrainCore` and CLI-facing behavior remains at 100% coverage, or
  any exception is explicitly reported for orchestrator approval;
- [MARK2_PROGRESS.md](MARK2_PROGRESS.md) has entries for the task's current
  state, validation result, and review handoff;
- the final report names all changed files;
- unresolved risks are explicit;
- the working tree contains no generated artifacts unrelated to the task.

## Common Pitfalls

- Using `chunkID` alone for current indexes. Duplicate content needs occurrence
  identity.
- Hashing stored records instead of semantic/content payloads.
- Accidentally storing full bodies in v2 document or version records.
- Making `dump` perform integrity checks in `2.0.0`.
- Exposing public `--chunk-id` or `--format` flags before `2.1.0`.
- Treating Markdown parse failure as a document write failure.
- Letting JSON nested splitting become full recursive JSON rewrite machinery.
- Letting front matter extraction become full YAML support in `2.0.0`.
