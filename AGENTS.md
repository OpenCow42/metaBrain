# Agent Guidelines

These rules apply to the whole `metaBrain` repository. They are here to keep agent work small, reviewable, and aligned with the architecture of the project.

## Commit Discipline

- Commit often.
- Keep commits small in content and focused on one logical change.
- Use Conventional Commits for every commit message.
- Prefer these commit types: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, and `chore:`.
- Scopes are allowed but not required, such as `docs(agent):` or `feat(core):`.
- Do not batch unrelated code, documentation, formatting, and dependency changes into one commit.
- Avoid large rewrites unless they have been explicitly planned.

## Architecture

- Keep shared behavior in `MetaBrainCore`.
- Keep `MetaBrainCLI` thin over the shared core.
- Keep Apple platform UI work in the sibling `metaBrainExplorer` repository.
- Do not duplicate business logic between the CLI, core package, and Explorer app.
- Prefer clear, boring interfaces in the shared library before adding frontend-specific behavior.
- Keep public APIs intentional and documented when they become part of the project surface.
- Keep [COMPLEXITY.md](COMPLEXITY.md) current when changing CLI command flows or core store scan patterns.

## Testing

Deep testing is a cornerstone of this project's stability.

- Strive for 100% test coverage in the shared library.
- Strive for 100% test coverage in the CLI library or CLI-facing logic.
- Strive for 80-90% test coverage in the UI app.
- Add tests with behavior changes whenever a test target exists for the touched area.
- Verify meaningful changes with `swift build`.
- Run automated tests whenever test targets are available.
- Treat untested core storage, indexing, retrieval, and migration behavior as incomplete work.

## Repository Hygiene

- Do not commit generated build artifacts, local caches, or editor state.
- Keep dependency changes separate from feature work.
- Keep formatting-only changes separate from behavior changes.
- Preserve user work already present in the tree.
- Prefer explicit project documentation over hidden assumptions.

## Multi-Agent Implementation

- Use `ORCHESTRATOR.md` when supervising implementation progress.
- Use `IMPLEMENTATION_AGENTS.md` for the serial milestone sequence and launch prompt.
- Do not run milestone agents in parallel unless the project owner explicitly changes the orchestration plan.
