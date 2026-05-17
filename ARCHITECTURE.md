# Architecture Notes

This document captures the planned storage architecture for `metaBrain`. The implementation will come later; these notes are the intended direction for `MetaBrainCore`.

## Storage Foundation

`metaBrain` will use LevelDB through `swift-leveldb` and `swift-leveldb-zstd`.

The useful shape of the dependency is:

- LevelDB provides ordered keys, efficient point lookups, prefix/range scans, atomic write batches, snapshots, Bloom filters, LRU cache options, approximate range sizes, and compaction.
- `ZstdCodec` wraps another typed codec, such as `JSONCodec<T>`, so serialization and compression stay separate.
- `ZstdCodec` defaults to ZSTD level `3` with adaptive storage: it stores compressed bytes only when compression saves enough space.
- Write batches can commit compressed records and plain ordered index keys atomically.

The core store should use ZSTD-compressed Codable JSON envelopes for document records, version records, and chunk records. Index keys and tiny index values should stay raw and ordered so LevelDB can scan them efficiently.

## Public Store Shape

The core API should expose an async reference type:

```swift
public final class MetaBrainStore: Sendable {
    public func putDocument(_ input: DocumentInput) async throws -> StoredDocument
    public func getDocument(_ reference: DocumentReference) async throws -> StoredDocument?
    public func search(_ query: SearchQuery) async throws -> [SearchResult]
    public func listVersions(of reference: DocumentReference) async throws -> [DocumentVersion]
    public func prune(_ request: PruneRequest) async throws -> PruneResult
}
```

`MetaBrainStore` should not be a public actor and should not be a struct.

- A struct would hide the fact that an opened LevelDB database is a resource with lifecycle and locking.
- A public actor would be safe but would over-serialize reads and searches that LevelDB can handle concurrently.
- A final class gives the CLI and UI one clear store handle while letting the implementation choose internal coordination.

Internally, high-level mutations should be serialized by a private write coordinator, likely an internal actor. Reads and searches may run concurrently and should use LevelDB snapshots when they need a consistent view across multiple keys.

## Process Model

LevelDB allows concurrent access from multiple threads inside one process, but a database may only be opened by one process at a time.

The v1 model is:

- CLI: each command opens the store, performs one operation, and exits.
- UI app: keep one `MetaBrainStore` instance alive and call it with `async`/`await`.
- Multiple processes: do not promise direct concurrent access to the same store.
- Future daemon: may own one store instance and expose process-safe access to many tools.

If a CLI command cannot open a store because another process owns it, surface a clear lock/open error rather than trying to bypass LevelDB's process lock.

## Document Model

Documents are text-first records with metadata and references.

- Use stable internal document IDs.
- Use filesystem-like paths as discoverable aliases.
- Allow paths to change without changing document identity.
- Store references between documents as first-class edges.
- Allow unresolved path references and external URL references.

Versioning should store full snapshots for v1. This is intentionally simple, reliable, and compatible with compression. Delta storage can be added later behind the same version API if measurements justify it.

Retention should be configurable:

- keep all versions
- keep the most recent `N` versions
- keep versions inside a time window

On-write pruning should apply the configured policy after edits. Explicit prune operations should also be available. Pinned versions, once implemented, must not be pruned automatically.

## Key Layout

Use one LevelDB database with stable ASCII key namespaces and the default bytewise ordering.

Planned key families:

- `doc/id/<id>`: compressed document metadata and current-version pointer
- `doc/path/<normalized-path>`: raw document ID lookup
- `ver/<id>/<sequence>`: compressed full document version
- `chunk/current/<id>/<ordinal>`: compressed current-version search chunk
- `idx/term/<term>/<id>/<ordinal>`: lexical search posting
- `idx/tag/<tag>/<id>`: tag lookup
- `idx/meta/<key>/<value>/<id>`: metadata lookup
- `idx/ref/out/<source-id>/<target-id>`: outbound document reference
- `idx/ref/in/<target-id>/<source-id>`: backlink lookup
- `tree/<parent-path>/<name>`: filesystem-like discovery

Document writes should use one write batch to update the document record, version record, current chunks, lexical indexes, metadata indexes, path aliases, and reference indexes together.

## Search

V1 search should be lexical and contextual, not vector-based.

Search should:

- tokenize document text into normalized terms
- index current-version chunks by term
- support filters by path prefix, tags, and metadata
- merge posting lists by document and chunk
- score results by term coverage, frequency, and locality
- fetch matching chunks plus neighboring context chunks
- optionally include linked documents and backlinks as contextual hints

Embedding and vector search should remain a future extension point. The v1 store should not depend on embedding models or external services.

## Compression And Performance

Use ZSTD as the primary compression layer for content-bearing values. Keep index records small and raw.

See [COMPLEXITY.md](COMPLEXITY.md) for the current big-O estimates of the CLI
commands and the core store methods they call.

Default store tuning should start conservatively:

- ZSTD compression level `3`
- adaptive compression savings threshold `0.10`
- LevelDB paranoid checks enabled
- Bloom filter around `10` bits per key
- LRU cache around `64 MiB`
- chunk target around `4000` characters
- chunk overlap around `400` characters

These are starting defaults, not sacred constants. They should be measured against real corpora before becoming compatibility commitments.

## Testing Expectations

The storage layer needs deep tests before it becomes trusted project infrastructure.

Tests should cover:

- create, update, fetch, and delete-like pruning flows
- path aliases and stable document IDs
- compressed record round trips
- lexical index insertion and removal on edit
- search ranking and contextual chunks
- references and backlinks
- version listing, fetching, and pruning policies
- snapshot consistency for multi-key reads
- clear failure behavior when the store cannot be opened

In this `metaBrain` repository, `MetaBrainCore` and CLI-facing logic should
strive for 100% coverage. UI-app coverage expectations belong in the sibling
app repository that owns that UI.
