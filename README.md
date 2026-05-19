# metaBrain

[![Swift Package Index](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/OpenCow42/metaBrain/badge?type=swift-versions)](https://swiftpackageindex.com/OpenCow42/metaBrain)
[![Swift Package Index](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/OpenCow42/metaBrain/badge?type=platforms)](https://swiftpackageindex.com/OpenCow42/metaBrain)

`metaBrain` is a local document memory for AI agents and tools.

It gives an agent one durable, searchable place to keep notes, source snippets,
task context, metadata, tags, links, and version history. Instead of spreading
state across loose `.md`, `.json`, and scratch files, `metaBrain` stores content
in a compact LevelDB-backed database while keeping it discoverable through a
small CLI.

The first public release ships the `mb` command-line tool and the
`MetaBrainCore` Swift library.

## Install On macOS

Install from the public OpenCow42 Homebrew tap:

```bash
brew tap OpenCow42/tap && brew install mb
```

## Why Try It

- **One local memory per workspace.** The default store lives at
  `.metabrain/store.leveldb`, so agents can find it without configuration.
- **Filesystem-like paths.** Documents live at paths such as `/notes/today` or
  `/projects/metabrain/release-plan`, making memory easy to browse and explain.
- **Searchable content.** Current document chunks are indexed for lexical search
  with tag, metadata, and path filters.
- **Versioned edits.** Updates keep full snapshots, and unified-diff patches can
  change stored documents without rewriting whole bodies by hand.
- **Structured enough to grow.** Documents carry metadata, tags, references, and
  retained versions, while the implementation stays embeddable.

## Requirements

- macOS 15 or newer
- Swift 6.3 or newer when building from source

## Build From Source

```bash
swift build
```

## Try The CLI

Create a store, write a note, browse it, search it, and read it back:

```bash
mb init
mb put /notes/today "Remember the lexical store." --tag planning --meta source=agent
mb list /notes --recursive --dates
mb tree --max-depth 2
mb search "lexical store" --tag planning
mb get /notes/today
```

The default store is `.metabrain/store.leveldb`. Pass `--store <path>` to any
command when a workspace uses a different store location.

## Agent Workflow

Use `put` for durable facts and summaries:

```bash
mb put /tasks/release-checklist \
  "Prepare first public release, confirm license, and publish the CLI." \
  --tag release \
  --meta status=active
```

Use `--body-file` for larger notes:

```bash
mb put /research/leveldb-notes --body-file notes.md --tag research
```

Use `patch` when an agent has a focused unified diff:

```bash
mb patch /tasks/release-checklist --patch-file change.diff
mb patch /tasks/release-checklist --patch-file change.diff --check
```

Export a subtree as JSONL, optionally with UTF-8 body files:

```bash
mb dump /tasks --output-dir ./metabrain-dump
```

Inspect history and prune retained versions:

```bash
mb versions /tasks/release-checklist
mb prune /tasks/release-checklist --keep-last 5
```

Ask the CLI what it can do:

```bash
mb --help
mb help search
mb help dump
```

## Commands

- `init` creates or opens a store.
- `put` creates or updates a document at a path.
- `patch` applies a single-file unified diff to an existing document body.
- `move` relocates an existing document to a new path without changing its ID.
- `get` reads a document by path or stable document ID.
- `list` lists stored document paths in a virtual folder.
- `tree` prints the stored document path tree.
- `search` searches current document content with optional filters.
- `dump` exports documents as JSONL and optional body files.
- `versions` lists retained snapshots for a document.
- `prune` applies a retention policy to document versions.
- `delete` removes a current document and all retained versions.
- `remove-version` removes one retained historical version.

## Project Shape

This repository is a Swift package with two products:

- `MetaBrainCore`: the shared library for storage, indexing, retrieval, and
  domain behavior.
- `mb`: the command-line tool.

The CLI stays thin. Shared behavior belongs in `MetaBrainCore` so every future
interface uses the same underlying model.

The native Apple platform GUI lives in the sibling
[`metaBrainExplorer`](../metaBrainExplorer) repository. It depends on
`MetaBrainCore` and owns app-specific state, presentation, and Apple UI
integration.

## Implemented Store Behavior

The current store is embedded and LevelDB-backed. Document records, versions,
and current chunks are Codable JSON envelopes stored through adaptive ZSTD
compression. Ordered index keys remain plain ASCII strings for prefix scans.
The default ZSTD compression level is `3`, and LevelDB paranoid checks are
enabled by default.

Implemented behavior includes:

- Async `MetaBrainStore` facade over one explicit store path.
- Stable lowercase ASCII document IDs.
- Normalized absolute slash paths.
- Whole-document writes, path-preserving updates, and explicit moves.
- Unified-diff body patches for existing documents.
- Full-snapshot version history with keep-all, keep-last-N, and time-window
  retention policies.
- Current-body chunking with overlap for search.
- Lexical search ranked by term coverage, frequency, and locality.
- Tag, metadata, and path-prefix search filters.
- Internal reference indexes for resolved document links.
- Virtual folder browsing through explicit `tree/` indexes.
- JSONL subtree dumping with optional versioned body files.

For cross-document relationships, prefer document ID references over path
references when the relationship is meant to survive reorganization. A move
preserves the moved document's stable ID, so `--ref-id` links continue to point
at the same document. Path references are useful location aliases, but stored
path reference values are not rewritten automatically when a document moves.

## Development

Run the normal checks before handing off implementation work:

```bash
swift build
swift test
git diff --check
```

The project also has deeper coverage, smoke-test, fuzzing, benchmark, and
release workflows for maintainers. Maintainer smoke tests use `ripgrep`. See
the project documents below when you need those paths.

## Project Documents

- [MANIFESTO.md](MANIFESTO.md) explains the project vision and principles.
- [ARCHITECTURE.md](ARCHITECTURE.md) records the compressed document store design.
- [COMPLEXITY.md](COMPLEXITY.md) estimates command and store-method costs.
- [AGENTS.md](AGENTS.md) defines repository rules for coding agents and contributors.

## License

`metaBrain` is licensed under the BSD 3-Clause License. See [LICENSE](LICENSE).

Third-party dependencies retain their own licenses, including BSD 3-Clause for
`swift-leveldb` and its vendored LevelDB source. Zstandard, provided by `zstd`,
is dual-licensed under BSD or GPLv2; this project uses it under the BSD option.
