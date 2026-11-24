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

To run `mbd` automatically at login, see [Daemon Autostart](docs/daemon-autostart.md).

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

To run `mbd` automatically with a user systemd unit, see
[Daemon Autostart](docs/daemon-autostart.md).

## Why Try It

- **One local memory per workspace.** Commands discover `.metabrain/store.leveldb`
  from the current directory or its nearest containing workspace.
- **Filesystem-like paths.** Documents live at paths such as `/notes/today` or
  `/projects/metabrain/release-plan`, making memory easy to browse and explain.
- **Searchable content.** Titles, paths, and current body passages are indexed for
  lexical search with tag, metadata, and path filters.
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
mb get /AGENTS.md
mb put /notes/today "Remember the lexical store." --tag planning --meta source=agent
mb list /notes --recursive --dates
mb tree --max-depth 2
mb search "lexical store" --tag planning
mb get /notes/today
```

Store-backed commands use the first applicable location in this order:

1. The explicit `--store <path>` option, which can appear before or after the
   subcommand.
2. The `METABRAIN_STORE` environment variable, when set to a nonempty path.
3. The nearest initialized `.metabrain/store.leveldb`, starting in the current
   directory and walking up its ancestors.
4. The current directory's `.metabrain/store.leveldb` when discovery finds no store.

Relative paths are resolved from the current directory. `mb init` and `mb put`
can create a store at the selected location. Other store-backed commands require
an existing store and report the selected location when it is missing.

`mb init` creates `/AGENTS.md` as the first document in a new store. This is a
virtual document inside the selected store. The repository's [AGENTS.md](AGENTS.md)
is for contributors to metaBrain itself. Run `mb init --empty` to start
with zero documents. Reopening a store preserves its contents. A command such
as `mb put` that creates a store implicitly only writes the requested document.
Use `mb ensure-guide` to install the current default in any existing store
missing `/AGENTS.md`. Concurrent calls create a single version. If the guide
already exists, the command preserves its ID, body, and history. Read it with
`mb get /AGENTS.md`; `mb man`, `mb man search`, and the `mb(1)` manual point
to that store-specific guide.

## Agent Workflow

1. Work from the project directory and run `mb get /AGENTS.md` to read local
   guidance. Use `--store` when you need to select another store explicitly.
2. Search what the project already knows before answering or writing. Use
   `--view refs` to shortlist documents and `--view evidence` for passages
   that support an answer. Start with a path, tag, or metadata filter.
3. Verify the passage in context before quoting it. Reopen its `ref` with
   `mb get --ref` and keep the versioned reference with your answer. See
   [Find and reopen evidence](#find-and-reopen-evidence).
4. Save decisions and durable findings under descriptive Markdown paths. Record
   the date, what was learned, and where it came from. Use tags and metadata
   for later filtering and [Markdown citations](#markdown-citations) to link
   related notes. Keep credentials and transient logs out of the store.
5. Update a relevant existing note when the project already has one. Read its
   current version and use a guarded write or check a focused patch first.

For example, save a new decision with a tag and a status filter.

```bash
mb put /tasks/release-checklist.md \
  "Prepare first public release, confirm license, and publish the CLI." \
  --tag release \
  --meta status=active --if-version 0
```

Use `--body-file` for larger notes.

```bash
mb put /research/leveldb-notes.md --body-file notes.md --tag research --if-version 0
```

Use `--if-version` when another writer may change the document between a read
and a write. Version 0 creates the document only if the path is free.
`--body-only` replaces just the body of an existing document and preserves its
title, tags, metadata, references, retention policy, and Markdown opt-in. Omit
those options when using `--body-only`. Ordinary `put` replaces the document's
title, tags, metadata, and references with the values supplied in the request.

```bash
mb put /notes/today "First draft" --if-version 0 --tag planning
mb get /notes/today
mb put /notes/today --body-file revision.md --body-only --if-version 1
# After that update, this different write expects version 1 and finds version 2.
mb put /notes/today "Stale edit" --body-only --if-version 1
```

The JSON and JSONL outputs report `created`, `updated`, or `unchanged` and the
current version. An identical write returns `unchanged` without adding a
version when the version check matches, or on an exact retry when the current
version is one higher than `--if-version`. Other version mismatches fail and
report the expected and current versions. Read the current document and
reapply your change using its current version. Guarded and body-only writes require a
daemon that supports them, or direct access with `mb --no-server`.

For a focused edit, review a unified diff against the current body, then check
it before applying it.

```bash
mb patch /tasks/release-checklist.md --patch-file change.diff --check
mb patch /tasks/release-checklist.md --patch-file change.diff
```

Export a subtree as JSONL, optionally with UTF-8 body files:

```bash
mb dump /tasks --output-dir ./metabrain-dump
```

Dumped body files preserve document path extensions. Extensionless JSON object
or array bodies are written with `.json`; other extensionless bodies use `.md`.

Inspect history and prune retained versions:

```bash
mb versions /tasks/release-checklist.md
mb prune /tasks/release-checklist.md --keep-last 5
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
- `init` creates a store with `/AGENTS.md` by default or opens an existing store.
- `ensure-guide` installs the default agent manual if the selected store lacks it.
- `put` creates or updates a document at a path. Use `--markdown` to index an extensionless note as Markdown.
- `patch` applies a single-file unified diff to an existing document body.
- `move` relocates an existing document to a new path without changing its ID.
- `get` reads documents by path or stable ID and supports retained `--version`,
  Markdown `--block` or `--heading`, and exact evidence `--ref` reads.
- `links` lists outgoing Markdown citations, or incoming citations with `--incoming`.
- `list` lists stored document paths in a virtual folder.
- `tree` prints the stored document path tree.
- `search` ranks current documents using their titles, paths, and body passages
  with optional filters. Use `--view refs` or `--view evidence` for compact
  versioned references or passages.
- `recall` returns relevant passages with versioned citations in a byte-budgeted JSON array.
- `dump` exports documents as JSONL and optional body files.
- `versions` lists retained snapshots for a document.
- `prune` applies a retention policy to document versions.
- `delete` removes a current document and all retained versions.
- `remove-version` removes one retained historical version.

## Search relevance

Search ranks lexical matches across title, path, and current body. Per
occurrence, title matches carry four times the body weight and path matches
carry twice the body weight before frequency saturation. A term found in fewer
documents contributes more to the score. Repeated occurrences of the same term
have diminishing weight.

Document scores use the strongest body passage for each term. A smaller
passage score orders matching excerpts within the document. Ranking uses
`b = 0` in BM25 terms, so passage length does not affect the score. A title or
path match with no matching body terms returns the first body passage, or its
title or path when the body is empty. Path prefix, tag, and metadata filters
restrict results while rarity still reflects the full store.

An older store builds its title and path index on the first search or document
mutation. When using a daemon, upgrade both `mb` and `mbd` to get the new
ranking. The daemon version determines the ranking and index used for
daemon-backed searches.

## Find and reopen evidence

Use `--view refs` to choose documents. This view accepts a query or filters
alone. Use `--view evidence` with a query to read verbatim passages. These
commands use the policy created in the next section. Set `ref` to the value
from an evidence item before running the third command.
Read the surrounding section for qualifiers and exceptions before citing it.

```sh
mb search --tag storage --meta status=current --view refs --limit 5
mb search "nightly backups" --tag storage --view evidence --max-tokens 512
mb get --ref "$ref" --context section --max-tokens 1024
```

Both views return compact JSON with `items` and `truncated`. Each item has
a version-bound `ref` and a `path`. Evidence items also have verbatim `text`.
`--max-tokens` bounds the complete serialized output including its final newline.
It counts one unit per UTF-8 byte, a conservative upper bound for byte-level
tokenizers. `--limit` caps distinct documents. If `truncated` is `true`, some
material was omitted. Narrow the filters or increase the budget when you need
more context. A `ref` identifies a stable document ID and a retained version
with a half-open character range (`ID@VERSION#START-END`) or a named Markdown
block (`ID@VERSION#^BLOCK`). Keep the reference with your quote. It can be
reopened after a move while the cited revision is retained. Range references
also work for plain text.

## Markdown citations

`.md` notes and documents marked with `mb put --markdown` support wikilinks,
relative Markdown links, heading targets, and explicit block IDs. In the
following example the decision arrives before the cited rule.

```sh
mb put /decisions/backups.md 'Follow [[Retention#^keep-last]]. See [exceptions](../policies/Retention.md#exceptions).' --if-version 0
mb links /decisions/backups.md
mb put /policies/Retention.md '# Retention

Keep the last seven nightly backups. ^keep-last

## Exceptions

Keep migration backups until the migration is verified.' --tag storage --meta status=current --if-version 0
mb links /decisions/backups.md
mb links /policies/Retention.md --incoming --block keep-last
mb get /policies/Retention.md --block keep-last
mb get /policies/Retention.md --heading Exceptions
```

Move the policy to see how both citations follow it.

```sh
mb move /policies/Retention.md /archive/Retention-2026.md
mb links /decisions/backups.md
```

`mb links` lists outgoing occurrences by default. `--incoming` lists backlinks.
`--block` filters by the source block on outgoing links and the cited block on
incoming links. If a short name is ambiguous, qualify it with the full store
path, such as `[[/policies/Retention.md#^keep-last]]`. If a link is unresolved,
check that both the target document and any specified heading or block exist.
Use distinct headings and block IDs so each anchor selects one passage.

A resolved occurrence binds to the target's stable ID and follows a move. Its
anchor is checked against the current target body. Deleting the target leaves
the citation unresolved even if a different document later occupies its path.
New occurrences resolve against the current store.
Distinct link labels help preserve each binding when reordering citations.
Repeated occurrences with identical syntax and labels are matched in source order.
The author's Markdown stays verbatim. For an exact quote use the versioned
evidence `ref` or select a retained revision explicitly, for example with
`mb get --id "$document_id" --version 1 --block keep-last`.

Use `--ref-id` for an explicit document relationship that follows its target,
`--ref-path` for a location, or `--ref-url` to record an external source.
These fields can accompany citations in the body.

Keep each citation on one line. Inline Markdown links, reference-style links
with a single-line definition, wikilinks, and their image/embed forms are
indexed. Separate a reference definition from the preceding paragraph with a
blank line. Code examples and comments can contain literal link syntax.

The first citation lookup or document edit upgrades a store with the original
citation index. It checks current Markdown bodies again and preserves the IDs
of surviving occurrences, including links whose targets moved or were deleted.
Upgrade `mb`, `mbd`, and any other writers together before opening that store.
New CLI commands require a daemon that supports the citation routes. For a
store you can open directly, use `mb --no-server`.

### Markdown properties

Flat YAML properties between opening and closing `---` lines participate in
search. A `tags` scalar or list adds tag postings. Other scalar and flat list
values support the existing exact, case-insensitive metadata filters. Explicit
`--meta` wins for the same key. Body edits update these derived indexes, while
`get` and `dump` preserve the original body and the separately supplied fields.
On first access the new code backfills these postings on older stores. Upgrade
the CLI, daemon, and other writers together. A binary using the previous search
index layout rejects searches and ordinary document writes after migration.

## Recall and citations

Use `recall` when you need recorded external sources and character offsets
alongside passages. It uses the same path-prefix, tag, and metadata filters as
`search`.

```bash
mb recall "release rollback" --path-prefix /notes --tag release --meta state=current --limit 3 --max-bytes 4096
```

The output is one compact JSON array. Each item has a `documentID`, `path`,
`version`, `sources`, and `passages`, plus a `title` when present. A passage
contains `text` and half-open `start` and `end` offsets measured in characters
in that version's body. A title or path match can return an opening excerpt.
An empty body can return a citation without passages. Sources come from
external URL references and the `source` metadata field. Cite the path,
version, and passage range. Keep the document ID so you can reopen the same
retained version after a move. Use the recalled ID and version for
`document_id` and `cited_version`.

```bash
mb get --id "$document_id" --version "$cited_version"
```

Recall defaults to at most five distinct documents and 8,192 UTF-8 output
bytes. The byte limit includes the final newline and accepts values from
3 to 1,048,576. A budget that fits only an empty array returns `[]` and a
newline. Historical reads require the cited version to be retained.
When using a daemon, update `mbd` for recall and historical reads, or use
`mb --no-server` for direct access.

## Daemon

`mbd` runs the local daemon surface. The daemon listens on one local endpoint,
serves `/health` with daemon version metadata, and exposes store-backed JSON
endpoints for document operations, including store guides, Markdown citations,
and versioned evidence. See [Agent retrieval routes](SERVER.md#agent-retrieval-routes)
for the citation and evidence API.

```bash
mbd serve --store .metabrain/store.leveldb --socket ~/.metabrain/mbd.sock
mbd serve --store .metabrain/store.leveldb --host 127.0.0.1
mbd service print --user
mbd service install --user --config ~/.config/metabrain/mbd.json --now
mbd service status --user
mbd version
```

One daemon process can serve multiple stores through the same socket or
loopback port. The CLI sends the selected store path with each daemon-backed
request after applying CLI store selection, and the daemon keeps one actor per
active store path. Operations for different
stores can proceed independently, while operations inside one store remain
serialized at that store actor. Idle stores are closed after
`--store-idle-timeout-seconds` seconds, defaulting to 30 seconds, which releases
the underlying LevelDB lock while the daemon keeps listening.

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
workspace store, install a user service, or start `mbd`. See
[Daemon Autostart](docs/daemon-autostart.md) for macOS LaunchAgent, Linux
systemd user service, and Windows Task Scheduler setup.

For the selected store, store-backed `mb` commands automatically make a short
health probe to `http://127.0.0.1:6374`. If a healthy daemon is already
listening there, the command sends the selected store path to the daemon; if the
probe is refused or times out, the command opens the same LevelDB store directly
as before. Use `--no-server` to skip probing and force direct LevelDB access.

```bash
mb put /notes/today "uses a healthy default daemon when one is running"
mb --store ~/work/project/.metabrain/store.leveldb put /notes/today "routes this store through the daemon"
mb --server auto search "probe the default daemon endpoint explicitly"
mb --server ~/.metabrain/mbd.sock put /notes/today "daemon-backed note"
mb --server ~/.metabrain/mbd.sock search "daemon-backed"
mb --server http://127.0.0.1:6374 search "daemon-backed"
mb --no-server search "force direct LevelDB access"
```

For a local serial CLI comparison between direct LevelDB command execution and
daemon-backed command execution, build release binaries and run:

```bash
swift build -c release --product mb --product mbd
Tests/MetaBrainCLITests/cli-server-performance.sh
```

For daemon-backed concurrent CLI read/write coverage, build the debug binaries
and run:

```bash
swift build --product mb --product mbd
Tests/MetaBrainCLITests/cli-server-concurrency.sh
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
The default ZSTD compression level for new writes is `9`. Existing records
remain readable across compression levels. LevelDB paranoid checks are enabled
by default.

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

Virtual paths compare by their exact UTF-8 spelling, including Unicode normalization.
They are case-sensitive, so `/Notes/Today` and `/notes/today` can
both appear in `list`, `tree`, and `dump`. On the first tree read or document
write, metaBrain rebuilds the tree index of an older store from its current
documents. Document IDs and retained versions are preserved. Upgrade any older
CLI, daemon, or app that writes to the same store before using it with this
release. Older binaries use case-folded tree keys, which can produce incorrect
tree listings or exports and damage the derived index if used to write to the
upgraded store.

Implemented behavior includes:

- Async `MetaBrainStore` facade over one explicit store path.
- Stable lowercase ASCII document IDs.
- Normalized absolute slash paths.
- Whole-document writes, path-preserving updates, and explicit moves.
- Unified-diff body patches for existing documents.
- Full-snapshot version history with keep-all, keep-last-N, and time-window
  retention policies.
- Current-body chunking with overlap for search.
- Field-weighted lexical search using BM25-style rarity and frequency saturation.
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

To measure Markdown citation performance, build the release binaries and save a
report. The default run measures latency and response bytes at 1, 32, and 256
links in both direct and daemon mode.

```bash
swift build -c release
python3 Benchmarks/citation-performance.py > citation-report.json
```

The [citation benchmark guide](docs/citation-performance.md) describes the four
workloads and records a baseline for comparison.

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
Yams and its bundled libyaml parser use the MIT license. Their notices are included in [LICENSE](LICENSE).
