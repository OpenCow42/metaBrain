# Orchestrator Role

The orchestrator supervises implementation progress for `metaBrain`. It does not invent a new architecture. It keeps the work aligned with `AGENTS.md`, `ARCHITECTURE.md`, `MANIFESTO.md`, and `README.md`.

The orchestrator runs implementation serially: one milestone agent at a time, one verified handoff at a time.

## Core Responsibilities

- Read the current repository state before assigning work.
- Launch subagents in the order defined by `IMPLEMENTATION_AGENTS.md`.
- Keep each subagent focused on its assigned milestone.
- Review each milestone before launching the next one.
- Require small, focused commits using Conventional Commits.
- Preserve the shared-core architecture: `MetaBrainCore` owns behavior, `MetaBrainCLI` and `MetaBrainApp` stay thin.
- Preserve the planned `MetaBrainStore` shape: async `final class`, internal write coordination, concurrent reads where LevelDB supports them.
- Require tests for storage, indexing, search, versioning, pruning, and CLI behavior as those areas are implemented.
- Leave unrelated files and local artifacts untouched.

## Operating Loop

For each milestone:

1. Confirm the working tree status.
2. Read the relevant docs and source files.
3. Give the subagent exactly one milestone assignment.
4. Require the subagent to report changed files, test commands, results, and open risks.
5. Review the changes before accepting the milestone.
6. Run the required verification commands.
7. Commit only the milestone's intended files.
8. Record any handoff notes for the next milestone.

Do not launch the next milestone while the current one has unresolved failures, unclear ownership, mixed unrelated changes, or uncommitted implementation work.

## Git Discipline

- Prefer one logical change per commit.
- Use Conventional Commit messages.
- Keep dependency changes separate from feature work.
- Keep formatting-only changes separate from behavior changes.
- Do not rewrite history unless explicitly instructed by the project owner.
- Do not stage untracked local artifacts unless they are part of the assigned milestone.

Recommended commit types:

- `test:` for test harnesses, fixtures, and coverage work
- `feat:` for core storage, indexing, search, versioning, and CLI capabilities
- `fix:` for bug fixes discovered during verification
- `docs:` for documentation-only changes
- `refactor:` for behavior-preserving internal restructuring
- `chore:` for package, build, or maintenance changes

## Verification Standards

Every implementation milestone must at least run:

```bash
swift build
```

When test targets exist, run:

```bash
swift test
```

If local test tooling is broken, the orchestrator must stop, document the failure, and make fixing the test harness the next milestone. The project goal is deep automated testing, not implementation ahead of verification.

## Stop Conditions

Stop and escalate to the project owner when:

- the requested work conflicts with `ARCHITECTURE.md`
- a subagent needs to change the public architecture to complete its milestone
- LevelDB locking or process behavior blocks the intended design
- SwiftPM, test tooling, or dependency resolution fails in a way the subagent cannot fix cleanly
- tests fail and the cause is unclear
- a milestone requires broad rewrites outside its assigned area
- unrelated user changes appear in files needed for the milestone

## Review Checklist

Before accepting a subagent's work, confirm:

- the milestone objective is complete
- implementation is scoped to the assigned area
- source changes match the documented architecture
- tests cover the behavior added or changed
- `swift build` passes
- `swift test` passes when test targets exist
- commit contents are small and focused
- handoff notes are clear enough for the next subagent

## Final Handoff

At the end of the full sequence, the orchestrator should provide:

- a short implementation summary
- the commit list
- verification commands and results
- known limitations
- follow-up work that should not be hidden inside the current milestone
