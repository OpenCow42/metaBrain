# Mark II Task Queue

This is the serial task queue for implementing Mark II. The orchestrator should
keep this file current as tasks move from `pending` to `active`, `review`, and
`done`.

Each task should be assigned to one subagent or completed directly by the
orchestrator. Do not start a dependent task until its prerequisites are committed
and validated.

## Milestones

- M0: Baseline and fixtures.
- M1: Chunking and identity primitives.
- M2: V2 records and reconstruction.
- M3: Indexing, history, migration, and pruning.
- M4: Patch locality.
- M5: CLI/release compatibility.
- M6: Benchmarks, coverage, and default enablement.

## Task Template

```text
ID:
Status:
Depends on:
Goal:
Allowed scope:
Validation:
Done when:
```

## Global Validation Gate

Every task inherits this validation gate in addition to its task-specific checks:

- the full automated test suite should pass, including full `swift test`;
- touched `MetaBrainCore` and CLI-facing behavior should be at 100% coverage;
- if the coverage command is unavailable or a temporary gap is unavoidable, the
  subagent must report the exact exception and the orchestrator must record a
  follow-up before marking the task `done`.

## M0 Baseline And Fixture Groundwork

### T00 Baseline Audit

Status: `pending`

Depends on: none

Goal: Map current v1 storage, chunking, version, search, prune, dump, and CLI
flows to concrete files and tests.

Allowed scope: documentation notes and focused characterization tests only.

Validation:

- `swift test`
- existing CLI smoke tests, if present

Done when:

- the orchestrator knows the files each later task must touch;
- any missing characterization tests for current behavior are listed or added.

### T01 Current-Base Performance Capture

Status: `pending`

Depends on: T00

Goal: Capture reproducible current-base benchmark results before Mark II code
changes alter the baseline.

Allowed scope: benchmark scripts, benchmark docs, generated result artifacts only
if the repository already tracks them.

Validation:

- benchmark command recorded;
- Swift version, OS, CPU, memory, git commit, and build configuration recorded.

Done when:

- baseline output covers `put`, `get`, `patch`, `search`, `history`/`versions`,
  `dump`, `prune`, large Markdown, JSON, JSONL, and repeated local edits.

## M1 Chunking And Identity Primitives

### T02 Add Swift-Markdown Dependency

Status: `pending`

Depends on: T00

Goal: Add `swift-markdown` to `Package.swift` and wire it only where the chunker
implementation needs it.

Allowed scope: package files and minimal dependency smoke tests.

Validation:

- `swift package resolve`
- `swift test`

Done when:

- dependency resolution is committed separately from behavior changes.

### T03 Hash And Identity Helpers

Status: `pending`

Depends on: T00

Goal: Implement streaming SHA-256 helpers and Mark II identity helpers for chunk,
segment, manifest, occurrence, and lazy full-file hashing.

Allowed scope: core helper files and tests.

Validation:

- tests prove `chunkID == chunkSHA256 == sha256(exact chunk body bytes)`;
- tests prove metadata changes do not alter chunk hashes;
- tests prove duplicate chunk bodies share content hash but have distinct
  occurrence identities;
- tests prove `segmentID == segmentSHA256` and segment ordinal/debug fields do
  not affect segment identity.

Done when:

- identity helpers are reusable by chunkers, storage, and indexes.

### T04 Chunker Protocol And Plain Text Chunker

Status: `pending`

Depends on: T03

Goal: Define the internal chunker protocol and implement plain-text chunking with
exact reconstruction and forced split behavior.

Allowed scope: core chunking files and tests.

Validation:

- exact reconstruction tests for line endings and whitespace;
- chunk token/term cap tests;
- small, empty, and oversized document fixtures.

Done when:

- later Markdown/JSON/JSONL chunkers can implement the same protocol.

### T05 Markdown Chunker And Fallback

Status: `pending`

Depends on: T02, T04

Goal: Implement Markdown semantic chunking with `swift-markdown` and linear
fallback when parsing or source mapping cannot produce reliable semantic chunks.

Allowed scope: Markdown chunker, fixtures, and tests.

Validation:

- heading, list, table, block quote, fenced code, empty document, and very large
  section tests;
- parse/source-map fallback tests;
- exact reconstruction tests;
- forced split tests.

Done when:

- malformed Markdown never blocks `put`, `get`, `patch`, `search`, or `dump`.

### T06 Front Matter Extraction

Status: `pending`

Depends on: T05

Goal: Preserve front matter as `markdownFrontMatter` and extract the Mark II
`2.0.0` simple YAML subset into namespaced derived metadata.

Allowed scope: front matter parser/extractor, metadata mapping, tests.

Validation:

- exact preservation tests;
- scalar, inline array, and block array extraction tests;
- unsupported YAML fallback tests;
- explicit metadata precedence tests;
- patching front matter updates only derived front matter metadata.

Done when:

- complex YAML is skipped or diagnosed without rejecting normal document
  operations.

### T07 JSONL Chunker

Status: `pending`

Depends on: T04

Goal: Implement JSONL chunking where each physical line is a chunk and strict
mode validates non-empty lines as independent JSON values.

Allowed scope: JSONL chunker and tests.

Validation:

- one-line-per-chunk tests;
- repeated identical line tests for occurrence identity;
- line terminator reconstruction tests;
- strict validation failure/fallback tests.

Done when:

- JSONL fixtures reconstruct exactly and duplicate lines index independently in
  later indexing tasks.

### T08 JSON Conservative Hybrid Chunker

Status: `pending`

Depends on: T04

Goal: Implement conservative hybrid JSON chunking: top-level object members or
array elements by default, recursive JSON Pointer-like splitting only for
oversized values, and full-document fallback when exact formatting ownership is
ambiguous.

Allowed scope: JSON chunker and tests.

Validation:

- top-level object/array chunk tests;
- oversized nested value split tests;
- JSON Pointer-like logical path tests;
- delimiter/whitespace fallback tests;
- exact reconstruction tests.

Done when:

- JSON chunking preserves source text and does not become a full JSON formatter.

### T09 Format Detection And Persistence

Status: `pending`

Depends on: T04, T05, T07, T08

Goal: Implement internal document format selection with explicit stored metadata
taking precedence over path and content inference.

Allowed scope: format detector, document metadata integration, tests.

Validation:

- explicit format wins after rename;
- inferred format is persisted on v2 writes;
- Markdown, plain text, JSON, and JSONL inference tests.

Done when:

- no public `--format` CLI flag is required for Mark II `2.0.0`.

## M2 V2 Records And Reconstruction

### T10 V2 Domain Types And Codecs

Status: `pending`

Depends on: T03

Goal: Add schema version 2 domain types for document metadata, chain manifests,
manifest segments, chunk records, and version records.

Allowed scope: core storage model and codec tests.

Validation:

- encode/decode tests;
- schema version branching tests;
- zstd level 9 assertion for content-bearing v2 records.

Done when:

- v1 and v2 record decoding are explicit and cannot be confused.

### T11 V2 Put And Get

Status: `pending`

Depends on: T09, T10

Goal: Teach `put` to write v2 chains and `get` to reconstruct exact complete
bodies from manifests, segments, and chunks.

Allowed scope: core put/get storage path and tests.

Validation:

- exact reconstruction across all formats;
- no full body duplicated in v2 document/version records;
- chunk and segment reuse tests for repeated writes;
- lazy `fileSHA256` refresh when `get` streams the full body.

Done when:

- v2 can be written and read internally without changing public CLI behavior.

### T12 Current Chunk Pointers

Status: `pending`

Depends on: T11

Goal: Maintain `chunk/current/<documentID>/<ordinal>` pointers for ordered scans
and occurrence identity.

Allowed scope: current pointer writes/deletes and tests.

Validation:

- inserted, removed, moved, and duplicate chunks update current pointers
  correctly;
- ordered scans avoid one point lookup per chunk when possible.

Done when:

- current-version traversal works without decoding full manifests for every
  index operation.

## M3 Indexing, History, Migration, And Pruning

### T13 Format-Aware Search Indexing

Status: `pending`

Depends on: T11, T12

Goal: Move search indexing from fixed windows to Mark II chunk occurrences.

Allowed scope: core indexing/search tests.

Validation:

- duplicate content occurrence tests;
- stale occurrence cleanup tests;
- heading/logical path context tests;
- search quality fixture comparison against v1 where useful.

Done when:

- postings use `documentID + ordinal + chunkID` and can assemble neighboring
  context from manifests.

### T14 History Command Rename

Status: `pending`

Depends on: T11

Goal: Rename public `versions` command to `history`, remove `versions`, and keep
the previous listing output shape.

Allowed scope: CLI command registration, help text, README examples, tests.

Validation:

- `history` smoke tests;
- `versions` unknown-command test;
- output-shape compatibility test;
- `version` still works.

Done when:

- command discovery and docs no longer advertise `versions`.

### T15 Lazy V1 To V2 Migration

Status: `pending`

Depends on: T11, T14

Goal: Read v1 documents without mutation and create a new retained v2 revision on
the next write.

Allowed scope: core storage compatibility and tests.

Validation:

- v1 read tests;
- v1 write creates v2 retained revision;
- `history`, `get`, `search`, and `dump` tolerate mixed v1/v2 histories.

Done when:

- migration is visible in history and never happens silently during reads.

### T16 V2 Prune And Delete Reachability

Status: `pending`

Depends on: T11, T13, T15

Goal: Add reachability-based garbage collection for v2 manifests, segments, and
chunks during prune and delete.

Allowed scope: prune/delete core paths and tests.

Validation:

- retained manifest scan tests;
- reachable unique chunk accounting tests;
- shared chunk/segment preservation tests;
- unreachable segment/chunk deletion tests;
- current version cannot be pruned.

Done when:

- prune avoids decoding chunk text and deletes only unreachable records.

## M4 Patch Locality

### T17 Internal Chunk-Targeted Patch Fields

Status: `pending`

Depends on: T11, T13

Goal: Add internal `chunkID` and `chunkOrdinal` patch fields without exposing new
public CLI flags in `2.0.0`.

Allowed scope: core patch request types and tests.

Validation:

- existing CLI patch calls compile and behave the same;
- internal targeted patch tests can address a chunk by ID or ordinal.

Done when:

- public CLI compatibility is preserved.

### T18 Localized Patch Write Path

Status: `pending`

Depends on: T17

Goal: Apply targeted patches to one chunk, re-chunk only affected text, splice
new chunk pointers, and rewrite changed segments/indexes.

Allowed scope: core patch implementation and tests.

Validation:

- one-chunk rewrite tests;
- split/merge chunk tests;
- heading/front matter metadata update tests;
- unchanged chunk IDs stay stable;
- changed segment count remains local in ordinary cases.

Done when:

- targeted patch cost tracks changed chunks and changed segments, not full body
  size.

### T19 Untargeted Patch Localization

Status: `pending`

Depends on: T18

Goal: Map ordinary unified diffs to affected chunk occurrences when safe, while
falling back to full-document patching when mapping is ambiguous.

Allowed scope: patch mapping, line/offset helpers, tests.

Validation:

- first/middle/final chunk hunk tests;
- ambiguous hunk fallback tests;
- byte offset and line mapping tests;
- compatibility with existing `patch --check`.

Done when:

- existing CLI `patch` benefits from locality where safe but remains correct
  everywhere.

## M5 CLI And Release Compatibility

### T20 Version And ZSTD Release Defaults

Status: `pending`

Depends on: T10, T14

Goal: Set release version behavior to `2.0.0` and make ZSTD level 9 the tested
default for content-bearing values.

Allowed scope: version constants, compression config, tests, docs.

Validation:

- `mb version` reports `2.0.0`;
- zstd level 9 tests;
- no remaining docs claim level 3 as the Mark II default.

Done when:

- release constants and compression defaults match the spec.

### T21 Dump Compatibility

Status: `pending`

Depends on: T15, T16

Goal: Keep `dump` behavior compatible for v1 and v2 current documents and
history without adding integrity checks in `2.0.0`.

Allowed scope: dump path and tests.

Validation:

- current dump tests;
- retained history dump tests;
- mixed v1/v2 dump tests;
- no default hash verification output.

Done when:

- `dump` reconstructs exact bodies and output shape remains compatible.

### T22 Full CLI Compatibility Sweep

Status: `pending`

Depends on: T14, T15, T18, T20, T21

Goal: Run and fill compatibility coverage for `put`, `get`, `patch`, `search`,
`dump`, `prune`, `delete`, `remove-version`, `history`, and `version`.

Allowed scope: CLI tests and small compatibility fixes.

Validation:

- full CLI test target;
- output schema/text shape tests;
- exit status tests.

Done when:

- the only intentional CLI break is `versions` to `history`.

## M6 Benchmarks, Coverage, And Default Enablement

### T23 Mark II Benchmark Suite

Status: `pending`

Depends on: T18, T21

Goal: Add Mark II benchmark fixtures and compare them to the captured current-base
baseline.

Allowed scope: benchmark target, scripts, benchmark docs.

Validation:

- large Markdown one-line patch benchmark;
- JSONL repeated-line ingest and single-line edit benchmark;
- `get`, `history`, `dump`, `search`, and `prune` benchmarks;
- segment target and token cap comparison runs.

Done when:

- performance acceptance criteria from [MARKII.md](MARKII.md) have evidence.

### T24 Coverage Closure

Status: `pending`

Depends on: T22, T23

Goal: Close test gaps toward the 100% coverage target for `MetaBrainCore` and
CLI-facing behavior.

Allowed scope: tests and small coverage-oriented refactors.

Validation:

- coverage command recorded;
- uncovered Mark II core paths listed or covered;
- all tests pass.

Done when:

- remaining uncovered behavior is documented and accepted, or coverage target is
  reached.

### T25 Default V2 Write Enablement

Status: `pending`

Depends on: T23, T24

Goal: Enable schema version 2 as the default Mark II write format only after
correctness, compatibility, and performance gates pass.

Allowed scope: feature switch/default write path, release notes, final tests.

Validation:

- full `swift test`;
- benchmark acceptance summary;
- clean mixed v1/v2 migration path;
- final docs review.

Done when:

- Mark II is ready to merge as the `2.0.0` storage model.
