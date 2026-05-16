# Implementation Agents

This document defines the serial milestone sequence for implementing the planned `metaBrain` storage architecture. Use it with `ORCHESTRATOR.md`.

Each subagent works on exactly one milestone, verifies it, and hands off notes before the next subagent starts.

## Launch Prompt

Use this prompt to start an orchestrator agent:

```text
You are the implementation orchestrator for the metaBrain Swift package.

Read AGENTS.md, MANIFESTO.md, ARCHITECTURE.md, ORCHESTRATOR.md, and IMPLEMENTATION_AGENTS.md before making assignments.

Run the implementation serially, one milestone agent at a time, in the order listed in IMPLEMENTATION_AGENTS.md. Do not run subagents in parallel. Do not invent a daemon. Do not change the documented architecture unless you stop and ask the project owner first.

For every milestone:
- inspect the current repository state
- assign only the milestone's scoped work
- require tests for implemented behavior
- verify with swift build and swift test when test targets exist
- commit small, focused changes using Conventional Commits
- record handoff notes before launching the next milestone

Preserve the planned core shape: MetaBrainStore is an async final class facade, high-level mutations are internally serialized, reads/searches may use LevelDB concurrency and snapshots, and CLI/UI remain thin wrappers over MetaBrainCore.
```

## Milestone 1: Test Harness And Fixtures

Mission: establish a working test target and reusable temporary-store fixtures before implementing storage behavior.

Owned areas:

- `Package.swift`
- `Tests/MetaBrainCoreTests`
- test-only helpers and fixtures

Out of scope:

- production storage APIs
- CLI commands
- UI changes

Required verification:

- `swift build`
- `swift test`
- at least one passing placeholder or smoke test proving the test target runs

Expected commit:

- `test: add core test harness`

Handoff:

- Document the chosen test framework, fixture helpers, and any local tooling caveats.

## Milestone 2: Domain Types And Keyspace Helpers

Mission: add the public document/search/version types and internal key-building helpers needed by later storage work.

Owned areas:

- `Sources/MetaBrainCore`
- `Tests/MetaBrainCoreTests`

Out of scope:

- opening LevelDB
- real persistence
- CLI commands

Required verification:

- tests for path normalization, document IDs, retention policy values, reference modeling, and key ordering
- `swift build`
- `swift test`

Expected commit:

- `feat: add document domain types`

Handoff:

- List public types added and any intentional compatibility assumptions.

## Milestone 3: Compressed LevelDB Storage Foundation

Mission: open a LevelDB-backed store and wire compressed Codable JSON envelopes through `swift-leveldb-zstd`.

Owned areas:

- `MetaBrainStore` initialization and options
- LevelDB/ZSTD codec setup
- low-level record read/write helpers
- temporary database tests

Out of scope:

- full document editing workflow
- search indexes
- CLI commands

Required verification:

- tests for opening a store, writing and reading compressed records, missing keys, and clear open/lock failure surfacing
- `swift build`
- `swift test`

Expected commit:

- `feat: add compressed store foundation`

Handoff:

- Document default compression, cache, Bloom filter, and store lifecycle behavior.

## Milestone 4: Versioned Documents And Retention

Mission: implement document create/update/fetch with stable IDs, path aliases, full-snapshot versions, and retention pruning.

Owned areas:

- `putDocument`
- `getDocument`
- `listVersions`
- version retention
- path alias records

Out of scope:

- lexical search
- references and backlinks
- CLI commands

Required verification:

- tests for create, update, fetch by ID, fetch by path, path rename behavior, version listing, keep-all retention, keep-last-N retention, time-window retention, and on-write pruning
- `swift build`
- `swift test`

Expected commit:

- `feat: add versioned document storage`

Handoff:

- Note exact retention semantics and any pinned-version placeholder decisions.

## Milestone 5: Chunking, Indexing, Metadata, And References

Mission: add current-version chunks, lexical term indexes, tag indexes, metadata indexes, and document reference edges.

Owned areas:

- chunk generation
- tokenization
- index write/delete helpers
- reference and backlink records

Out of scope:

- final search ranking
- CLI commands
- embedding or vector search

Required verification:

- tests proving edits remove stale term indexes, new terms become searchable at the index level, tags and metadata can be scanned, references create outbound and inbound records, and chunk boundaries include overlap
- `swift build`
- `swift test`

Expected commit:

- `feat: index document chunks and references`

Handoff:

- Record tokenization rules, chunk defaults, and index key families implemented.

## Milestone 6: Contextual Lexical Search

Mission: implement search over lexical indexes with filters, scoring, context chunks, and optional link/backlink context.

Owned areas:

- `search`
- search scoring
- context retrieval
- search result types

Out of scope:

- embeddings
- daemon access
- UI search screens

Required verification:

- tests for multi-term search, ranking, path-prefix filters, tag filters, metadata filters, neighboring context chunks, linked-document hints, and no-result cases
- `swift build`
- `swift test`

Expected commit:

- `feat: add contextual lexical search`

Handoff:

- Document scoring behavior and any limits/defaults used by search.

## Milestone 7: CLI Commands

Mission: expose the core store through thin `metabrain` CLI commands.

Owned areas:

- `Sources/MetaBrainCLI`
- CLI-specific tests if the test harness supports them
- README command examples if they change

Out of scope:

- UI app behavior
- core storage redesign
- daemon/service behavior

Required verification:

- tests or smoke scripts for `init`, `put`, `get`, `search`, `versions`, and `prune`
- `swift build`
- `swift test`
- at least one local CLI round trip using a temporary store

Expected commit:

- `feat: add document store cli commands`

Handoff:

- Include command syntax, known limitations, and examples verified locally.

## Milestone 8: Hardening, Coverage, And Documentation

Mission: tighten edge cases, document the implemented behavior, and make verification expectations explicit.

Owned areas:

- tests across core and CLI
- docs that describe implemented behavior
- small correctness fixes found during hardening

Out of scope:

- new major features
- daemon implementation
- UI implementation beyond keeping the package buildable

Required verification:

- `swift build`
- `swift test`
- coverage command if one exists by then
- final CLI smoke test against a temporary store

Expected commits:

- `test: cover document store edge cases`
- `docs: document implemented store behavior`
- use `fix:` only for isolated bugs found during hardening

Handoff:

- Provide final status, coverage gaps, known limitations, and recommended next milestones.
