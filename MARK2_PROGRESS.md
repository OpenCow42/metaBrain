# Mark II Progress

This file is the shared progress ledger for Mark II orchestration. The
orchestrator and every subagent must update it as tasks move through planning,
implementation, validation, review, and commit.

Progress notes should be short, factual, and linked to task IDs from
[MARK2_TASKS.md](MARK2_TASKS.md). The goal is to make the current state obvious
after a context switch without rereading the full thread or every commit.

## Rules

- Add a progress entry at the start and end of every orchestrator step.
- Add a progress entry when a subagent receives a task, starts implementation,
  starts validation, finishes validation, returns for review, or is blocked.
- Record test and coverage status for every task handoff.
- Record commit hashes when a task or task slice is committed.
- Record blockers, deferrals, and spec changes as explicit entries.
- Keep entries append-only. If an entry was wrong, add a correction entry rather
  than rewriting history.
- Keep details concise; put full analysis in the relevant task report, commit,
  or spec document.

## Entry Format

Use this format:

```text
### YYYY-MM-DD HH:MM TZ - <actor> - <task-id or general>

Status: pending | active | blocked | review | done | deferred | note
Step: <what changed>
Validation: <tests/coverage/benchmarks run, or "not run yet">
Commit: <hash or "none">
Next: <next planned action>
```

Actor examples:

- `orchestrator`
- `subagent:T03`
- `subagent:T18`

## Current Snapshot

Status: planning

Latest commit on `feat/mark2`: `a8dc9c8 docs(markii): add agent orchestration plan`

Next expected action: start `T00 Baseline Audit` when implementation begins.

## Log

### 2026-05-21 12:27 Europe/Paris - orchestrator - general

Status: note
Step: Created progress ledger requirement for Mark II orchestration.
Validation: documentation-only; tests not run.
Commit: none
Next: commit the progress ledger update when reviewed.
