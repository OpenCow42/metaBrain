# metaBrain

[![Swift Package Index](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/OpenCow42/metaBrain/badge?type=swift-versions)](https://swiftpackageindex.com/OpenCow42/metaBrain)
[![Swift Package Index](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/OpenCow42/metaBrain/badge?type=platforms)](https://swiftpackageindex.com/OpenCow42/metaBrain)

🪟 Windows is supported alongside macOS and Linux.

`metaBrain` is a local document memory for AI agents and tools.

It gives an agent one durable, searchable place to keep notes, source snippets,
task context, metadata, tags, links, and version history. Instead of spreading
state across loose `.md`, `.json`, and scratch files, `metaBrain` stores content
in a compact LevelDB-backed database while keeping it discoverable through a
small CLI.

The first public release ships the `mb` command-line tool, the `mbd` local
daemon, and the `MetaBrainCore` Swift library.

## Install On macOS

Install from the public OpenCow42 Homebrew tap:

```bash
brew tap OpenCow42/tap && brew install mb
```

The Homebrew package installs both `mb` and `mbd`. It does not start the daemon
automatically.

## Install On Ubuntu

Install from the public OpenCow42 APT repository on Ubuntu 24.04 or 26.04.
The package name is `metabrain`, and it installs both `mb` and `mbd`.

Ubuntu 24.04:

```bash
echo 'deb [trusted=yes] https://opencow42.github.io/apt-repo ubuntu24.04 main' | sudo tee /etc/apt/sources.list.d/opencow.list
sudo apt update
sudo apt install metabrain
```

Ubuntu 26.04:

```bash
echo 'deb [trusted=yes] https://opencow42.github.io/apt-repo ubuntu26.04 main' | sudo tee /etc/apt/sources.list.d/opencow.list
sudo apt update
sudo apt install metabrain
```

The current Ubuntu package is published for `amd64`. The repository uses
`trusted=yes` until signed APT metadata is available.

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

- macOS 15 or newer, or Ubuntu 24.04 / 26.04 on amd64
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

Dumped body files preserve document path extensions. Extensionless JSON object
or array bodies are written with `.json`; other extensionless bodies use `.md`.

Inspect history and prune retained versions:

```bash
mb versions /tasks/release-checklist
mb prune /tasks/release-checklist --keep-last 5
```

Ask the CLI what it can do:

```bash
mb version
mb --help
mb help search
mb help dump
```

## Commands

- `version` prints the current release tag, probes the default local daemon, and
  checks GitHub for newer releases.
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

## Daemon

`mbd` runs the local daemon surface. The daemon opens one configured
`MetaBrainCore` store for its lifetime, serves `/health` with daemon version
metadata, and exposes store-backed JSON endpoints for version, init, put, patch, move, get, list,
tree, search, dump, versions, prune, delete, and remove-version.

```bash
mbd serve --store .metabrain/store.leveldb --socket ~/.metabrain/mbd.sock
mbd serve --store .metabrain/store.leveldb --host 127.0.0.1
mbd service print --user
mbd version
```

`mb version` reports the CLI version and also probes the default local daemon at
`http://127.0.0.1:6374`. If the daemon is reachable, the output includes the
daemon endpoint and version. If it is not reachable, the command still exits
successfully and reports the daemon as unavailable. Use `mb version --server
<socket-or-url>` to query a specific daemon, `mb version --server auto` to probe
the default local daemon explicitly, or `mb version --no-server` for the CLI
version only.

Unix sockets are the default local transport on macOS and Linux. Loopback HTTP
is available with `--host 127.0.0.1 --port 6374`. Port `6374` is the default
loopback port because it reads as `META` in leetspeak and avoids commonly used
mainstream service ports.

Package managers install the daemon binary passively; they do not create a
workspace store, install a user service, or start `mbd`. Use
`mbd service print --user` or `mbd service install --user --config <path>` when
you want an inspectable user LaunchAgent or systemd unit.

For the default store, store-backed `mb` commands automatically make a short
health probe to `http://127.0.0.1:6374`. If a healthy daemon is already
listening there, the command uses it; if the probe is refused or times out, the
command opens LevelDB directly as before. Commands with an explicit `--store`
stay direct unless daemon mode is requested.

```bash
mb put /notes/today "uses a healthy default daemon when one is running"
mb --server auto search "probe the default daemon endpoint explicitly"
mb --server ~/.metabrain/mbd.sock put /notes/today "daemon-backed note"
mb --server ~/.metabrain/mbd.sock search "daemon-backed"
mb --server http://127.0.0.1:6374 search "daemon-backed"
mb --no-server search "force direct LevelDB access"
```

`--body-file`, `--patch-file`, and `--output-dir` remain client-side CLI
features. The daemon receives JSON request bodies and never reads or writes
those paths on behalf of a client.

## Project Shape

This repository is a Swift package with three products:

- `MetaBrainCore`: the shared library for storage, indexing, retrieval, and
  domain behavior.
- `mb`: the command-line tool.
- `mbd`: the local daemon executable.

The CLI and daemon stay thin. Shared behavior belongs in `MetaBrainCore`, while
server-facing transport DTOs live in the internal `MetaBrainServerSupport`
target when they are not part of the core storage model.

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

### Store Format Compatibility

Record envelopes include an internal schema version. This tool treats schema
version `1` as the current writable format. Later schema versions are parsed as
future versions instead of invalid versions.

When a store contains future-version records, commands should still read them
when the existing key layout and Codable payload remain compatible. This lets
older `mb` binaries inspect a newer store where possible. Mutating commands
refuse to overwrite, prune, or delete future-version records and return a clear
upgrade-required store error instead of silently downgrading newer data. In
practice, `get`, `list`, `tree`, `search`, `dump`, and `versions` can continue
to work for compatible future records, while `put`, `patch`, `move`, `prune`,
`delete`, and `remove-version` fail at the affected newer records.

Compatibility is best-effort, not a promise that every future format can be
read by older binaries. A future release may add required payload fields or a
new key layout that old tools cannot decode. Older tools should fail
gracefully in those cases.

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
