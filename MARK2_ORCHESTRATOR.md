# Mark II Orchestrator

This document defines how a lead agent should coordinate the Mark II
implementation with serial subagents. The goal is to keep a large storage
revision reviewable, test-driven, and continuously aligned with [MARKII.md](MARKII.md),
[ARCHITECTURE.md](ARCHITECTURE.md), and [COMPLEXITY.md](COMPLEXITY.md).

## Role

The orchestrator owns continuity, sequencing, and final integration. Subagents
own one bounded task at a time.

The orchestrator must:

- keep [MARK2_TASKS.md](MARK2_TASKS.md) current;
- launch or assign only one implementation subtask at a time unless the work is
  explicitly read-only and cannot conflict;
- provide each subagent a narrow task packet based on [MARK2_SUBAGENT.md](MARK2_SUBAGENT.md);
- require tests or benchmark evidence for every behavior-changing task;
- review each returned diff before starting the next dependent task;
- keep commits small and conventional, following [AGENTS.md](AGENTS.md);
- stop and update the specs when implementation discovers a missing invariant.

## Source Of Truth

The active requirements are:

- [MARKII.md](MARKII.md): storage model, chunking, migration, CLI behavior, and
  Mark II testing target;
- [ARCHITECTURE.md](ARCHITECTURE.md): high-level core architecture and v2 model;
- [COMPLEXITY.md](COMPLEXITY.md): command/core cost model and complexity guards;
- [AGENTS.md](AGENTS.md): repository-wide agent, commit, and testing rules;
- [MARK2_TASKS.md](MARK2_TASKS.md): serial implementation queue.

If code and specs disagree, the orchestrator should decide whether the code is
wrong or the spec needs a deliberate update. Silent drift is not allowed.

## Serial Workflow

Use this loop for each task:

1. Select the next unblocked task from [MARK2_TASKS.md](MARK2_TASKS.md).
2. Prepare a task packet with scope, allowed files, required tests, and explicit
   non-goals.
3. Run the subagent for that task.
4. Review the returned diff locally.
5. Run the validation commands the subagent ran, plus any integration tests the
   orchestrator thinks are needed.
6. Fix or return the task if validation fails.
7. Update docs or task state when behavior, complexity, or test coverage changes.
8. Commit the completed logical change with a detailed Conventional Commit.
9. Move to the next task only after the tree is clean.

The orchestrator should favor small, serial changes even when the feature is
large. Mark II touches storage, indexing, migration, and CLI compatibility; each
step should leave the repository in a testable state.

## Task States

Use these states in [MARK2_TASKS.md](MARK2_TASKS.md):

- `pending`: not started.
- `blocked`: waiting on a dependency, design decision, or failing prerequisite.
- `active`: currently assigned to one subagent or the orchestrator.
- `review`: implementation returned and awaiting orchestrator review.
- `done`: merged locally, validated, and committed.
- `deferred`: deliberately moved out of Mark II `2.0.0`.

Only one task should be `active` during normal implementation.

## Handoff Packet

Every subagent should receive:

- task ID and title;
- the relevant excerpts or links from [MARKII.md](MARKII.md);
- expected files or directories to inspect first;
- allowed write scope;
- public behavior that must remain compatible;
- tests to add or update;
- validation commands to run;
- expected final report format from [MARK2_SUBAGENT.md](MARK2_SUBAGENT.md).

The packet should also state: "You are not alone in the codebase. Do not revert
edits made by others. Keep the change scoped to this task."

## Validation Ladder

Use the smallest validation that proves the task, then climb as the blast radius
grows:

1. Focused unit tests for new helpers or data types.
2. Core storage tests for records, indexes, reconstruction, migration, and
   pruning.
3. CLI smoke tests for command compatibility and output shape.
4. Benchmark fixtures for performance-sensitive work.
5. Full `swift test` before integration milestones and before enabling v2 as the
   default write format.

Every subagent validation gate includes two default requirements unless the
orchestrator explicitly records a temporary exception:

- the full automated test suite should pass, including full `swift test`;
- coverage for touched `MetaBrainCore` and CLI-facing behavior should be 100%.
  If the local coverage command is not available or a temporary gap is
  unavoidable, the subagent must report the exact reason and the orchestrator
  must record a follow-up task before marking the work `done`.

For storage and indexing tasks, "it compiles" is not enough. The task is not
complete until exact reconstruction, stale-index cleanup, and v1/v2 compatibility
risks are covered by tests or explicitly deferred.

## Review Checklist

Before committing a subagent result, the orchestrator should check:

- Does the diff stay inside the task scope?
- Are public CLI changes intentional and documented?
- Are v1 records still readable?
- Does any write path accidentally store a full body in v2 document or version
  records?
- Are chunk hashes based only on exact chunk body bytes?
- Are indexes keyed by current-version occurrence identity when needed?
- Are segment IDs stable for unchanged pointer runs?
- Are hashers streaming when whole-file hashing is needed?
- Does pruning account for manifests, segments, and reachable chunks?
- Did tests cover duplicate chunk content, malformed Markdown/front matter, and
  JSONL repeated lines when relevant?
- Does the full automated test suite pass, including full `swift test`?
- Is coverage 100% for touched `MetaBrainCore` and CLI-facing behavior, or is
  any exception explicitly recorded with a follow-up?
- Did the task update [COMPLEXITY.md](COMPLEXITY.md) if scan patterns changed?

## Commit Policy

Commit each finished task or small task slice. Use Conventional Commits:

```text
feat(core): add v2 chunk records
test(markii): cover duplicate chunk occurrence indexes
docs(markii): refine migration task plan
```

Do not combine dependency changes, storage model changes, CLI changes, and
benchmark updates in one commit unless the task explicitly requires it.

## Performance Gates

Before Mark II becomes the default write format, the orchestrator must ensure:

- current-base benchmark results were captured on a named commit;
- Mark II benchmark results were captured with the same fixture shapes;
- segment size `256` was tested against smaller and larger targets;
- the chunk token cap was benchmarked and fixed in tests;
- ZSTD level 9 CPU and storage tradeoffs were recorded;
- large JSONL ingest, one-line patch, `get`, `history`, `dump`, `search`, and
  `prune` scenarios were measured.

If performance is mixed, the orchestrator should keep v2 behind an internal
feature switch until the tradeoff is explicit and accepted.

## Stop Conditions

Pause implementation and update the plan when:

- a task needs a public CLI change not planned for `2.0.0`;
- exact reconstruction cannot be preserved;
- a v2 write path requires loading very large files wholly into memory;
- a benchmark shows Mark II is worse in the primary target scenarios;
- an invariant in [MARKII.md](MARKII.md) cannot be implemented cleanly;
- a subagent returns broad refactors outside the task scope.

Stop conditions should result in a spec update, a task split, or a deliberate
deferral before more code is written.
