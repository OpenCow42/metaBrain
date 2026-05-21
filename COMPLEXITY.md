# Complexity Notes

This document estimates the big-O behavior of the core methods behind each
`metabrain` CLI command as implemented today. It is meant to guide users and
contributors toward the calls that can become expensive as a store grows.

## Notation

- `N`: number of stored documents.
- `A`: number of virtual tree entries, including directories and documents.
- `B`: size of the current document body being read or written.
- `B_old`: size of the previous body for an updated document.
- `C`: number of current chunks for a document.
- `C_old`: number of previous chunks for an updated document.
- `T`: number of distinct indexed terms in a document or query context.
- `Q`: number of distinct query terms.
- `P`: total postings scanned for the query terms.
- `P_patch`: size of a unified diff patch.
- `M`: number of unique matching document/chunk candidates before `--limit`.
- `G`: number of tag and metadata filters on a search query.
- `F`: total tag and metadata filter postings scanned.
- `B_match`: total body bytes decoded while scoring matched search candidates.
- `C_match`: total current chunk records scanned while scoring matched candidates.
- `R`: number of references on a document.
- `E`: number of reference edges scanned for linked-document or backlink output.
- `V`: number of versions for one document.
- `H`: total encoded body/snapshot bytes across one document's versions.
- `L`: number of virtual tree entries on the new and old path branches touched
  by one write.
- `D`: total path segments processed while maintaining or traversing tree records.
- `K`: number of direct children listed for one virtual directory.
- `D_dump`: number of current documents selected by one dump path.
- `H_dump`: total body bytes emitted by a dump operation, including expanded
  retained versions when requested.
- `S`: total number of LevelDB keys in the store.
- `X`: number of keys matched by one LevelDB prefix scan.
- `X_tree`: total `doc/path` descendant keys scanned while maintaining affected
  tree branch entries.
- `P_delete`: number of version keys deleted by a prune or explicit document
  delete operation.
- `K_delete`: number of document, chunk, index, reference, backlink, and tree
  keys cleaned up by one explicit document delete.

LevelDB stores keys in sorted order and exposes efficient seek/iterator scans.
Point lookups are not truly `O(1)`: they are usually small with cache and Bloom
filters, but they still depend on memtable/table lookup state, block cache, and
the number of sorted-table levels/files that must be consulted. Prefix scans
seek to the first prefix key and then call `Next()` until the prefix no longer
matches, so they are best thought of as `O(seek(S) + X)` logical LevelDB work
plus the Swift wrapper's copying, decoding, materialization, and any extra
sorting done by `MetaBrainStore`.

The checked LevelDB behavior comes from the vendored dependency and upstream
LevelDB docs:

- `LevelDBStore.scanEncodedPrefix` creates an iterator, seeks to the prefix,
  copies every matching key and value into an array, and then returns it.
  `scanEncodedPrefixKeys` avoids value reads when callers only need keys.
- LevelDB documents `WriteBatch` as atomic and useful for bulk updates, but the
  batch itself still stores every edit before the write is submitted.
- LevelDB block cache stores uncompressed blocks, and bulk reads should consider
  `fill_cache = false` so large scans do not evict hotter cached data.
- Bloom filters reduce unnecessary disk reads for point `Get()` calls, but they
  do not make broad prefix scans cheap.
- LevelDB is an LSM store: writes first land in the log/memtable, later flush to
  sorted tables, and may be rewritten by compaction. Large values and repeated
  delete/reinsert churn can therefore cause write and space amplification.

Primary references: [LevelDB usage docs](https://github.com/google/leveldb/blob/main/doc/index.md),
[LevelDB implementation notes](https://github.com/google/leveldb/blob/main/doc/impl.md),
and [LevelDB options](https://github.com/google/leveldb/blob/main/include/leveldb/options.h).

## CLI Command Summary

| CLI command | Core methods | Estimated complexity | Notes |
| --- | --- | --- | --- |
| `metabrain` / `help` | ArgumentParser help generation, `commandHelpMessage` | `O(1)` relative to store size | Does not open or scan the store. |
| `version` | `currentSoftwareTag`, optional GitHub latest release request | `O(1)` relative to store size | Does not open the store. With the default release check, it performs one bounded HTTP request to GitHub's latest release API. |
| `init` | `StoreOptions.openStore`, `MetaBrainStore.init` | `O(1)` relative to documents, plus LevelDB open/recovery work | Creates the parent directory and opens LevelDB. Recovery can replay logs and clean stale files. |
| `put` new document | `putDocument`, `writeNewDocument`, `writeDocumentBatch` | `O(B + T + R + L * seek(S) + X_tree + D)` | Body chunking now advances indices incrementally. Tree maintenance touches only the new path branch instead of rebuilding the whole tree index. |
| `put` existing document | `putDocument`, `writeDocumentUpdate`, `writeDocumentBatch`, retention helpers | `O(B + B_old + T + T_old + R + R_old + V log V + H + L * seek(S) + X_tree + D)` | Updates delete stale chunks/indexes/references, may scan all versions for retention, and update only old/new tree branches. |
| `patch` | `checkDocumentPatch`/`patchDocument`, unified diff parsing, `writeDocumentUpdate`, `writeDocumentBatch`, retention helpers | `O(P_patch + B_old + B + T + T_old + R + R_old + V log V + H + L * seek(S) + X_tree + D)` for writes; `O(P_patch + B_old)` for `--check` | Patch is partial at the CLI layer, but writes still store a full next document snapshot and rebuild current chunks/indexes. |
| `move` | `moveDocument`, `writeDocumentUpdate`, `writeDocumentBatch`, retention helpers | `O(B + B_old + T + T_old + R + R_old + V log V + H + L * seek(S) + X_tree + D)` | Resolves an existing document, preserves its stable ID and content fields, writes a new path alias, removes the old path alias, and updates affected tree branches. |
| `get` | `getDocument`, `documentID(for:)`, `documentRecord(id:)`, `printDocument` | `O(seek(S) + B)` | Decoding and printing the stored document body dominate once the point lookup succeeds. |
| `list` non-recursive | `listDirectory`, `childTreeEntries`, `formatListEntry` | `O(seek(S) + K log K)` | Scans one tree prefix, decodes child records, sorts by display path, and prints them. |
| `list --recursive` | `listDirectory`, `flattenedTreeEntries`, `childTreeEntries` | `O(A * seek(S) + A log A)` typical, with extra recursive array-copy overhead | Walks directories with many separate prefix scans and materializes the whole subtree. `--directories-only` filters output but still traverses descendants. |
| `tree` | `tree`, `flattenedTreeEntries`, `printTree` | `O(A * seek(S) + A log A)` typical for an unbounded tree | `--max-depth 0` is `O(1)`. Larger depths scan and materialize the requested subtree, then group and sort for printing. |
| `dump` current | `dump`, `listDirectory`, `getDocument`, optional `DocumentDumpFileWriter.write` | `O(A * seek(S) + D_dump * B + H_dump)` for the requested subtree | Includes the exact path document plus descendant documents, emits JSONL, and optionally writes UTF-8 body copies. |
| `dump --versions` | `dump`, `versionRecords`, optional `DocumentDumpFileWriter.write` | `O(A * seek(S) + D_dump * (seek(S) + V log V + H) + H_dump)` | Selects current documents by path, then scans retained full-snapshot versions for each selected document. |
| `search` | `search`, `filteredDocumentIDs`, `termPostings`, `currentChunkRecords`, scoring, optional edge scans | `O((Q + G + M) * seek(S) + F log F + P log P + B_match + C_match + M * (W^2 + E) + M log M)` | `W` is terms in a scored chunk. `--limit` is applied after collecting, scoring, and sorting all candidates, so it does not cap the initial scan. |
| `versions` | `listVersions`, `versionRecords` | `O(seek(S) + V log V + H)` | Scans, decodes, sorts, and prints every full-snapshot version for the document. |
| `prune` | `prune`, `pruneVersions`, `versionRecords`, retention helpers | `O(seek(S) + V log V + H + P_delete)` | Scans and decodes all versions before deciding which version keys to delete. |
| `delete` | `deleteDocument`, `deleteDocumentRecord`, cleanup helpers | `O((C + R + E + L) * seek(S) + T + V + X_tree + P_delete + K_delete)` | Resolves one explicit document, then cleans current chunks, lexical/tag/metadata indexes, references/backlinks, retained versions, and affected tree entries. |
| `remove-version` | `getDocument`, `removeVersion` | `O(seek(S))` | Resolves one document and performs one version-key point lookup/delete. Rejects the current version. |

## Current Complex Calls To Treat Carefully

- `put` builds one large in-memory `WriteBatch` for document, version, chunk,
  term, metadata, reference, tree, and prune edits. LevelDB applies it
  atomically, but the batch size, WAL write, memtable pressure, and later
  compactions all grow with the number and size of edits.
- `put` stores large bodies multiple times: current document record, full
  version snapshot, and current chunk records. LevelDB then writes those values
  to its log and later sorted tables, with further rewrites during compaction.
- `put` with retention on a long-lived document scans and decodes the document's
  full version history. Because versions are full snapshots, large historical
  bodies make this cost closer to `O(H)` than just `O(V)`.
- `patch` avoids sending a whole replacement body through the CLI, but after the
  diff applies in memory it uses the same full-snapshot update path as `put`.
  One-line patches to large documents are therefore still large-document writes.
- Tree updates are branch-local now, but each affected branch entry still checks
  descendant document paths. Very deep paths or broad descendant sets can still
  make writes more expensive than the document body alone.
- `search` scans all postings for every distinct query term and scores every
  unique matched chunk before applying `--limit`. Queries for common terms can
  therefore be expensive even with a small limit.
- Prefix scans still materialize arrays. Key-only scans no longer copy values,
  and bulk scans use `fillCache = false`, but very broad scans still allocate
  memory proportional to the scan result.
- `search --include-linked-documents` and `search --include-backlinks` add
  reference prefix scans per matched document. This is useful context, but it
  can compound the cost of broad searches with many matched documents.
- `tree` and `list --recursive` materialize entire subtrees in memory. They are
  fine for small stores, but large or deeply nested stores should prefer bounded
  paths or `tree --max-depth`.
- `versions` and `prune` decode every version snapshot for the target document.
  Large bodies plus many versions are the worst case.
- `delete` is intentionally explicit, but it can still issue a broad cleanup for
  one document: current chunks and indexes, references and backlinks, retained
  version keys, and virtual tree branch entries are all removed or refreshed.
- `remove-version` is a point deletion after document resolution. It is cheap
  compared with pruning, but it cannot remove the current version.

## Command Details

### `version`

`version` resolves the current CLI tag from `METABRAIN_VERSION` or the bundled
release version. It does not open the document store.

By default, it also fetches GitHub's latest release endpoint once with a bounded
timeout and compares semantic release tags. Passing `--no-release-check` keeps
the command entirely local. Complexity is `O(1)` relative to store size.

### `init`

`init` opens the store through `StoreOptions.openStore()` and
`MetaBrainStore.init(url:options:)`.

Complexity is `O(1)` with respect to stored documents. It may still do filesystem
work to create the parent directory and LevelDB work to open or recover the
database.

### `put`

`put` validates and parses CLI input, reads a body argument or UTF-8 body file,
then calls `MetaBrainStore.putDocument(_:)`.

For a new document, the main work is:

- build and encode the document record and full-snapshot version: `O(B)`;
- chunk the body by advancing from the previous `String.Index`: `O(B)`;
- tokenize chunks and create term/tag/metadata/reference index keys:
  `O(B + T + R)`;
- update affected virtual tree branch records:
  `O(L * seek(S) + X_tree + D)`;
- write all records in one LevelDB batch. The foreground batch write is linear
  in encoded edit bytes, then LevelDB may later rewrite those bytes during
  flushes and compactions.

For an existing document, add:

- read the previous document record: `O(B_old)`;
- scan and decode previous current chunks to remove stale term indexes:
  `O(C_old log C_old + B_old + T_old)`;
- scan stale outbound reference keys and remove matching inbound keys:
  `O(R_old log R_old)`;
- if retention applies, scan/decode/sort versions:
  `O(V log V + H)`.

### `patch`

`patch` reads a unified diff from a UTF-8 file or stdin, resolves the target
document, applies the diff to the current body in memory, and then either stops
for `--check` or calls `MetaBrainStore.patchDocument(_:)`.

For `--check`, the main work is:

- read and parse the patch: `O(P_patch)`;
- decode the current document body and match hunk context/removals:
  `O(B_old + P_patch)`.

For a write, add the same existing-document update cost as `put`: the patched
body becomes the next full snapshot, current chunks and indexes are rebuilt, and
retention may scan historical full-snapshot versions. This intentionally keeps
version reads and pruning simple while making tiny patches to large documents
cost about the same as whole-body updates.

### `get`

`get` resolves a path or ID with `getDocument(_:)`, decodes the stored document,
and prints it. Complexity is `O(seek(S) + B)` because outputting the body
dominates once the point lookup succeeds.

### `move`

`move` resolves an existing path or ID with `moveDocument(_:to:)`, then writes a
new full-snapshot version with the same document ID, body, title, tags,
metadata, and stored references at the destination path. It fails when the
source document is missing and does not upsert. Moving to the current path is a
no-op.

Like other full-document updates, a real move rewrites current chunks and
indexes, removes the old path alias, writes the new path alias, updates only the
affected old/new virtual tree branches, stores a retained version according to
the document's retention policy, and may prune historical versions. Complexity
is the same shape as an existing-document `put`:
`O(B + B_old + T + T_old + R + R_old + V log V + H + L * seek(S) + X_tree + D)`.

Stable document ID references remain valid across a move because the document ID
is preserved. Stored path references are not rewritten automatically; if a
source document stores a path reference to the old location, that value remains
old until that source document is explicitly rewritten.

### `list`

`list` without `--recursive` calls `childTreeEntries(of:)`, which scans the tree
keys for one parent path, decodes them, sorts them, and formats output:
`O(seek(S) + K log K)`.

`list --recursive` calls `flattenedTreeEntries(...)`, recursively scans each
directory below the requested root, materializes all matching entries, and then
prints them. The typical cost is `O(A * seek(S) + A log A)` for the requested
subtree, plus extra array-copy overhead from recursive `entries += ...`
concatenation. All of these scans currently use the default LevelDB read option
that fills the block cache.

### `tree`

`tree` shares the same recursive traversal as `list --recursive`, then groups
entries by parent and sorts siblings while printing the ASCII tree.

Unbounded `tree` is typically `O(A * seek(S) + A log A)` for the requested
subtree. `tree --max-depth 0` returns before scanning children and is `O(1)`.

### `dump`

`dump` selects the exact document at the requested path when present, recursively
walks descendant tree entries, filters virtual directories out of the result,
sorts selected current documents by path, and emits one JSON object per line.

Current-only dumping decodes each selected current document and writes its body
to stdout as JSONL, plus optional UTF-8 file copies under `--output-dir`. Its
cost is dominated by tree traversal and emitted body bytes:
`O(A * seek(S) + D_dump * B + H_dump)` for the requested subtree.

`dump --versions` keeps the same current-document selection phase, then scans
and decodes retained full-snapshot versions for every selected document. This
adds `O(D_dump * (seek(S) + V log V + H))`, and the final stdout/file output
cost grows with all emitted version bodies.

### `search`

`search` calls `MetaBrainStore.search(_:)`.

The main work is:

- tokenize and de-duplicate query terms: `O(Q)`;
- scan tag and metadata filter indexes and intersect matching IDs:
  `O(G * seek(S) + F log F)`;
- scan term posting prefixes for every query term: `O(Q * seek(S) + P log P)`;
- OR-merge postings into unique document/chunk candidates: `O(P)`;
- for every matched document, decode the document record once, scan current
  chunks once in key order, and score each matched chunk:
  `O(M * seek(S) + B_match + C_match + M * W^2)`;
- keep only the best `L` scored candidates during traversal, where `L` is
  `--limit`, using bounded insertion cost `O(M * L)` instead of a full
  `O(M log M)` result sort;
- materialize snippets, neighboring context, and optional reference edges only
  for the retained top `L` results: `O(L * seek(S) + B_limit + L * E)`.

The scoring locality helper can be `O(W^2)` for a chunk with many repeated query
terms. This is usually hidden by small chunk sizes, but broad common-term
queries can still create many candidates. Search remains exact, so broad
queries still score every candidate before `--limit` is final; the limit now
primarily bounds retained result records and reference/context enrichment.

### `versions`

`versions` calls `listVersions(of:)`, which scans every `ver/<id>/...` key,
decodes each full-snapshot version, sorts by sequence, and prints all rows.

Complexity is `O(seek(S) + V log V + H)`.

### `prune`

`prune` resolves the document reference and calls `prune(_:)`, which scans,
decodes, and sorts all versions before applying the retention policy and
deleting pruned version keys.

Complexity is `O(seek(S) + V log V + H + P_delete)`.

### `delete`

`delete` resolves a path or ID and calls `deleteDocument(_:)`. Missing documents
return successfully without cleanup work. Existing documents delete the current
document record, path alias, current chunks, lexical/tag/metadata indexes,
outbound references, inbound backlink records, retained version keys, and
affected virtual tree entries.

Complexity is
`O((C + R + E + L) * seek(S) + T + V + X_tree + P_delete + K_delete)`.
The exact constant factor depends on how many indexed terms, references, and
tree branches the deleted document touched.

### `remove-version`

`remove-version` resolves a path or ID to the current document and then calls
`removeVersion(documentID:sequence:)`. Missing documents or missing historical
version keys return successfully with no deletion. Removing the current version
throws a core error so the current document remains readable.

Complexity is `O(seek(S))` for document resolution plus one version-key point
lookup and, when present, one delete.

## Mark II Provisional Complexity

Mark II changes the physical representation from full-body document records plus
fixed-window chunks to schema version 2 records made from document metadata,
chain manifests, and format-aware chunk records. The CLI contract should remain
stable for the first Mark II release, so this section describes expected core
costs rather than new public commands.

Additional provisional notation:

- `C2`: number of Mark II chunks in the current document chain.
- `S2`: number of manifest segments in the current document chain.
- `S_delta`: number of manifest segments changed, inserted, removed, or
  rehashed by one write.
- `P_seg`: target chunk pointers per manifest segment. Mark II starts at `256`
  and should tune this before merge based on benchmarks.
- `C_delta`: number of chunks changed, inserted, removed, or reindexed by one
  write.
- `B_delta`: text bytes inside changed chunks, plus immediate boundary context.
- `T_delta`: distinct indexed terms inside changed chunks.
- `R_delta`: references added or removed by changed chunks.
- `FM_delta`: derived front matter metadata fields added, changed, or removed by
  changed chunks.
- `J`: structural parse work for a format-aware chunker. For Markdown and JSON
  this is generally `O(B)` for a full body or `O(B_delta)` for localized work;
  JSONL line validation is `O(B_delta)`. If Markdown semantic parsing fails,
  fallback paragraph/line/window chunking remains linear in the input size.
- `J_delta`: structural parse or validation work for only the changed chunk
  region.
- `M_chain`: encoded size of one chain manifest root, usually proportional to
  `S2`.
- `M_segment`: encoded size of changed manifest segment records, usually
  proportional to `S_delta * P_seg`.
- `M_summary`: version or manifest summary bytes decoded while listing history,
  excluding chunk bodies.
- `P_manifest`: total segment pointers scanned across retained manifests during
  history, prune, dump, delete, or reachability work.
- `H_sha`: bytes scanned by streaming SHA-256 hashers for required chunk and
  segment/manifest hashes, plus optional lazy complete-file hashes when an
  operation already reads the whole reconstructed body.
- `H2`: total encoded chain manifest, segment, and reachable chunk bytes across
  retained Mark II versions.
- `G_segment`: number of manifest segment records considered by a reachability
  or garbage collection pass.
- `G_chunk`: number of chunk records considered by a reachability or garbage
  collection pass.
- `C_reachable`: number of unique chunk pointers reachable from retained
  manifests after retention is applied.
- `W_max`: enforced maximum terms/tokens per chunk after format-aware splitting.
- `B_match_delta`: total matched chunk bytes decoded while scoring Mark II
  search candidates.
- `retention_work`: the chosen retention policy's version-summary scan,
  manifest scan, and optional chunk reachability work.

Provisional command/core costs:

| Operation shape | Expected Mark II complexity | What changes from v1 |
| --- | --- | --- |
| New `put` | `O(J + B + H_sha + T + R + FM_delta + C2 + S2 + L * seek(S) + X_tree + D)` | Initial writes still parse, hash, segment, and index the whole body. Mark II adds segment/manifest metadata overhead. |
| Full-body update | `O(J + B + H_sha + B_old + C2 + C_old + S2 + T_delta + R_delta + FM_delta + retention_work + H2 + L * seek(S) + X_tree + D)` | Worst case remains whole-document work, but unchanged chunks and segments should be reused instead of rewritten. |
| Localized patch write | target `O(P_patch + B_delta + J_delta + H_sha + C_delta + S_delta * P_seg + T_delta + R_delta + FM_delta + M_chain + M_segment + retention_work)` | Required hashing should cover changed chunks, changed segments, and the manifest root, not force a full-file scan. The main desired win: cost should track changed chunks and changed segments, not full body size. |
| Untargeted compatible `patch` | best case like localized patch after mapping hunks to chunks and segments; fallback `O(P_patch + B + J + C2 + S2 + T_delta + R_delta + FM_delta + M_chain + M_segment)` | CLI stays stable. Internals should infer affected chunks from diff hunks when safe, and fall back deliberately when not. |
| `patch --check` | target `O(P_patch + B_delta + J_delta)`; fallback `O(P_patch + B)` | Keep the compatibility path correct even if optimization cannot localize a patch. |
| `get` | `O(seek(S) + S2 * seek(S) + C2 * seek(S) + B)` naive; target `O(seek(S) + S2 + C2 + B)` with ordered scans or batched reads | Reconstruction now reads a manifest, segments, and chunks. Avoid one point lookup per segment or chunk if that becomes visible. |
| `history` | target `O(seek(S) + V * M_summary)` | Version keys encode sequence order, so listing history should stream ordered version summaries without sorting. It should not decode retained chunk bodies. Mark II removes the old `versions` command name. |
| `dump --versions` | `O(A * seek(S) + D_dump * (V log V + H2) + H_dump)` | Dumping complete retained bodies still pays for emitted bytes, but repeated local edits should make `H2` much smaller than v1 `H`. |
| `prune` | `O(seek(S) + V * M_summary + P_manifest + G_segment + C_reachable + G_chunk + P_delete)` | Prune selects retained manifests, scans their segment pointers, marks reachable segments/chunks, and deletes only unreachable records. It should avoid decoding chunk text. |
| `search` | `O((Q + G + M) * seek(S) + F log F + P log P + B_match_delta + C_match + M * W_max^2)` | Search should score semantic/format-aware chunks with a hard token/term cap. Patch reindexing should touch only `C_delta` chunks. |
| `delete` | `O((S2 + C2 + R + E + L) * seek(S) + T + V + G_segment + G_chunk + X_tree + P_delete + K_delete)` | Delete must clean manifests, segments, and chunk records, preferably by reachability rather than broad value decoding. |

The `history` target assumes implementation uses LevelDB key ordering. Version
keys should remain sequence-sorted, and the scanner should emit summaries in key
order instead of materializing and sorting all `V` records. If a future key
layout loses that ordering, the complexity regresses to `O(seek(S) + V log V)`.

The biggest intended complexity improvement is for repeated local edits to
large documents. In v1, a one-line patch to a large body is still roughly a
large-body update because the current body, retained version, chunks, and indexes
are rebuilt. In Mark II, the target is:

```text
localized patch ~= changed chunk bytes + changed segment records + affected indexes + manifest root rewrite
```

not:

```text
localized patch ~= full document bytes + all chunks + all indexes
```

The manifest root rewrite is still proportional to `S2`, and changed segment
records are bounded by the segment target. Mark II starts with `P_seg = 256`
chunk pointers per segment. This should keep localized edits away from `O(C2)`
flat-manifest rewrites, but `S2` can still become visible for very large JSONL
logs and must be benchmarked.

### Mark II Complexity Controls

Keep Mark II complexity under control with these implementation constraints:

- Preserve exact reconstruction, but do not store full document bodies in v2
  document records or v2 version records. Otherwise Mark II quietly falls back
  to v1 space and write costs.
- Keep chunk counts bounded. Markdown chunking should merge tiny adjacent blocks
  when useful, plain text should use paragraph/window targets, JSON should avoid
  exploding deeply nested scalar values, and JSONL should document that each
  physical line is one chunk. For JSON, use top-level object/array chunks by
  default and recurse into nested JSON Pointer-like chunks only when a value
  exceeds chunk caps.
- Treat Markdown parsing as advisory. Parse/source-map failures should fall back
  to linear plain-text-style chunking with diagnostic metadata instead of
  rejecting writes.
- Treat Markdown front matter as both exact text and derived metadata. Store it
  as a normal `markdownFrontMatter` chunk, but only parse and reindex derived
  `frontmatter.*` fields when that chunk changes. The `2.0.0` extractor should
  stay a bounded simple-subset parser, not a full YAML engine. Localized patches
  elsewhere should not rescan the full document for front matter metadata.
- Keep manifest segment size tunable. Start with `256` chunk pointers per
  segment, then benchmark and tune before merging the Mark II PR.
- Keep chunk token counts bounded. Format-aware chunkers must split or force
  split chunks before they exceed `W_max`, because the current locality scoring
  helper can be quadratic in terms per chunk.
- Store manifest summaries that let `history` list revisions without decoding
  chunk bodies: sequence, created date, path, title, pin state, body byte count,
  chunk count, segment count, `manifestSHA256`, optional `fileSHA256`, and
  format.
- Maintain enough offset or line mapping to locate patch hunks in the current
  chain. If hunk-to-chunk mapping is ambiguous, use the full-document fallback
  explicitly and count it in benchmarks.
- Reindex only changed chunks. Stale term/reference keys should be tracked by
  current-version occurrence identity, `documentID + ordinal + chunkID`, so a
  localized patch does not need to scan and decode all old chunks and duplicate
  chunk contents are cleaned up independently.
- Make segment and chunk garbage collection reachability-based. Prune and
  explicit migration should compute retained manifests first, scan segment
  pointers across those manifests, mark reachable segments and chunks, then
  delete only unreferenced segments and chunks.
- Avoid broad prefix scans that materialize values when keys are enough. Use
  key-only scans for stale chunk keys, manifest keys, and reachability passes
  whenever possible.
- Watch write batch size. A localized patch should not build a batch containing
  every current chunk or every term in the document.
- Compute SHA-256 digests with scanning APIs. Required write-path hashes are
  chunk hashes, segment hashes, and manifest hashes; complete-file hashes are
  lazy metadata and should be updated only when an operation already streams the
  full reconstructed body.
- Treat ZSTD level 9 as a measured tradeoff. Track compressed bytes and CPU time
  separately for manifests, chunks, versions, and metadata.
- Benchmark JSONL separately. One-line-per-chunk is simple and predictable, but
  very large logs can create huge `C2`; manifest size, current ordinal pointers,
  and `get` reconstruction must be measured against that case.

Mark II should add benchmarks or counters that make these controls observable:

- current chunk count per document and distribution across formats;
- max and p95 token count per chunk;
- manifest segment count and chunk pointers per segment;
- changed chunk count per write;
- changed segment count per write;
- encoded write batch bytes and key count per mutation;
- chunk reuse ratio across versions;
- segment reuse ratio across versions;
- SHA-256 bytes scanned, complete-file hash refresh count, and whether hashing
  stayed streaming;
- history storage growth per repeated local edit;
- `get` reconstruction chunk reads per document;
- prune reachability scan keys and deleted segment/chunk count;
- retained manifest pointer count and reachable unique chunk count during prune;
- fallback rate from localized patching to full-document patching.

## Maintenance Guidance

Update this file whenever a CLI command starts calling a different core method,
when a core storage method changes its scan pattern, or when an optimization
removes one of the warnings above. Any benchmark or profiling work should record
the data shape alongside timings so the variables in this document stay useful.
Good candidates to revisit next are streaming prefix scans with early result
limits, version-summary indexes for prune/list operations, and an explicit
approximate search mode that can apply `--limit` before scoring every
common-term candidate.
