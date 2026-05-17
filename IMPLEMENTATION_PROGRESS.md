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
- Defaults: ZSTD level `3`, adaptive minimum savings ratio `0.10`, LevelDB paranoid checks enabled, Bloom filter `10` bits per key, LRU cache `64 MiB`, and LevelDB native compression disabled so the explicit ZSTD layer owns content compression.
- Lifecycle: opening a locked/already-open store surfaces `MetaBrainStoreError.openFailed` with the store path and underlying message.
- Verification: `swift build` passed; `swift test` passed with 12 tests and 0 failures.

## Milestone 4: Versioned Documents And Retention

- Status: completed in commit `a461f2d`.
- Handoff: `putDocument` creates documents or updates an existing document at the same path with a stable ID. `updateDocument(_:with:)` supports ID/path-referenced updates, including path rename. `getDocument` fetches by ID or path, and `listVersions` returns ordered full-snapshot versions.
- Mutation model: high-level document writes and explicit pruning are serialized through an internal write coordinator. Document writes use one LevelDB batch for the document record, path alias, version record, old path alias deletion, and on-write pruning deletions.
- Retention: `.keepAll` retains every version; `.keepMostRecent(N)` retains at least the current version and treats `N <= 0` as `1`; `.keepWithin(interval)` retains versions inside the time window plus current and pinned versions.
- Scope note: document references are preserved on stored records but are not indexed yet. External URL references resolve as missing for fetch/list/prune, which is intentional for this milestone.
- Verification: `git diff --check` passed; `swift build` passed; `swift test` passed with 19 tests and 0 failures.

## Milestone 5: Chunking, Indexing, Metadata, And References

- Status: completed in commit `c2785da`.
- Handoff: current-version chunks are stored under `chunk/current/<id>/<ordinal>` with target size `4000` characters and overlap `400` characters. Empty documents still get one empty current chunk.
- Tokenization: lowercase Unicode alphanumeric runs; punctuation and whitespace split terms. Term index keys de-duplicate duplicate terms per chunk through set-based key generation.
- Indexes: lexical postings use `idx/term/<term>/<id>/<ordinal>`; tag lookups use `idx/tag/<tag>/<id>`; metadata lookups use `idx/meta/<key>/<value>/<id>`.
- References: document ID references and path references that resolve at write time create outbound and inbound records under `idx/ref/out` and `idx/ref/in`. External URLs and unresolved paths remain on the stored document but are not indexed as document edges.
- Mutation model: document writes atomically delete stale current chunks, stale term/tag/metadata indexes, and stale reference edges before writing fresh records in the same LevelDB batch.
- Verification: `git diff --check` passed; `swift build` passed; `swift test` passed with 24 tests and 0 failures.

## Milestone 6: Contextual Lexical Search

- Status: completed in commit `f3c24ca`.
- Handoff: `MetaBrainStore.search(_:)` uses lexical `idx/term` postings, OR-merges matching chunks, and ranks results by query-term coverage, matched-term frequency, and term locality within the chunk.
- Filters: path-prefix filtering is segment-aware; tag and metadata filters intersect the existing `idx/tag` and `idx/meta` document ID sets before result scoring.
- Results: matching chunk text is returned as `snippet`; neighboring current chunks are returned in `context`. Optional linked-document and backlink hints are returned as stable `.documentID(...)` references from `idx/ref/out` and `idx/ref/in`.
- Limits: empty queries, normalized queries with no terms, and non-positive limits return no results. Search reads multiple keys without explicit snapshot wiring, matching current store read patterns.
- Verification: `git diff --check` passed; `swift build` passed; `swift test` passed with 29 tests and 0 failures.

## Milestone 7: CLI Commands

- Status: completed in commit `a25c467`.
- Handoff: `metabrain` now exposes thin commands over `MetaBrainCore`: `init`, `put`, `get`, `search`, `versions`, and `prune`.
- Syntax: commands accept `--store` with a default of `.metabrain/store.leveldb`; `get`, `versions`, and `prune` accept exactly one of `--path` or `--id`; `put` accepts a body argument or `--body-file`, repeated `--tag`, repeated `--meta key=value`, and retention flags.
- Smoke coverage: `Tests/MetaBrainCLITests/cli-smoke.sh` runs a temporary-store round trip through all required commands.
- Limitations: CLI output is human-readable only. JSON output mode, CLI reference editing, and SwiftPM-integrated CLI tests remain follow-up hardening candidates.
- Verification: `git diff --check` passed; `swift build` passed; `swift test` passed with 29 tests and 0 failures; `Tests/MetaBrainCLITests/cli-smoke.sh` passed.

## Milestone 8: Hardening, Coverage, And Documentation

- Status: completed on 2026-05-17.
- Handoff: added targeted hardening tests for path collision safety, missing-document pruning, empty-body chunk behavior, stale tag/metadata index removal, unresolved/external reference indexing, and segment-aware path-prefix search boundaries.
- CLI smoke: extended `Tests/MetaBrainCLITests/cli-smoke.sh` to verify filtered no-result output plus invalid metadata and missing-reference validation failures against a temporary store.
- Documentation: `README.md` now records implemented store behavior, current CLI validation behavior, the verification workflow, and the native SwiftPM coverage command.
- Coverage: `swift test --enable-code-coverage` is the available coverage command; no repo-specific coverage wrapper exists. Current generated JSON summary reported line coverage at about 76.0%.
- Commit: hardening tests and CLI smoke checks are in `a562fed`.
- Verification: `git diff --check` passed; `swift build` passed; `swift test` passed with 35 tests and 0 failures; `swift test --enable-code-coverage` passed with 35 tests and 0 failures; `Tests/MetaBrainCLITests/cli-smoke.sh` passed.

## Final Status

- Current coverage goal: `MetaBrainCore` and `MetaBrainCLI` should reach and maintain 100.00% line coverage. Use `Scripts/check-coverage.sh` as the combined SwiftPM + CLI coverage gate.
- Recommended follow-up: add SwiftPM-integrated CLI tests or a dedicated CLI test target, and add JSON CLI output if downstream tools need stable machine-readable responses.
