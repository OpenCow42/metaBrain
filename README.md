# metaBrain

`metaBrain` is an early-stage Swift project for building an AI-native memory and knowledge store.

The goal is to help AI tools store, retrieve, discover, and navigate large bodies of content without being limited to loose `.json`, `.jsonl`, and `.md` files scattered through folders. The long-term direction is a compressed NoSQL-style store that remains as discoverable to AI tools as a filesystem while supporting richer structure, indexing, metadata, relationships, and search.

## Project Shape

This repository is a Swift package with three products:

- `MetaBrainCore`: the shared library where storage, indexing, retrieval, and domain behavior should live.
- `metabrain`: the command-line tool.
- `MetaBrainApp`: a SwiftUI app target for a graphical interface.

The CLI and app should stay thin. Shared behavior belongs in `MetaBrainCore` so every interface uses the same underlying model.

The planned storage API is an async `MetaBrainStore` final class: one explicit store handle with internally coordinated writes and concurrent read/search paths where LevelDB supports them. The project will start embedded in the CLI and app; a daemon can come later if multi-process coordination becomes necessary.

## Requirements

- Swift 6.3 or newer
- macOS 14 or newer

## Build

```bash
swift build
```

## Run The CLI

```bash
swift run metabrain init --store .metabrain/store.leveldb
swift run metabrain put --store .metabrain/store.leveldb /notes/today "Remember the lexical store."
swift run metabrain get --store .metabrain/store.leveldb --path /notes/today
swift run metabrain search --store .metabrain/store.leveldb "lexical store"
swift run metabrain versions --store .metabrain/store.leveldb --path /notes/today
swift run metabrain prune --store .metabrain/store.leveldb --path /notes/today --keep-last 3
```

`put` accepts repeated `--tag` and `--meta key=value` options, plus `--body-file`
for larger UTF-8 text. `get`, `versions`, and `prune` accept either `--path` or
`--id`.

## Implemented Store Behavior

The current package implements an embedded LevelDB-backed document store in
`MetaBrainCore`. Values for document records, versions, and current chunks are
Codable JSON envelopes stored through adaptive ZSTD compression. Ordered index
keys remain plain ASCII strings for prefix scans.

Implemented document behavior:

- `MetaBrainStore` is an async `final class` facade over one explicit store path.
- Document IDs are stable lowercase ASCII identifiers; paths normalize
  filesystem-like input to absolute slash paths.
- `putDocument` creates a document at a new path or updates the existing
  document already aliased to that path.
- `updateDocument` can rename a document by ID while preserving its ID, and it
  rejects renames onto another document's path.
- Versions are full snapshots. Retention supports keep-all, keep-most-recent-N,
  and keep-within-time-window policies. Pruning always retains at least the
  current version, and pinned versions are preserved by the pruning helper.
- Current-version chunks use a 4,000-character target with 400-character
  overlap. Empty bodies still have one empty current chunk.
- Lexical search indexes current chunks by normalized alphanumeric terms.
  Results rank by query-term coverage, matched-term frequency, and term
  locality.
- Search filters intersect repeated tag and metadata constraints, and path
  prefixes match the exact path plus descendants only.
- Resolved internal document references create outbound and inbound edge indexes.
  Unresolved path references and external URLs are stored on the document but do
  not create graph edges.

The CLI currently wraps the core store for `init`, `put`, `get`, `search`,
`versions`, and `prune`. It validates one document reference for read/prune
commands, one retention option per write/prune command, and `key=value`
metadata syntax.

## Run The App

```bash
swift run MetaBrainApp
```

The SwiftUI app target is useful for local development. A polished distributable app may later move to an Xcode app project that depends on `MetaBrainCore`.

## Testing Philosophy

Deep automated testing is a cornerstone of the project.

The shared library and CLI-facing logic should strive for 100% coverage. The UI app should strive for 80-90% coverage. As the storage layer grows, tests should make subtle failures visible: missed content, broken indexes, corrupted migrations, incomplete retrieval, and misleading metadata.

## Verification

Run these commands before handing off implementation work:

```bash
swift build
swift test
swift test --enable-code-coverage
Tests/MetaBrainCLITests/cli-smoke.sh
git diff --check
```

`swift test --enable-code-coverage` is the current SwiftPM coverage command. No
repo-specific coverage wrapper exists yet.

## Project Documents

- [MANIFESTO.md](MANIFESTO.md) explains the project vision and principles.
- [ARCHITECTURE.md](ARCHITECTURE.md) records the planned compressed document store design.
- [AGENTS.md](AGENTS.md) defines repository rules for coding agents and contributors.
- [ORCHESTRATOR.md](ORCHESTRATOR.md) defines the supervising agent role for implementation.
- [IMPLEMENTATION_AGENTS.md](IMPLEMENTATION_AGENTS.md) defines the serial subagent milestones and launch prompt.
