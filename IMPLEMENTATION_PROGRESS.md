# Implementation Progress

This file records orchestrator handoff notes for the serial milestone plan in `IMPLEMENTATION_AGENTS.md`.

## Milestone 1: Test Harness And Fixtures

- Status: completed in commit `be72896`.
- Handoff: Swift Testing is the active test framework. `Tests/MetaBrainCoreTests/TemporaryStoreFixture.swift` provides isolated temporary store paths for LevelDB-backed tests.
- Verification: `swift build` and `swift test` passed before the milestone was accepted.

## Milestone 2: Domain Types And Keyspace Helpers

- Status: completed in commit `a7c78d3`.
- Handoff: Public document, reference, search, and retention-policy types are in `MetaBrainCore`; internal key helpers use stable ASCII namespaces matching `ARCHITECTURE.md`.
- Verification: `swift build` and `swift test` passed before the milestone was accepted.

## Milestone 3: Compressed LevelDB Storage Foundation

- Status: completed in commit `1773bff`.
- Handoff: `MetaBrainStore` is an async `final class` facade over `LevelDBStore<StringCodec, DataCodec>`. Values use ZSTD-compressed Codable JSON envelopes with schema version `1`; index keys remain available as raw ordered strings for later milestones.
- Defaults: ZSTD level `3`, adaptive minimum savings ratio `0.10`, Bloom filter `10` bits per key, LRU cache `64 MiB`, and LevelDB native compression disabled so the explicit ZSTD layer owns content compression.
- Lifecycle: opening a locked/already-open store surfaces `MetaBrainStoreError.openFailed` with the store path and underlying message.
- Verification: `swift build` passed; `swift test` passed with 12 tests and 0 failures.

## Milestone 4: Versioned Documents And Retention

- Status: completed locally on 2026-05-17.
- Handoff: `putDocument` creates documents or updates an existing document at the same path with a stable ID. `updateDocument(_:with:)` supports ID/path-referenced updates, including path rename. `getDocument` fetches by ID or path, and `listVersions` returns ordered full-snapshot versions.
- Mutation model: high-level document writes and explicit pruning are serialized through an internal write coordinator. Document writes use one LevelDB batch for the document record, path alias, version record, old path alias deletion, and on-write pruning deletions.
- Retention: `.keepAll` retains every version; `.keepMostRecent(N)` retains at least the current version and treats `N <= 0` as `1`; `.keepWithin(interval)` retains versions inside the time window plus current and pinned versions.
- Scope note: document references are preserved on stored records but are not indexed yet. External URL references resolve as missing for fetch/list/prune, which is intentional for this milestone.
- Verification: `git diff --check` passed; `swift build` passed; `swift test` passed with 19 tests and 0 failures.

## Next Milestone

- Milestone 5: Chunking, Indexing, Metadata, And References.
- Scope: implement current-version chunks, tokenization, lexical term indexes, tag indexes, metadata indexes, and outbound/inbound reference records.
- Guardrails: keep final search ranking, CLI commands, UI changes, embeddings, vectors, and daemon behavior out of this milestone.
