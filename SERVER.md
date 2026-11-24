# metaBrain Server

`mbd` is the local metaBrain daemon. See the [README](README.md#daemon) for
current CLI usage and [Architecture](ARCHITECTURE.md#process-model) for the
process model. This document records the API and the original design plan.
Sections on goals, implementation order, and distribution describe that plan.

The goal is to keep the existing architecture intact while removing the current
multi-process LevelDB lock problem for agents and tools. LevelDB supports
concurrent work inside one process, but one database path can only be open in
one process at a time. A long-lived daemon can own the store, serialize unsafe
operations, and let many short-lived clients call into the same memory without
failing with a database lock error.

## Goals

- Add a server on top of `MetaBrainCore`, not beside it.
- Keep `MetaBrainCLI` thin over shared behavior.
- Preserve feature parity with the current CLI command surface.
- Make the default deployment local-only and safe by construction.
- Use one daemon-owned `MetaBrainStore` per configured store path.
- Serialize mutations per store and allow reads/searches only when the core
  store can handle them safely.
- Return structured JSON errors instead of surfacing raw LevelDB lock failures.
- Reach 100% line coverage for `MetaBrainCore`, `MetaBrainCLI`, and the new
  server support target.
- Provide installable macOS and Linux user services before considering
  system-wide services.

## Non-Goals For The First Server

- No public remote hosted service.
- No internet-facing listener by default.
- No multi-user authorization model beyond local process ownership and optional
  bearer tokens for loopback HTTP.
- No rewrite of `MetaBrainStore` into a public actor.
- No Apple platform UI work in this repository.
- No Windows service support in the first implementation slice, although the
  existing CLI and core should keep building on Windows unless a platform guard
  is explicitly required.

## WasmKit Pattern To Reuse

The sibling `WasmKit` repository already uses a useful shape:

```text
WasmKitCore
wasmkit
WasmKitDaemonSupport
wasmkitd
```

For `metaBrain`, mirror that separation:

```text
metaBrain
|- MetaBrainCore          library: store, indexing, retrieval, domain behavior
|- mb                     CLI: one-shot human and agent commands
|- MetaBrainServerSupport target: protocol, routing, service files, config
`- mbd                    daemon: long-lived local server over MetaBrainCore
```

`MetaBrainServerSupport` should not be published as a package product at first.
Its public declarations can exist so the executable and tests can share them
inside the package, but they should not be treated as a stable external SDK.

## Product Shape

Add a second executable product:

```swift
.executable(
    name: "mbd",
    targets: ["MetaBrainServer"]
)
```

Add two targets:

```swift
.target(
    name: "MetaBrainServerSupport",
    dependencies: ["MetaBrainCore"]
)

.executableTarget(
    name: "MetaBrainServer",
    dependencies: [
        "MetaBrainServerSupport",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
    ]
)
```

Add test coverage:

```swift
.testTarget(
    name: "MetaBrainServerSupportTests",
    dependencies: ["MetaBrainServerSupport"]
)
```

The daemon executable should be thin. Request parsing, routing, configuration,
service file rendering, and serialization helpers belong in
`MetaBrainServerSupport`; document storage behavior belongs in `MetaBrainCore`.

## Process And Store Model

Start with one primary store per daemon process:

```bash
mbd serve --store .metabrain/store.leveldb --socket .metabrain/mbd.sock
```

This keeps ownership explicit and avoids a global daemon accidentally opening
unrelated workspace stores. Multiple workspaces can run separate daemons on
separate Unix socket paths.

The daemon opens stores on demand and shares one `MetaBrainStore` per active
path. Registry entries close after the configured idle timeout.

Per store:

- Mutating operations must be serialized.
- Reads may run concurrently if they do not mutate access metadata.
- Current `get` defaults to tracking reads and therefore writes entry metadata;
  expose that behavior clearly and serialize it with other mutations.
- `get` with `trackingRead: false`, `list`, `tree`, `search`, `dump`, and
  `versions` may be concurrent once their core behavior is verified as safe.
- The first implementation may conservatively serialize all requests; a later
  commit can split read and write lanes with tests.

The daemon should close the store on SIGINT and SIGTERM.

## CLI Relationship

By default, `mb` probes `http://127.0.0.1:6374` and sends store operations to a
healthy daemon there. Otherwise it opens the selected store directly. Use
`--no-server` for a direct open or `--server` to select a daemon explicitly.

```bash
mb --server .metabrain/mbd.sock put /notes/today "..."
mb --server .metabrain/mbd.sock search "..."
```

## Transports

Default transport:

```bash
mbd serve --socket ~/.metabrain/mbd.sock
```

Use Unix domain sockets on macOS and Linux. They fit a local trusted service and
can rely on filesystem permissions. The server must reject a regular file,
directory, or symlink at the socket path. It may remove an existing stale socket
file only after confirming it is a socket.

Optional debugging/integration transport:

```bash
mbd serve --host 127.0.0.1 --port 7421
```

Loopback HTTP must bind only to `127.0.0.1` or `localhost`. If loopback HTTP is
enabled with `authorizationTokenPath`, every request must provide a matching
`Authorization: Bearer <token>` header.

The first protocol should be HTTP/1.1 with JSON bodies. That keeps it easy to
exercise from shell tools, tests, and future editor integrations.

## Daemon Commands

```text
mbd serve
mbd service print --user
mbd service install --user
mbd service uninstall --user
mbd version
```

`serve` runs in the foreground by default and logs to stderr. Service
installation helpers should come after foreground serving is tested.

Suggested `serve` options:

```text
--store <path>
--socket <path>
--host <host>
--port <port>
--config <path>
--request-timeout-seconds <seconds>
--maximum-concurrent-requests <count>
--maximum-queued-requests <count>
--max-header-bytes <bytes>
--max-request-body-bytes <bytes>
--authorization-token-path <path>
--log-level <debug|info|warn|error>
```

Flags override config files.

## Configuration

Recommended default config candidates:

```text
macOS user:  ~/Library/Application Support/metaBrain/mbd.json
Linux user:  ~/.config/metabrain/mbd.json
system:      /etc/metabrain/mbd.json
```

Configuration fields:

```json
{
  "storePath": ".metabrain/store.leveldb",
  "socketPath": "~/.metabrain/mbd.sock",
  "loopbackHost": "127.0.0.1",
  "loopbackPort": 7421,
  "requestTimeoutSeconds": 30,
  "maximumConcurrentRequests": 16,
  "maximumQueuedRequests": 1024,
  "maxHeaderBytes": 65536,
  "maxRequestBodyBytes": 16777216,
  "authorizationTokenPath": null,
  "logLevel": "info"
}
```

Do not add path allowlists for document content in the first slice unless the
daemon starts reading arbitrary server-side body or patch files. Prefer request
bodies over server-side file paths for API operations so the client chooses what
to read.

## API Envelope

All successful responses should be JSON.

Error responses:

```json
{
  "error": "invalid_request",
  "message": "path is required."
}
```

Recommended status mapping:

```text
400 invalid JSON, invalid arguments, invalid document paths
401 missing or invalid loopback token
404 missing store, document, or route
405 wrong HTTP method
408 request timeout
409 conflicting path or store state
413 request too large
429 queue or concurrency limit exceeded
500 unexpected server or store failure
```

Use ISO-8601 date encoding and sorted JSON keys to match the current CLI JSON
style.

## Feature-Parity Endpoint Set

Keep endpoint names close to CLI verbs:

```text
GET  /health
GET  /v1/version
POST /v1/init
POST /v1/put
POST /v1/put-conditional
POST /v1/operation-inspect
POST /v1/operation-apply
POST /v1/patch
POST /v1/move
POST /v1/get
POST /v1/get-version
POST /v1/ensure-guide
POST /v1/put-markdown
POST /v1/links
POST /v1/lint
POST /v1/get-passage
POST /v1/get-ref
POST /v1/search-evidence
POST /v1/list
POST /v1/tree
POST /v1/search
POST /v1/recall
POST /v1/dump
POST /v1/versions
POST /v1/prune
POST /v1/delete
POST /v1/remove-version
```

`/health` and `/v1/version` work without a store. Store requests use the
daemon's configured path unless the `X-MetaBrain-Store-Path` header supplies a
base64-encoded UTF-8 path. `/v1/init`, `/v1/put`, and
`/v1/put-conditional` with `ifVersion: 0` can create a store. Existing-only
operations return HTTP 404 with `store_not_found` and the checked path if the
selected store is missing. An existing store with a missing
document can return `document_not_found`.

### Agent retrieval routes

Source transfer uses bounded JSON requests. All four routes use POST and the selected store. References use the ordinary `DocumentReferenceDTO` wire format.

| Route | Request | Result |
| --- | --- | --- |
| `/v1/source-stage-chunk` | `{"bytes":"<base64>"}` | `{"sha256":"<chunk digest>"}` |
| `/v1/source-finish-blob` | `{"chunks":["<chunk digest>"]}` in file order | `{"sha256":"<file digest>","byteCount":42}` |
| `/v1/source-descriptor` | `reference` and optional `version` | Stable document ID, retained version and capture metadata |
| `/v1/source-chunk` | `reference`, positive `version`, zero-based `index` | `{"bytes":"<base64>"}` |

Use 1 MiB chunks, with a possibly shorter final chunk. An empty file has an empty chunk list. Submit the returned blob and provenance as `sourceCapture` on its document during operation inspection. Readers resolve a descriptor once, fetch chunks by the returned ID and version, then verify the original length and SHA-256. An older daemon needs an upgrade to serve these routes. [CLI capture example](README.md#capture-and-recover-an-original-file)

For project writes, `POST /v1/operation-inspect` accepts a `ProjectOperation` and returns the full `OperationPreview`. `POST /v1/operation-apply` takes that exact preview and returns an `OperationReceipt` with ordered document IDs, versions, and statuses. A malformed operation returns HTTP 400. A stale preview, wrong store, or reused operation ID with different contents returns HTTP 409. The client selects the store on both calls. See the [complete request example](README.md#commit-related-notes-together).

- `POST /v1/ensure-guide` with `{}` installs `/AGENTS.md` in an existing
  store only when absent. Response fields match a put result, with operation
  `ensure-guide` and status `created` or `unchanged`.
- `POST /v1/put-markdown` explicitly enables Markdown on a put, including for
  extensionless paths. The request wraps ordinary put fields in `document` and
  optionally accepts a top-level `ifVersion`. Ordinary `.md` puts already
  enable Markdown through the normal put route.
- `POST /v1/links` takes a document reference and optional `direction`
  (`incoming` or `outgoing`, the default) and `block`. The block filter matches
  the cited block for incoming links and the source block for outgoing links.
  Each occurrence includes its source revision and character offsets, target
  details when available, and a resolution status.
- `POST /v1/lint` takes optional `path` and `includeOrphans` fields. The path
  selects the exact document and its descendants. Omit it to audit the whole
  store. `includeOrphans` defaults to false. A completed audit returns HTTP 200
  with `path`, `documentsChecked`, `counts`, and `findings`. Counts use keys
  `missingTarget`, `ambiguousTarget`, `missingAnchor`, `ambiguousAnchor`, and
  `orphan`. Findings carry `kind`, `sourceID`, `sourcePath`, and `sourceVersion`.
  Citation findings add `start`, `end`, and `destination`, plus `targetPath`,
  `fragment`, and `candidatePaths` where applicable. An explicit scope with no
  document or descendants returns HTTP 404 with `lint_scope_not_found`.
- `POST /v1/get-passage` takes a document reference, exactly one of `block` or
  `heading`, and an optional retained `version`. It uses the current revision
  by default.
- `POST /v1/search-evidence` accepts `query`, `pathPrefix`, `tags`, `metadata`,
  `limit`, a required `view` of `refs` or `evidence`, and optional `maxTokens`.
  Filter-only requests require `refs`.
- `POST /v1/get-ref` expands a versioned `ref`, with optional `context`
  (`section`) and `maxTokens`. The cited revision must still be retained.
  Both evidence routes return compact JSON with `items` and `truncated`. Each
  item has `path` and `ref`, plus `text` when returning passages. The budget
  counts UTF-8 bytes including JSON framing and the CLI's final line feed.

### Request Shapes

`POST /v1/init`

Send an empty body or `{}` to initialize a new store with `/AGENTS.md`.
Send the following body to create a store with zero documents.
Either request preserves the contents of an existing store.

```json
{"empty": true}
```

Response mirrors CLI JSON:

```json
{
  "operation": "init",
  "status": "initialized",
  "storePath": "/absolute/path/to/store.leveldb"
}
```

`POST /v1/put`

```json
{
  "path": "/notes/today",
  "body": "Important context",
  "title": "Today",
  "tags": ["planning"],
  "metadata": {"source": "agent"},
  "references": [
    {"kind": "path", "value": "/notes/other"},
    {"kind": "documentID", "value": "abc123"},
    {"kind": "url", "value": "https://example.com"}
  ],
  "retention": {"kind": "keepLast", "count": 5}
}
```

Response mirrors `PutOutput`. The `status` is `created`, `updated`, or
`unchanged`. A write that leaves the document and retention policy unchanged
returns the current version without adding a snapshot.

`POST /v1/put-conditional`

```json
{
  "document": {"path": "/notes/today", "body": "Revised context"},
  "ifVersion": 2,
  "bodyOnly": true
}
```

The `document` object uses the `/v1/put` request fields. Supply `ifVersion`,
`bodyOnly: true`, or both. A positive `ifVersion` checks the current version
before writing. Use `ifVersion: 0` to create a document at an unused path.
`bodyOnly: true` requires an existing document and preserves the title, tags,
metadata, references, and retention policy. Omit these fields and use a
positive `ifVersion` or leave it unspecified.

A mismatched version returns HTTP 409 with `conflict` and the expected and
current versions. An exact retry whose current version is `ifVersion + 1`
returns `unchanged`. The response mirrors `PutOutput`. Older daemons return
HTTP 404 with `not_found` for this route. Clients should surface that error
and keep guarded requests on this endpoint.

`POST /v1/patch`

```json
{
  "reference": {"kind": "path", "value": "/notes/today"},
  "unifiedDiff": "--- a/doc\n+++ b/doc\n@@ ...",
  "check": false,
  "retention": {"kind": "keepAll"}
}
```

Response mirrors `PatchOutput` or `PatchCheckOutput`.

`POST /v1/move`

```json
{
  "reference": {"kind": "documentID", "value": "abc123"},
  "destinationPath": "/notes/archive/today"
}
```

Response mirrors `MoveOutput`.

`POST /v1/get`

```json
{
  "reference": {"kind": "path", "value": "/notes/today"},
  "trackingRead": true
}
```

Response mirrors `GetOutput`.

`POST /v1/get-version`

```json
{
  "reference": {"kind": "documentID", "value": "abc123"},
  "version": 2
}
```

The version must be a positive retained sequence. The response uses
`GetOutput` with the snapshot body, path, fields, and version. A historical
read leaves the document's read counter unchanged. A missing or pruned
sequence returns HTTP 404 with `document_version_not_found`. Use the document
ID to reopen a citation after a move.

`POST /v1/list`

```json
{
  "path": "/notes",
  "recursive": true,
  "directoriesOnly": false
}
```

Response is an array of `ListOutput`.

`POST /v1/tree`

```json
{
  "path": "/",
  "directoriesOnly": false,
  "maxDepth": 2
}
```

Response is an array of `TreeOutput`, including the root entry when the current
CLI JSON would include it.

`POST /v1/search`

```json
{
  "query": "Important context",
  "pathPrefix": "/notes",
  "tags": ["planning"],
  "metadata": {"source": "agent"},
  "includeLinkedDocuments": true,
  "includeBacklinks": true,
  "limit": 20
}
```

Response is an array of `SearchOutput`.

`POST /v1/recall`

```json
{
  "query": "release rollback",
  "pathPrefix": "/notes",
  "tags": ["release"],
  "metadata": {"state": "current"},
  "limit": 5,
  "maxBytes": 8192
}
```

The response is a compact JSON array of recall results with document ID, path,
version, optional title, sources, and passages. Each passage has `text` and
half-open `start` and `end` character offsets into the cited body. Title and
path matches can return the opening excerpt. Empty bodies can return an empty
passages array. The default `limit` is five distinct documents. The default `maxBytes` is
8,192, with a supported range of 3 to 1,048,576. The daemon reserves a byte for
the newline the CLI appends. An invalid budget or nonpositive document limit
returns HTTP 400 with `invalid_request`.

`POST /v1/dump`

```json
{
  "path": "/notes",
  "versions": false,
  "includeBodies": true
}
```

Response is an array of `DumpOutput`. Do not support `outputDirectory` in the
daemon API at first; that is a client-side filesystem concern.

`POST /v1/versions`

```json
{
  "reference": {"kind": "path", "value": "/notes/today"}
}
```

Response is an array of `VersionsOutput`.

`POST /v1/prune`

```json
{
  "reference": {"kind": "path", "value": "/notes/today"},
  "retention": {"kind": "keepLast", "count": 5}
}
```

Response mirrors `PruneOutput`.

`POST /v1/delete`

```json
{
  "reference": {"kind": "path", "value": "/notes/today"}
}
```

Response mirrors `DeleteOutput`.

`POST /v1/remove-version`

```json
{
  "reference": {"kind": "path", "value": "/notes/today"},
  "sequence": 1
}
```

Response mirrors `RemoveVersionOutput`.

`GET /v1/version`

Default to local version information only. Do not perform the GitHub release
check from the daemon unless a future endpoint explicitly requests it.

## Shared Request Types To Move Out Of CLI

The current CLI contains private output structs and parsing helpers. For parity,
move stable JSON request/response types into a shared module in small slices:

- `DocumentReferenceDTO`
- `DocumentRetentionPolicyDTO`
- `DocumentReferenceListDTO`
- `InitializeOutput`
- `PutOutput`
- `PatchOutput`
- `PatchCheckOutput`
- `MoveOutput`
- `GetOutput`
- `ListOutput`
- `TreeOutput`
- `SearchOutput`
- `DumpOutput`
- `VersionsOutput`
- `PruneOutput`
- `DeleteOutput`
- `RemoveVersionOutput`
- `VersionOutput`

Prefer putting domain-neutral DTOs in `MetaBrainCore` only when they are truly
part of the public library surface. Server-only HTTP details should stay in
`MetaBrainServerSupport`.

## Concurrency And Backpressure

The server must have explicit limits:

- maximum request header bytes
- maximum request body bytes
- request read timeout
- maximum concurrent accepted requests
- maximum queued requests
- graceful shutdown timeout

If the queue is full, return `429`.

The first implementation can use a single per-store request actor:

```swift
actor MetaBrainStoreServer {
    let store: MetaBrainStore
    func handle(_ operation: StoreOperation) async throws -> StoreResponse
}
```

This is intentionally conservative. Once correctness is covered, split into a
write lane and a read lane:

- write lane: `init`, `put`, `patch`, `move`, tracking `get`, `prune`,
  `delete`, `remove-version`
- read lane: non-tracking `get`, `list`, `tree`, `search`, `dump`, `versions`

Do not expose lower-level LevelDB handles through the server boundary.

## Security And Local Safety

- Default to Unix sockets.
- Create socket parent directories with owner-only permissions where possible.
- Reject unsafe pre-existing socket paths.
- Bind loopback HTTP only to local interfaces.
- Require bearer token auth for loopback HTTP when configured.
- Do not read arbitrary body or patch files from server request parameters in
  the first API; send bodies and diffs in JSON.
- Log request method, path, status, latency, and error code; do not log document
  bodies by default.
- Make shutdown deterministic and clean up daemon-created socket files.

## Testing Requirements

Coverage remains a release gate. Update `Scripts/check-coverage.sh` so it
includes:

- `Sources/MetaBrainCore`
- `Sources/MetaBrainCLI`
- `Sources/MetaBrainServerSupport`
- server smoke coverage for the `mbd` executable

Add focused tests before or alongside each implementation slice:

- config path selection and config loading
- serve configuration validation
- HTTP codec parsing and serialization
- request size limits and timeout mapping
- router method checks and not-found responses
- every feature-parity endpoint success path
- every endpoint validation failure path
- store operation serialization under concurrent mutating requests
- graceful shutdown and socket cleanup
- Unix socket stale-file behavior
- loopback authorization behavior
- service file rendering for launchd and systemd
- CLI smoke tests for foreground `mbd serve`

Use temporary stores for integration tests. Do not rely on a global user store.

## Documentation Updates During Implementation

When `feat/server` changes command flow or store scan patterns, update:

- `README.md` for user-facing commands and installation.
- `ARCHITECTURE.md` for the process model once the daemon exists.
- `COMPLEXITY.md` for server endpoints and any changed core access patterns.
- `RELEASING.md` for packaging changes.
- `SERVER.md` as implementation decisions settle.

## Original Implementation Order

1. Add shared DTOs and output encoders without changing CLI behavior.
2. Add `MetaBrainServerSupport` and a router with `/health` only.
3. Add bounded HTTP codec/server support for Unix sockets.
4. Add `MetaBrainServer` executable with `mbd serve`.
5. Open one configured `MetaBrainStore` for the daemon lifetime.
6. Implement `/v1/init`, `/v1/put`, and `/v1/get` through the serialized store
   owner.
7. Add server smoke tests and coverage script support.
8. Implement `/v1/list`, `/v1/tree`, `/v1/search`, and `/v1/versions`.
9. Implement `/v1/patch`, `/v1/move`, `/v1/prune`, `/v1/delete`, and
   `/v1/remove-version`.
10. Implement `/v1/dump` without server-side output directories.
11. Add loopback HTTP and optional bearer-token authorization.
12. Add structured logs and request IDs.
13. Add `service print --user` for launchd and systemd.
14. Add `service install --user` and `service uninstall --user`.
15. Add optional `mb --server <socket>` client mode.
16. Document distribution and update release scripts.
17. Revisit read concurrency after full endpoint parity is covered.

Each step should be a small commit. Keep dependency changes separate from
feature work.

## Distribution

Homebrew and APT are suitable for distributing a service/daemon, but they
should install the binaries and service templates, not silently start a daemon
for every user.

Recommended macOS/Homebrew approach:

- Package both `mb` and `mbd` in the existing tap.
- Provide a `service` block or documented `brew services start metabrain` path
  only after `mbd service print --user` is stable.
- Prefer a user LaunchAgent over a system LaunchDaemon.
- Do not auto-start in `post_install`; print clear next steps instead.
- Store user config under `~/Library/Application Support/metaBrain/mbd.json`.

Recommended Linux/APT approach:

- Package both `mb` and `mbd` in the `metabrain` `.deb`.
- Install a systemd user unit template or an example unit.
- Do not auto-enable a user service from package install; user services need
  per-user context and often linger configuration.
- Provide documented commands:

```bash
mbd service print --user
mbd service install --user
systemctl --user daemon-reload
systemctl --user enable --now mbd.service
```

- For system-wide installs later, add a dedicated `metabrain` user, explicit
  store/config paths, and a separate threat model.

APT is appropriate for Ubuntu users because it can place binaries, docs, and
systemd unit files predictably. Homebrew is appropriate for macOS users because
it can install both the CLI and daemon and integrate with `brew services`.
Neither package manager should decide which workspace store a daemon owns; that
belongs in user config or an explicit service install command.
