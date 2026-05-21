# metaBrain Mark II

Mark II is a storage and patching revision for `MetaBrainCore`. The visible CLI
shape should stay familiar, but the core should stop treating each document body
as one monolithic string for every edit. Document input becomes format-aware
chunks, Markdown gets structural parsing, patches can target one chunk, and the
store can rebuild the same complete document body on demand for existing CLI
commands.

## Goals

- Parse Markdown with `swift-markdown` instead of fixed character windows.
- Support format-aware chunking for Markdown, plain text, JSON, and JSONL.
- Store a document as an ordered chain of chunk records plus document metadata.
- Let `patch` update a specific chunk without rewriting every chunk in the
  document.
- Release Mark II as `2.0.0`; the `version` command must report `2.0.0`.
- Rename the document history command from `versions` to `history` in `2.0.0`;
  `versions` is not available in Mark II.
- Keep the remaining existing `put`, `get`, `patch`, `search`, `dump`, `prune`,
  `delete`, `remove-version`, and `version` CLI behavior stable for Mark II.
- Use ZSTD level 9 for content-bearing values.
- Measure Mark II against the current base implementation in detail before
  treating the new storage shape as a win.

## Non-Goals

- Mark II does not introduce vector search.
- Mark II does not require a daemon or multi-process store owner.
- Mark II does not require users to know about chunks or document formats to
  read or write normal documents.
- Mark II does not replace full-document compatibility APIs. `StoredDocument.body`
  remains reconstructable.
- The first Mark II release does not expose chunk targeting or format selection
  as required CLI concepts.

## Dependency

Add `swift-markdown` to `Package.swift` and depend on its `Markdown` product from
`MetaBrainCore`.

Reference: <https://github.com/swiftlang/swift-markdown>

The package describes itself as a Swift package for parsing, building, editing,
and analyzing Markdown documents. Its parser is powered by GitHub-flavored
Markdown's `cmark-gfm`, and its markup tree uses immutable, thread-safe,
copy-on-write value types. This matches the Mark II need: parse once, derive
stable semantic chunks, and only replace the substructure that changed.

Prefer a released version constraint once the exact compiler compatibility is
confirmed. As of 2026-05-21, GitHub lists Swift-Markdown 0.8.0 as the latest
release.

## Current State

The current store keeps a `StoredDocument` with the full body and creates search
chunks with fixed character windows around 4,000 characters with 400 characters
of overlap. `patchDocument` applies a unified diff to `document.body`, then
writes a full document update. That regenerates the current chunk records and
indexes even when the diff only touches one section.

Current records are schema version 1. The current entry metadata format tag is
`metabrain.document.v1`, and `MetaBrainRecordEnvelope.currentSchemaVersion` is
`1`.

That model is simple and correct, but it makes small edits expensive for large
Markdown files and makes chunk identity unstable across unrelated edits.

## Mark II Storage Model

Keep one LevelDB database and ordered ASCII key prefixes. Mark II encoded
documents must use record schema version 2 and a document format tag such as
`metabrain.document.v2`.

Suggested key families:

- `doc/id/<id>`: compressed document metadata, current chain pointer, and public
  fields that are not chunk bodies.
- `doc/path/<normalized-path>`: raw document ID lookup.
- `doc/meta/<id>`: compressed access counters, flags, and schema metadata.
- `chain/<id>/<sequence>`: compressed document chain manifest for a version.
- `segment/<id>/<segment-id>`: compressed manifest segment containing an ordered
  run of chunk pointers.
- `chunk/<id>/<chunk-id>`: compressed chunk body and chunk metadata.
- `chunk/current/<id>/<ordinal>`: raw or tiny pointer from current ordinal to
  chunk ID for ordered scans.
- `ver/<id>/<sequence>`: compressed version record pointing at a chain manifest.
- Existing `idx/*`, `tree/*`, and reference keys continue to describe the
  current version.

The document record should not duplicate the complete body. It should identify
the current version and the current chain manifest. The full body is materialized
by reading the manifest, reading its ordered segments, and concatenating segment
chunks in order.

## Record Versions

Use explicit on-disk record versions:

- schema version 1: current base encoding. Document records and version records
  carry full document bodies and current fixed-window chunk records.
- schema version 2: Mark II encoding. Document records point at chain manifests,
  chain manifests point at manifest segments, manifest segments point at chunk
  records, and chunks carry format-aware body slices.

The v2 implementation should not silently reinterpret v1 records as v2 records.
Decoding should branch on the envelope schema version and route to the correct
reader. New Mark II writes should emit v2 records for document records, version
records, chain manifests, manifest segments, and chunk records. Index keys can
keep their existing raw layout when compatible.

`DocumentEntryMetadata.formatTag` should move from `metabrain.document.v1` to
`metabrain.document.v2` when a document is written in Mark II form. During
lazy migration, a store may contain both v1 and v2 documents.

## Chain Manifest And Segments

The chain manifest is the compact root map of a document version. It points to
ordered manifest segments rather than storing every chunk pointer inline:

```swift
struct DocumentChainManifest: Codable, Equatable, Sendable {
    var documentID: DocumentID
    var sequence: UInt64
    var createdAt: Date
    var segments: [DocumentManifestSegmentPointer]
    var manifestSHA256: String
    var fileSHA256: String?
    var byteCount: Int
    var characterCount: Int
    var chunkCount: Int
    var segmentTargetChunkCount: Int
}

struct DocumentManifestSegmentPointer: Codable, Equatable, Sendable {
    var ordinal: UInt32
    var segmentID: String
    var segmentSHA256: String
    var chunkCount: Int
    var byteRange: Range<Int>
    var debugLabel: String?
}

struct DocumentManifestSegment: Codable, Equatable, Sendable {
    var documentID: DocumentID
    var segmentID: String
    var segmentSHA256: String
    var ordinal: UInt32
    var chunks: [DocumentChunkPointer]
    var byteRange: Range<Int>
}

struct DocumentChunkPointer: Codable, Equatable, Sendable {
    var ordinal: UInt32
    var chunkID: String
    var chunkSHA256: String
    var byteRange: Range<Int>
    var format: DocumentBodyFormat
    var chunkKind: DocumentChunkKind
    var headingPath: [String]
    var logicalPath: [String]
    var debugLabel: String?
}
```

The manifest and its segments are intentionally separate from chunk bodies. A new
version can reuse unchanged segment IDs and chunk IDs, then only write new
segments and chunk records for changed runs. This gives snapshot-style version
semantics while avoiding full body rewrites and avoiding a single giant manifest
value for large JSONL files.

Manifest segments should be content-addressed pointer runs:

- `segmentID` equals `segmentSHA256`.
- `segmentSHA256` is computed from a canonical representation of the ordered
  `DocumentChunkPointer` run.
- The canonical segment payload must exclude `segmentID`, `segmentSHA256`,
  `debugLabel`, segment ordinal, and other cache or diagnostic fields.
- The canonical segment payload must include each pointer's `chunkID`,
  `chunkSHA256`, byte range, format, chunk kind, heading path, logical path, and
  chunk count in order.

Excluding segment ordinal keeps unchanged pointer runs reusable after inserts or
deletes elsewhere in the document. The chain manifest's segment pointers record
where each segment sits in a specific revision.

Initial segment tuning:

- target `256` chunk pointers per manifest segment;
- split changed regions into new segment records when a patch changes, inserts,
  or removes chunks;
- allow smaller edge segments;
- merge or rebalance tiny adjacent segments if repeated edits fragment a
  document too much;
- before merging the Mark II PR, benchmark and tune the target segment size
  against Markdown, plain text, JSON, and JSONL corpora.

## Chunk Record

A chunk is a format-aware body slice plus enough metadata to preserve ordering,
diagnostics, and search behavior:

```swift
enum DocumentBodyFormat: String, Codable, Sendable {
    case markdown
    case plainText
    case json
    case jsonl
}

enum DocumentChunkKind: String, Codable, Sendable {
    case markdownFrontMatter
    case markdownSection
    case markdownBlock
    case textParagraph
    case textWindow
    case jsonObjectMember
    case jsonArrayElement
    case jsonScalar
    case jsonlLine
    case forcedSplit
}

enum DocumentChunkingStrategy: String, Codable, Sendable {
    case markdownSemantic
    case markdownFallback
    case plainText
    case jsonStructural
    case jsonFallback
    case jsonlLine
}

enum DocumentParseStatus: String, Codable, Sendable {
    case parsed
    case fallback
    case notApplicable
}

struct DocumentChunkRecord: Codable, Equatable, Sendable {
    var documentID: DocumentID
    var chunkID: String
    var createdAt: Date
    var text: String
    var chunkSHA256: String
    var format: DocumentBodyFormat
    var chunkKind: DocumentChunkKind
    var headingPath: [String]
    var sourceStartUTF8Offset: Int
    var sourceEndUTF8Offset: Int
    var logicalPath: [String]
    var chunkingStrategy: DocumentChunkingStrategy
    var parseStatus: DocumentParseStatus
    var parseDiagnostic: String?
    var tokenCountHint: Int?
}
```

Chunk IDs should be plain content hashes over the complete chunk body:
`chunkID = chunkSHA256 = sha256(exact chunk body bytes)`. The hashed bytes are
the exact UTF-8 source bytes that the chunk contributes to reconstruction,
including whitespace, comments, delimiters owned by the chunk, and line
terminators when present.

Do not hash the stored chunk record as a whole, and do not include document ID,
document path, version sequence, segment ordinal, chunk ordinal, byte offsets,
timestamp, heading path, logical path, parse status, token hints, debug labels,
or other metadata in `chunkID`. Those fields may change because of renames,
inserts before the chunk, parser improvements, metadata repair, or debugging
updates even when the chunk body bytes are unchanged. Debuggability should come
from manifest and pointer metadata, not from polluting content identity.

Manifest and segment pointers should make file structure debuggable while
keeping `chunkID` pure. Useful metadata includes document ID, version sequence,
segment ordinal, chunk ordinal, byte range, format, chunk kind, heading path,
logical path, `chunkSHA256`, `segmentSHA256`, and optional human-readable
`debugLabel` values. Debug labels are not identity and may be regenerated.

Example debug rendering:

```text
/notes/spec v12 seg=3 chunk=42 id=3f9a12c0 kind=markdownSection bytes=18420..20110 path="Mark II > Storage"
```

Pure content-hash IDs keep unchanged chunks stable across versions and make
content reuse straightforward. The surrounding manifest structure keeps the file
explainable.

Content identity is not occurrence identity. The same `chunkID` may appear more
than once in one document when content repeats, such as duplicate JSONL lines,
repeated Markdown blocks, or repeated JSON scalar values. Current-version
indexes and cleanup logic must identify searchable occurrences with
`documentID + ordinal + chunkID`, not with `chunkID` alone. Conceptual current
index keys should follow this shape:

```text
idx/term/<term>/<documentID>/<ordinal>/<chunkID>
idx/ref/<target>/<documentID>/<ordinal>/<chunkID>
chunk/current/<documentID>/<ordinal> -> chunkID
```

`chunkID` still identifies the stored bytes. `ordinal` identifies where that
occurrence appears in the current reconstructed body. The combined occurrence
identity lets search, reference cleanup, and metadata cleanup handle duplicate
chunk content without deleting or merging the wrong posting.

The manifest must store SHA-256 digests for every chunk, every manifest segment,
and the manifest root itself. Each `chunkSHA256` is computed over the exact
stored chunk bytes, including line terminators when present. `segmentSHA256` is
computed as the content address for the segment pointer run described above.
`manifestSHA256` is computed over a canonical representation of the manifest
identity and ordered segment pointer data, including each segment's SHA-256.

`fileSHA256` is optional lazy metadata. It is computed over the exact bytes that
`get` or `dump` would reconstruct for that revision, but Mark II writes should
not be forced to scan the whole document only to populate it. It is acceptable
for a manifest to have chunk hashes, segment hashes, and a manifest hash without
a complete-file hash.

Hashing must use a scanning/streaming API. Implementations should feed bytes into
SHA-256 hashers incrementally while reading, chunking, patching, or
reconstructing the document. When an operation already reads the whole file body,
such as `get`, `dump`, integrity verification, or a full-body write, the store
should use that opportunity to compute `fileSHA256` and persist it as metadata.
It should not require the entire file body to be loaded into memory at once.

## Document Formats And Chunkers

Mark II should be Markdown-first, not Markdown-only. The core should choose a
chunker from an explicit document format when one is supplied, then fall back to
path extension and lightweight content detection.

Format selection policy:

- explicit document format metadata wins when available;
- API metadata can set or update that explicit format;
- future CLI format flags, if added after `2.0.0`, can map to the same metadata;
- path extensions such as `.md`, `.markdown`, `.txt`, `.json`, and `.jsonl`
  provide the next hint when no explicit format is stored;
- JSONL detection may accept documents where every non-empty line parses as one
  JSON value when no explicit format is stored;
- JSON detection may accept one complete top-level JSON value when no explicit
  format is stored;
- otherwise, use plain text.

When Mark II writes a schema version 2 revision, it should store the selected
document format as explicit metadata on the document and/or manifest summary.
That makes future writes stable: renaming `/notes/spec.md` to `/notes/spec`
should not silently change chunking from Markdown to plain text. Inference is a
bootstrap and compatibility path, not something that should override an existing
explicit format. If a future API or CLI command intentionally changes the
format, that change should create a normal new revision and should be covered by
chunking, reconstruction, and search-index tests.

All chunkers must preserve exact source text. A chunker may parse structure to
find safe boundaries, but it must not pretty-print, normalize, reorder keys,
change line endings, or remove whitespace during storage.

Format-specific rules:

- Markdown: parse with `swift-markdown` and chunk by block-level semantic
  structure.
- Plain text: chunk by paragraphs or line groups, with a maximum byte/character
  target and no overlap unless search quality requires a small context window.
- JSONL: treat each physical line as a chunk. The chunk text includes its line
  terminator when present so reconstruction is exact. The logical path can be
  the zero-based line number. Validation should parse each non-empty line as an
  independent JSON value when strict JSONL mode is requested.
- JSON: use a conservative hybrid strategy. Parse as one JSON value and prefer
  stable top-level structural boundaries: one top-level object member or array
  element per chunk when practical. Nested JSON Pointer-like chunking should
  happen only when a top-level value would otherwise exceed the byte,
  character, or token cap. Scalar or tiny JSON documents can remain one chunk.
  Recursive splits must record JSON Pointer-like logical paths for debugging and
  patch mapping.

JSON deserves extra caution: patching one structural chunk must preserve the
surrounding commas, indentation, and whitespace. The first implementation should
fall back to full-document patching for JSON when a targeted patch would make
delimiter ownership ambiguous, when a recursive split cannot be mapped back to
exact source ranges, or when preserving original formatting cannot be guaranteed.
JSONL is the cleanest structured format because line boundaries are also record
boundaries.

All chunkers must enforce a maximum token/term count per chunk. If a semantic
unit exceeds that cap, the chunker should split at the safest format-specific
boundary and mark unavoidable splits as `forcedSplit`. This protects search
scoring from very large chunks, because locality scoring may be quadratic in the
number of terms inside one chunk. The first Mark II implementation should choose
the cap by benchmark and record the chosen value in tests.

## Markdown Chunking Rules

Use `Document(parsing:)` from `swift-markdown` as the primary parser. Markdown
parsing is advisory for chunk boundaries, not a requirement for document
validity. Chunking should operate over block-level Markdown nodes when parsing
and source mapping succeed.

Initial rules:

- A heading starts a new section chunk. The chunk includes the heading and the
  block content until the next heading at the same or higher level.
- Very large sections may split at paragraph, list item, thematic break, table,
  block quote, or fenced code block boundaries.
- Fenced code blocks stay intact unless they exceed a hard maximum. If they do,
  split only with explicit metadata that marks the chunk as a forced split.
- YAML front matter, if present at the beginning of the document, becomes a
  dedicated `markdownFrontMatter` chunk and is preserved as exact source text.
- Markdown source order is authoritative. Rendered or normalized Markdown should
  not be used as the stored body unless the user explicitly asks for formatting.

The chunker should preserve exact source text. Parsing is for boundaries and
metadata, not for rewriting user Markdown.

## Front Matter Policy

Markdown front matter should be both first-class derived metadata and a normal
document chunk.

The front matter chunk is the source of truth for reconstruction and patching.
It must keep the original delimiters, whitespace, key order, comments, quoting,
and line endings. Mark II should not rewrite or normalize front matter unless
the user edits that text.

When front matter is parseable, the store should also extract it into derived
metadata for filtering, search, summaries, and debugging. Derived front matter
metadata should be namespaced, for example `frontmatter.title`,
`frontmatter.tags`, and `frontmatter.status`, so it does not silently overwrite
explicit API or CLI metadata. Explicit document metadata remains canonical when
there is a conflict.

Front matter extraction is opportunistic. If front matter parsing fails, the
chunk still stores and reconstructs exactly, while derived metadata extraction is
skipped or marked with a diagnostic. A malformed front matter block must not
block `put`, `get`, `patch`, `search`, or `dump`.

For Mark II `2.0.0`, derived metadata extraction should support a small,
explicit YAML front matter subset rather than full YAML:

- front matter must begin at byte offset `0` with a line containing exactly
  `---`;
- front matter closes at the next line containing exactly `---` or `...`;
- keys are simple identifiers such as `title`, `tags`, `status`, and `date`;
- values can be plain strings, quoted strings, booleans, numbers, or dates
  stored as strings unless the existing metadata model has a compatible typed
  field;
- inline string arrays such as `tags: [swift, notes]` are supported;
- block string arrays such as `tags:` followed by indented `- swift` entries are
  supported.

Nested maps, anchors, aliases, custom YAML tags, multiline scalar blocks, and
other complex YAML features are not extracted in `2.0.0`. Encountering
unsupported YAML should preserve the front matter chunk exactly, skip derived
metadata extraction for the unsupported fields or the whole block, and record a
short diagnostic. It should not require adding a full YAML parser dependency for
the first Mark II release.

Patches that change the `markdownFrontMatter` chunk should refresh only the
derived front matter metadata and indexes affected by that chunk. Patches outside
front matter should not require rescanning or reindexing the derived front matter
fields.

## Markdown Parse Fallback

Markdown parse failures or source-mapping failures must not block `put`, `get`,
`patch`, `search`, or `dump`. `metaBrain` is a document database, so exact text
preservation is more important than semantic chunk quality.

Fallback flow:

1. Try semantic Markdown chunking with `swift-markdown`.
2. If parsing, source mapping, resource limits, or parser diagnostics prevent
   reliable semantic chunks, keep the document format as `markdown`.
3. Mark produced chunks with `chunkingStrategy: .markdownFallback`,
   `parseStatus: .fallback`, and an optional short `parseDiagnostic`.
4. Chunk with safe plain-text rules: paragraph boundaries first, then line
   groups, then bounded forced splits if needed.
5. Preserve exact source bytes and line endings.

Fallback chunks are still normal chunks. Search indexes, manifest segments,
`get`, `dump`, and future `--chunk-id` patching should work against them. If a
later revision parses successfully, it may return to `markdownSemantic` chunks
and record that as an ordinary new revision.

Local validation after a chunk-targeted Markdown patch can be low. It is enough
to re-run the chunker and record whether the result used semantic Markdown
chunking or fallback chunking. A failed Markdown parse should degrade chunk
quality, not reject the write, unless the input is not valid text or violates a
hard resource limit.

## Patch Flow

Extend `DocumentPatchRequest` so callers may optionally target a chunk:

```swift
public struct DocumentPatchRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReference
    public var unifiedDiff: String
    public var chunkID: String?
    public var chunkOrdinal: UInt32?
    public var retention: VersionRetentionPolicy?
}
```

Behavior:

1. Resolve the document reference to a current chain manifest and its affected
   manifest segment records.
2. If `chunkID` or `chunkOrdinal` is provided, read only that chunk body and
   apply the unified diff to the chunk text.
3. Re-parse or validate the patched chunk text with the document's chunker. For
   Markdown, use `swift-markdown`; for strict JSONL, parse the patched line as a
   JSON value; for JSON, validate the affected value or fall back to
   full-document validation; for plain text, validation is mostly boundary and
   encoding checks.
4. Re-chunk the patched text. If it still maps to one logical chunk, replace the
   pointer in a new segment for the next manifest.
5. If the local edit creates multiple chunks or changes heading boundaries,
   splice the new chunk pointers into new segment records at the original
   ordinal.
6. Rebuild only affected search indexes and current chunk ordinal pointers.
7. Write the new manifest, changed segments, changed chunks, version record,
   document metadata, access metadata, and affected indexes in one LevelDB write
   batch.

If no chunk target is provided, `patch` remains a document-level operation for
CLI compatibility. The implementation may reconstruct the full body and apply
the existing patch algorithm, then re-chunk the result.

## CLI Behavior

Mark II is a major `2.0.0` release. It intentionally breaks one command name:
`versions` is renamed to `history`, and `versions` is not available in Mark II.
Other existing CLI behavior should remain stable so scripts only need to update
the history-listing command name.

Mark II CLI contract:

- `history` is the public command for listing retained document revisions;
- `versions` is removed and should fail as an unknown command;
- existing flags and positional arguments keep the same meaning;
- existing default output formats stay the same;
- JSON and JSONL output schemas keep the same field names and compatible value
  meanings;
- text output remains stable enough for users and tests that already parse it;
- exit status behavior and validation errors should not change except where a
  current bug is intentionally fixed and documented;
- `mb put` accepts the same body inputs and silently chooses an internal chunker;
- `mb get` prints or returns the same complete reconstructed body;
- `mb patch` keeps accepting the same `--patch-file` and `--check` flows;
- `mb search` returns contextual chunks as it does today, now backed by
  format-aware chunk records internally;
- `mb dump` can still emit full documents and retained history, without adding
  integrity-check behavior in `2.0.0`;
- `mb version` reports `2.0.0` for the Mark II release.

Do not expose new public chunk-targeting or format-selection CLI concepts in the
Mark II `2.0.0` release. Chunk IDs, chunk ordinals, document formats, and storage
schemas are internal details unless the user is using an explicitly experimental
build or hidden diagnostic command. Format detection should happen without adding
mandatory `--format` usage.

History command:

```console
mb history /notes/spec
```

`history` should keep the existing version-listing output shape so the command
rename is the only intended break. Help text, README examples, shell smoke tests,
and command discovery should name `history`, not `versions`.

## Version History

Keep snapshot semantics at the API level. A version is still a complete logical
document at a point in time, but the physical representation is a chain manifest
plus chunk records. This preserves the retention and pruning model:

- `keepAll`: keep every manifest, segment, and chunk reachable from any retained
  manifest.
- `keepMostRecent(N)`: delete manifests outside the retained set, then garbage
  collect unreferenced segments and chunks.
- `keepWithin`: same reachability rule after selecting retained manifests.
- Current version must never be pruned.
- Pinned versions, once implemented, keep their manifest and reachable segments
  and chunks.

Pruning now needs segment and chunk reachability passes. It should run inside the
same write coordination path as other mutations.

## Compression

Mark II defaults must use ZSTD level 9:

```swift
zstdCompressionLevel: Int32 = 9
```

Apply this to compressed content-bearing values:

- document records
- document metadata records
- chain manifests
- manifest segments
- version records
- chunk records

Keep ordered index keys and tiny index values raw unless measurements show a
clear benefit. Keep adaptive compression unless benchmarks show that always-on
compression is better at level 9. The architectural docs and tests should stop
claiming level 3 as the default.

## Migration

Schema v1 stores can migrate lazily to schema version 2:

1. When reading a schema version 1 document, continue decoding the full body
   without rewriting storage or creating a revision.
2. On the next write to that document, create a new retained document revision
   whose records are schema version 2. The migration is part of the write and is
   visible in `history` like any other document update.
3. `get`, `search`, `history`, and `dump` should tolerate both v1 full snapshots
   and v2 chain manifests during the transition.
4. A future explicit migration command can compact a whole store to v2 by
   creating schema version 2 revisions for selected documents, then garbage
   collecting obsolete v1 chunk records only when retention rules allow it.

Avoid a required up-front migration for existing stores.

## Search And Indexing

Search should index format-aware chunk occurrences instead of fixed character
windows. Each current-version posting should reference `documentID + ordinal +
chunkID` so duplicate chunk contents remain distinct. Result assembly can fetch
neighboring chunks from the manifest when context is requested. Markdown chunks
can use heading metadata, JSON chunks can use logical paths, JSONL chunks can use
line numbers, and plain text chunks can use paragraph or window ordinals.

Search complexity depends on chunk token counts. Chunkers must enforce the
maximum token/term cap described above so scoring stays bounded even for large
Markdown sections, large JSON values, or dense plain-text paragraphs.

When a targeted patch changes one chunk, delete and rewrite only:

- the current ordinal pointer for changed ordinals,
- lexical postings for changed occurrences,
- reference edges if changed occurrences alter explicit references,
- metadata postings if front matter or extracted metadata changed.

If heading structure changes, affected ordinals after the splice may need pointer
updates, but unchanged chunk bodies and their postings should be reused whenever
possible.

## Performance Baseline

Mark II should be measured against the current base implementation, not just
validated for correctness. The existing `MetaBrainCoreBenchmarks` target is the
starting point. It already covers small puts, multi-chunk puts, large updates,
one-line patches in large documents, search, tree/list/dump, and long version
history operations.

Before replacing the current store path, capture baseline results on `main` and
preserve them in a reproducible form. At minimum, record:

- git commit, Swift version, OS, CPU, memory, and build configuration,
- benchmark command and package dependency revisions,
- wall clock, throughput, and variance for each benchmark,
- store directory byte size before and after each scenario,
- number of LevelDB keys and approximate bytes by key family where practical,
- compressed payload sizes for document records, versions, manifests, and
  chunks,
- write amplification proxies such as number of keys written/deleted per
  operation and total encoded batch bytes.

Mark II benchmarks should run side by side with equivalent base scenarios. The
important comparison is not only raw speed; it is the cost curve as document size,
chunk count, edit locality, retained history, and search corpus size grow.

Add benchmark cases for these dimensions:

- Markdown shape: flat prose, heading-heavy notes, deeply nested sections,
  large lists, tables, block quotes, fenced code blocks, and front matter.
- Non-Markdown shape: plain text paragraphs, dense logs, JSON arrays, JSON
  objects with large nested values, and JSONL record streams.
- Document size: small single-chunk, medium multi-section, large 100 KB, very
  large 1 MB, and stress documents beyond normal interactive use.
- Patch locality: first chunk, middle chunk, final chunk, heading-only edit,
  code-block edit, edit that splits one chunk, edit that merges or deletes a
  section, JSONL single-line edit, JSON member or array-element edit, and
  untargeted full-document patch compatibility.
- Version history: repeated one-line patches with `keepAll`, `keepMostRecent`,
  and explicit `prune`.
- Search: common terms, rare terms, filtered metadata/tag searches, context
  assembly from neighboring chunks, linked-document and backlink expansion.
- Manifest segment size: compare the starting target of `256` chunk pointers
  with smaller and larger targets before merging the Mark II PR.
- Chunk token cap: benchmark search scoring against large Markdown, JSON, JSONL,
  and plain-text chunks, then choose and test a maximum token/term count per
  chunk before merging.
- Read paths: `get` full reconstruction, `dump` current, `dump` all history, and
  `history` listing.
- Compression: compare ZSTD level 3 current-base behavior, level 9 Mark II
  defaults, and any measured adaptive-compression tradeoffs.

Expected Mark II wins:

- targeted patch write time should scale with changed chunk size plus manifest
  and affected-index work, not full body size;
- unchanged chunk IDs and chunk records should remain stable across unrelated
  edits;
- retained history storage should grow mostly with changed chunks and manifests,
  not one full snapshot or one full flat manifest per edit;
- search reindexing after targeted patches should touch only affected chunks in
  ordinary cases.

Costs to watch:

- Markdown parsing may make initial `put` slower than fixed character chunking;
- full-body `get` and `dump` now read multiple chunk records and may regress for
  small documents unless batching and ordering are tight;
- ZSTD level 9 may improve storage size while increasing CPU time;
- manifest and chunk pointer scans may add overhead to `history`, `prune`, and
  migration;
- format-aware chunking may produce too many small records for heading-heavy
  files;
- chunks that exceed the token cap can make search scoring too expensive.

Performance acceptance should be explicit before Mark II becomes the default:

- no severe regression for small document `put`, `get`, `patch --check`, and
  `search`;
- clear improvement for one-line targeted patches in large Markdown documents;
- clear reduction in retained-history storage growth for repeated local edits;
- search result quality and context remain at least as useful as current chunks;
- any ZSTD level 9 CPU cost is justified by storage reduction or user-visible
  write/read behavior.

## Testing Plan

All tests should pass before Mark II is merged. The target for `MetaBrainCore`
and CLI-facing behavior is 100% coverage, matching the existing repository
expectation.

Add focused tests for:

- Markdown chunk boundaries for headings, lists, tables, block quotes, code
  fences, front matter, empty documents, and very large sections.
- Front matter is preserved as an exact `markdownFrontMatter` chunk and is also
  extracted into namespaced derived metadata when parseable.
- Front matter parse failures preserve exact text, skip or diagnose derived
  metadata extraction, and do not block normal document operations.
- Front matter extraction supports only the documented Mark II `2.0.0` subset:
  simple keys, scalar values, inline string arrays, and block string arrays.
- Unsupported YAML front matter features, such as nested maps, anchors, aliases,
  custom tags, and multiline scalar blocks, preserve exact text and fall back
  without rejecting the document.
- Explicit document metadata wins over derived front matter metadata when field
  names overlap.
- Markdown parse/source-mapping failure falls back to plain-text-style chunking,
  records fallback metadata, preserves exact text, and keeps put/get/patch/search
  usable.
- Plain text, JSON, and JSONL chunk boundaries, including exact reconstruction
  of line endings and whitespace.
- Explicit stored document format wins over path/content inference on later
  writes, including after document renames.
- Inference chooses Markdown, JSONL, JSON, or plain text when no explicit
  document format is stored, and the selected format is persisted in schema
  version 2 metadata.
- JSONL uses one physical line per chunk and validates non-empty lines in strict
  JSONL mode.
- JSON chunking uses the conservative hybrid policy: top-level object members or
  array elements by default, recursive JSON Pointer-like splitting only for
  oversized values, and deliberate full-document patch fallback when exact
  delimiter or whitespace ownership is ambiguous.
- Chunkers enforce and test a maximum token/term count per chunk, using
  `forcedSplit` when a format-specific safe boundary is unavailable.
- Full-body reconstruction preserving exact source bytes.
- Targeted patch that rewrites one chunk and leaves unrelated chunk IDs stable.
- Targeted patch that splits one chunk into multiple chunks.
- Targeted patch that changes a heading and updates heading metadata.
- Targeted patch that changes front matter updates derived metadata postings
  without reindexing unrelated chunks.
- Manifest segments store `segmentSHA256`, reuse unchanged segment IDs, and
  start with a target size of `256` chunk pointers.
- `segmentID` equals `segmentSHA256` for the canonical ordered chunk-pointer run
  and does not include segment ordinal or debug/cache fields.
- Chunk IDs are plain SHA-256 content hashes, while manifest/segment/chunk
  pointer metadata keeps the document structure debuggable.
- `chunkID` and `chunkSHA256` are identical hashes of exact chunk body bytes, not
  hashes of the stored chunk record or its metadata.
- Current-version search, reference, and metadata postings use occurrence
  identity: `documentID + ordinal + chunkID`, so duplicate chunk contents are
  indexed and cleaned up independently.
- Benchmark results before merge justify keeping or tuning the 256-pointer
  segment target.
- Untargeted `patch` compatibility.
- Mark II CLI compatibility against stable command behavior, flags, output
  schemas, text output, and exit statuses, with the intentional `versions` to
  `history` command break.
- `history` replaces `versions` and preserves the previous version-listing output
  shape.
- `versions` is not available in Mark II and fails as an unknown command.
- `version` reports `2.0.0` for the Mark II release.
- ZSTD default level is 9.
- schema version 1 read compatibility and lazy schema version 2 conversion on
  write.
- Lazy migration creates a new retained document revision and does not mutate
  schema version 1 records invisibly during reads.
- Mark II writes encode document, version, chain manifest, manifest segment, and
  chunk records with schema version 2 and `metabrain.document.v2` entry
  metadata.
- Pruning removes unreachable segments and chunks, and retains records reachable
  from current or pinned versions.
- Pruning tests cover retained manifest pointer scans and reachable unique chunk
  accounting, not only deleted record counts.
- Baseline-vs-Mark-II benchmark fixtures are reproducible and cover the
  performance dimensions listed above.

## Implementation Order

1. Add `swift-markdown` dependency and a chunker protocol with Markdown,
   Markdown fallback, plain text, JSON, and JSONL implementations behind tests.
2. Add schema version 2 chunk, manifest segment, and chain manifest domain types.
3. Capture current-base benchmark results and add Mark II benchmark scenarios.
4. Teach `put` and `get` to write and reconstruct v2 documents.
5. Move search indexing to format-aware chunks.
6. Add internal targeted patch request fields and chunk-level patch flow while
   preserving the existing CLI patch surface.
7. Add schema version 1 / schema version 2 compatibility and lazy migration.
8. Rename CLI `versions` to `history`, remove `versions`, and update docs,
   command discovery, and smoke tests.
9. Set the release version to `2.0.0` and verify `mb version` reports it.
10. Change ZSTD default level to 9 and update assertions/docs.
11. Add pruning reachability for manifest segment and chunk records.
12. Compare Mark II benchmarks against the captured baseline before enabling v2
    as the default write format.
13. Require passing tests and target 100% coverage before merging the Mark II PR.

## Future 2.1.0 CLI Work

Mark II `2.0.0` should not change `dump` behavior to verify retained
`fileSHA256`, `manifestSHA256`, `segmentSHA256`, or `chunkSHA256` values by
default. `dump` remains a compatibility-preserving export path.

Plan a future `2.1.0` release with explicit commands for verification,
scrubbing, structure inspection, and optional advanced chunk/document-format
controls.

Candidate integrity command shapes:

```console
mb verify /notes/spec
mb verify /notes/spec --history
mb scrub /notes/spec
mb scrub /notes/spec --repair
```

The verification command should check manifest, segment, chunk, and optional
complete-file hashes without changing export output. The scrubbing command should
scan store records, report unreachable or corrupt records, and only repair or
delete data when the user explicitly asks for repair behavior.

Candidate structure inspection command shapes:

```console
mb inspect /notes/spec --chunks
mb inspect /notes/spec --segments
mb inspect /notes/spec --history
```

The inspection command should expose the debuggable structure around pure hash
IDs: path, version sequence, segment ordinal, chunk ordinal, short chunk hash,
byte range, logical path, chunk kind, parse status, and fallback diagnostics when
present.

Candidate chunk-targeted patch shapes:

```console
mb patch /notes/spec --chunk-id <chunk-id> --patch-file change.diff
mb patch /notes/spec --chunk 7 --patch-file change.diff
```

For the first public chunk-targeting surface, prefer `--chunk-id` for stable
identity across reordering and use ordinal-based `--chunk` only if benchmark and
UX testing show that ordinal targeting is safe enough. Chunk-targeting flags
should remain out of `2.0.0`.

Candidate explicit format selection shapes:

```console
mb put /logs/events --format jsonl --body-file events.jsonl
mb put /data/config --format json --body-file config.json
mb put /notes/plain --format text --body-file notes.txt
```

Explicit `--format` should also wait until after `2.0.0`; Mark II should infer
formats internally for the initial release.
