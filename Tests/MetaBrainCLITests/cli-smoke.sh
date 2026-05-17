#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_PARENT="${METABRAIN_TMPDIR:-/private/tmp}"
TMP_DIR="$(mktemp -d "$TMP_PARENT/metabrain-cli.XXXXXX")"
STORE="$TMP_DIR/store.leveldb"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -n "${METABRAIN_BIN:-}" ]]; then
    METABRAIN=("$METABRAIN_BIN")
else
    METABRAIN=(swift run metabrain)
fi

cd "$ROOT_DIR"

"${METABRAIN[@]}" | rg -q 'Agent discovery:'
"${METABRAIN[@]}" --help | rg -q 'Common workflow:'
"${METABRAIN[@]}" help | rg -q 'metabrain help search'
"${METABRAIN[@]}" help | rg -q 'metabrain help list'
"${METABRAIN[@]}" help | rg -q 'metabrain help tree'
"${METABRAIN[@]}" help | rg -q 'metabrain help dump'
"${METABRAIN[@]}" help init | rg -q 'Create or open a metaBrain store'
"${METABRAIN[@]}" help put | rg -q 'Create or update a document at a path'
"${METABRAIN[@]}" help patch | rg -q 'Patch a document body with a unified diff'
"${METABRAIN[@]}" help get | rg -q 'Read a document by path or ID'
"${METABRAIN[@]}" help list | rg -q 'List stored document paths in a folder'
"${METABRAIN[@]}" help tree | rg -q 'Show the stored document path tree'
"${METABRAIN[@]}" help search | rg -q 'Search current document content'
"${METABRAIN[@]}" help dump | rg -q 'Dump stored documents as JSONL'
"${METABRAIN[@]}" help versions | rg -q 'List stored versions for a document'
"${METABRAIN[@]}" help prune | rg -q 'Prune document versions using a retention policy'

if "${METABRAIN[@]}" help missing 2>"$TMP_DIR/help-missing.err"; then
    echo "Expected unknown help topic to fail" >&2
    exit 1
fi
rg -F -q 'Usage: metabrain help [<command>]' "$TMP_DIR/help-missing.err"

if "${METABRAIN[@]}" init --unknown-option 2>"$TMP_DIR/init-invalid.err"; then
    echo "Expected invalid init option to fail" >&2
    exit 1
fi
rg -F -q 'Usage: metabrain init [--store <store>] [--format <format>]' "$TMP_DIR/init-invalid.err"

if "${METABRAIN[@]}" search query --limit 0 2>"$TMP_DIR/search-invalid.err"; then
    echo "Expected invalid search limit to fail" >&2
    exit 1
fi
rg -F -q 'Usage: metabrain search [--store <store>] <query>' "$TMP_DIR/search-invalid.err"

if "${METABRAIN[@]}" tree --max-depth=-1 2>"$TMP_DIR/tree-invalid-depth.err"; then
    echo "Expected invalid tree max depth to fail" >&2
    exit 1
fi
rg -q -- '--max-depth must be zero or greater' "$TMP_DIR/tree-invalid-depth.err"

INIT_DEFAULT_JSON="$("${METABRAIN[@]}" init --store "$STORE")"
EXPECTED_INIT_JSON="{\"operation\":\"init\",\"status\":\"initialized\",\"storePath\":\"$STORE\"}"
if [[ "$INIT_DEFAULT_JSON" != "$EXPECTED_INIT_JSON" ]]; then
    echo "Expected init default JSON output, got: $INIT_DEFAULT_JSON" >&2
    exit 1
fi
"${METABRAIN[@]}" init --store "$STORE" --format text | rg -F -q "Initialized metaBrain store at $STORE"
INIT_JSONL="$("${METABRAIN[@]}" init --store "$STORE" --format jsonl)"
if [[ "$INIT_JSONL" != "$EXPECTED_INIT_JSON" ]]; then
    echo "Expected init JSONL output, got: $INIT_JSONL" >&2
    exit 1
fi
"${METABRAIN[@]}" put --store "$STORE" /notes/today 'alpha beta searchable memory' --title Today --tag search --meta status=active --meta kind=daily | rg -q '^version: 1$'
"${METABRAIN[@]}" put --store "$STORE" /notes/archive/final 'archived memory' | rg -q '^version: 1$'
"${METABRAIN[@]}" put --store "$STORE" /notes/patchable 'one old patchable memory' --tag patch | rg -q '^version: 1$'
"${METABRAIN[@]}" dump --store "$STORE" /notes >"$TMP_DIR/dump-notes.jsonl"
rg -F -q '"path":"/notes/archive/final"' "$TMP_DIR/dump-notes.jsonl"
rg -F -q '"path":"/notes/today"' "$TMP_DIR/dump-notes.jsonl"
rg -F -q '"body":"alpha beta searchable memory"' "$TMP_DIR/dump-notes.jsonl"
if rg -F -q '"path":"/refs/target"' "$TMP_DIR/dump-notes.jsonl"; then
    echo "Expected /notes dump to exclude unrelated paths" >&2
    exit 1
fi
"${METABRAIN[@]}" dump --store "$STORE" /missing >"$TMP_DIR/dump-missing.jsonl"
if [[ -s "$TMP_DIR/dump-missing.jsonl" ]]; then
    echo "Expected missing dump path to produce no JSONL entries" >&2
    exit 1
fi
PATCH_FILE="$TMP_DIR/patchable.diff"
cat >"$PATCH_FILE" <<'PATCH'
--- a/notes/patchable
+++ b/notes/patchable
@@ -1 +1 @@
-one old patchable memory
\ No newline at end of file
+one fresh patchable memory
\ No newline at end of file
PATCH
"${METABRAIN[@]}" patch --store "$STORE" /notes/patchable --patch-file "$PATCH_FILE" --check | rg -q '^patch applies$'
"${METABRAIN[@]}" get --store "$STORE" /notes/patchable | rg -q 'one old patchable memory'
"${METABRAIN[@]}" patch --store "$STORE" /notes/patchable --patch-file "$PATCH_FILE" | rg -q '^version: 2$'
"${METABRAIN[@]}" get --store "$STORE" /notes/patchable | rg -q 'one fresh patchable memory'
"${METABRAIN[@]}" search --store "$STORE" fresh --tag patch | rg -q '^/notes/patchable'
"${METABRAIN[@]}" search --store "$STORE" old --tag patch | rg -q '^No results\.$'
"${METABRAIN[@]}" put --store "$STORE" /notes/stdin-patch 'stdin old memory' | rg -q '^version: 1$'
STDIN_PATCH_FILE="$TMP_DIR/stdin-patch.diff"
cat >"$STDIN_PATCH_FILE" <<'PATCH'
@@ -1 +1 @@
-stdin old memory
\ No newline at end of file
+stdin fresh memory
\ No newline at end of file
PATCH
"${METABRAIN[@]}" patch --store "$STORE" --path /notes/stdin-patch --patch-file - <"$STDIN_PATCH_FILE" | rg -q '^version: 2$'
"${METABRAIN[@]}" get --store "$STORE" --path /notes/stdin-patch | rg -q 'stdin fresh memory'
"${METABRAIN[@]}" list --store "$STORE" | rg -q '^notes/$'
"${METABRAIN[@]}" list --store "$STORE" --recursive | rg -q '^notes/archive/final$'
"${METABRAIN[@]}" list --store "$STORE" /notes | rg -q '^today$'
"${METABRAIN[@]}" list --store "$STORE" /notes --recursive | rg -q '^archive/final$'
"${METABRAIN[@]}" list --store "$STORE" /notes --recursive --directories-only | rg -q '^archive/$'
"${METABRAIN[@]}" list --store "$STORE" /notes --dates | rg -q '^today  created=.* updated=.*'
"${METABRAIN[@]}" tree --store "$STORE" --max-depth 2 | rg -q '^`-- notes/$'
"${METABRAIN[@]}" tree --store "$STORE" /notes --directories-only | rg -q '^`-- archive/$'
"${METABRAIN[@]}" list --store "$STORE" /missing | rg -q '^No documents\.$'
"${METABRAIN[@]}" tree --store "$STORE" /missing | rg -q '^No documents\.$'
"${METABRAIN[@]}" tree --store "$STORE" --max-depth 0 | rg -q '^/$'
"${METABRAIN[@]}" get --store "$STORE" /notes/today | rg -q 'alpha beta searchable memory'
"${METABRAIN[@]}" get --store "$STORE" --path /notes/today | rg -q 'alpha beta searchable memory'
"${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag search --meta status=active | rg -q '/notes/today'
"${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag missing | rg -q '^No results\.$'
"${METABRAIN[@]}" put --store "$STORE" /notes/today 'alpha beta updated memory' --keep-last 2 | rg -q '^version: 2$'
"${METABRAIN[@]}" dump --store "$STORE" /notes/today --versions >"$TMP_DIR/dump-today-versions.jsonl"
rg -F -q '"version":1' "$TMP_DIR/dump-today-versions.jsonl"
rg -F -q '"version":2' "$TMP_DIR/dump-today-versions.jsonl"
rg -F -q '"isCurrent":true' "$TMP_DIR/dump-today-versions.jsonl"
DUMP_OUTPUT_DIR="$TMP_DIR/dump-files"
"${METABRAIN[@]}" dump --store "$STORE" /notes/today --output-dir "$DUMP_OUTPUT_DIR" >"$TMP_DIR/dump-today-files.jsonl"
rg -F -q '"fileSystemPath":"' "$TMP_DIR/dump-today-files.jsonl"
DUMP_FILE="$(find "$DUMP_OUTPUT_DIR" -type f -name 'today__*__v2__*.txt' | head -n 1)"
if [[ -z "$DUMP_FILE" || ! -f "$DUMP_FILE" ]]; then
    echo "Expected dump --output-dir to create a versioned copy" >&2
    exit 1
fi
rg -F -q 'alpha beta updated memory' "$DUMP_FILE"
"${METABRAIN[@]}" versions --store "$STORE" /notes/today | rg -q '^2 '
"${METABRAIN[@]}" versions --store "$STORE" --path /notes/today | rg -q '^2 '
"${METABRAIN[@]}" prune --store "$STORE" /notes/today --keep-last 1 | rg -q '^retained: 1$'
"${METABRAIN[@]}" prune --store "$STORE" --path /notes/today --keep-last 1 | rg -q '^retained: 1$'
"${METABRAIN[@]}" versions --store "$STORE" --path /notes/today | rg -q '^2 '

BODY_FILE="$TMP_DIR/body.txt"
printf 'file body with gamma delta searchable terms\n' >"$BODY_FILE"
"${METABRAIN[@]}" put --store "$STORE" /notes/file --body-file "$BODY_FILE" --keep-all | rg -q '^version: 1$'
"${METABRAIN[@]}" get --store "$STORE" --path /notes/file | rg -q 'file body with gamma delta'
"${METABRAIN[@]}" search --store "$STORE" gamma --path-prefix /notes --limit 1 | rg -q '^/notes/file'
"${METABRAIN[@]}" versions --store "$STORE" --path /missing | rg -q '^No versions\.$'
"${METABRAIN[@]}" prune --store "$STORE" --path /missing --keep-within 0 | rg -q '^retained: 0$'

mkdir -p "$TMP_DIR/home-root" "$TMP_DIR/home-nested"
env METABRAIN_HOME="$TMP_DIR/home-root" "${METABRAIN[@]}" init --store '~' --format text | rg -q "Initialized metaBrain store at $TMP_DIR/home-root"
env METABRAIN_HOME="$TMP_DIR/home-nested" "${METABRAIN[@]}" init --store '~/.metabrain/store.leveldb' --format text | rg -q "Initialized metaBrain store at $TMP_DIR/home-nested/.metabrain/store.leveldb"

"${METABRAIN[@]}" put --store "$STORE" /refs/target 'target needle reference' --title Target | rg -q '^version: 1$'
TARGET_ID="$("${METABRAIN[@]}" get --store "$STORE" --path /refs/target | awk '/^id: / { print $2 }')"
"${METABRAIN[@]}" get --store "$STORE" --id "$TARGET_ID" | rg -q 'target needle reference'
"${METABRAIN[@]}" put --store "$STORE" /refs/source 'source needle reference' --ref-id "$TARGET_ID" --ref-path /refs/target --ref-url https://example.com/ref | rg -q '^version: 1$'
"${METABRAIN[@]}" get --store "$STORE" --path /refs/source | rg -q "references: $TARGET_ID, /refs/target, https://example.com/ref"
"${METABRAIN[@]}" search --store "$STORE" source --include-linked-documents | rg -q '^linked: [0-9a-f-]+$'
"${METABRAIN[@]}" search --store "$STORE" target --include-backlinks | rg -q '^backlinks: [0-9a-f-]+$'

LONG_BODY="$TMP_DIR/long-body.txt"
for _ in {1..650}; do
    printf 'context '
done >"$LONG_BODY"
printf 'needle ' >>"$LONG_BODY"
"${METABRAIN[@]}" put --store "$STORE" /notes/long --body-file "$LONG_BODY" | rg -q '^version: 1$'
"${METABRAIN[@]}" search --store "$STORE" needle --path-prefix /notes/long >"$TMP_DIR/long-search.out"
rg -q '^context: 0$' "$TMP_DIR/long-search.out"
rg -q '\.\.\.$' "$TMP_DIR/long-search.out"

if "${METABRAIN[@]}" get --store "$STORE" --id bad/id 2>"$TMP_DIR/invalid-id.err"; then
    echo "Expected invalid ID syntax to fail" >&2
    exit 1
fi
rg -q 'invalidDocumentID' "$TMP_DIR/invalid-id.err"

if "${METABRAIN[@]}" dump --store "$STORE" .. 2>"$TMP_DIR/invalid-dump-path.err"; then
    echo "Expected invalid dump path to fail" >&2
    exit 1
fi
rg -q 'invalidDocumentPath' "$TMP_DIR/invalid-dump-path.err"

if "${METABRAIN[@]}" get --store "$STORE" --id abc --path /notes/today 2>"$TMP_DIR/double-reference.err"; then
    echo "Expected duplicate reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/double-reference.err"
rg -F -q 'Usage: metabrain get [--store <store>] [--id <id>] [--path <path>] [<path>]' "$TMP_DIR/double-reference.err"

if "${METABRAIN[@]}" get --store "$STORE" --path /notes/today /notes/file 2>"$TMP_DIR/path-and-positional-reference.err"; then
    echo "Expected option path plus positional path to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/path-and-positional-reference.err"

if "${METABRAIN[@]}" get --store "$STORE" --id abc /notes/today 2>"$TMP_DIR/id-and-positional-reference.err"; then
    echo "Expected ID plus positional path to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/id-and-positional-reference.err"

if "${METABRAIN[@]}" get --store "$STORE" --path /missing 2>"$TMP_DIR/not-found.err"; then
    echo "Expected missing document to fail" >&2
    exit 1
fi
rg -q 'Document not found' "$TMP_DIR/not-found.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/bad body --meta invalid 2>"$TMP_DIR/invalid-meta.err"; then
    echo "Expected invalid metadata syntax to fail" >&2
    exit 1
fi
rg -q 'Metadata must use key=value syntax' "$TMP_DIR/invalid-meta.err"
rg -F -q 'Usage: metabrain put [<options>] <path> [<body>]' "$TMP_DIR/invalid-meta.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/no-body 2>"$TMP_DIR/missing-body.err"; then
    echo "Expected missing body to fail" >&2
    exit 1
fi
rg -q 'Provide a document body argument or --body-file' "$TMP_DIR/missing-body.err"
rg -F -q 'Usage: metabrain put [<options>] <path> [<body>]' "$TMP_DIR/missing-body.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/double-body body --body-file "$BODY_FILE" 2>"$TMP_DIR/double-body.err"; then
    echo "Expected duplicate body inputs to fail" >&2
    exit 1
fi
rg -q 'Use either a body argument or --body-file' "$TMP_DIR/double-body.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/bad-retention body --keep-last 0 2>"$TMP_DIR/bad-keep-last.err"; then
    echo "Expected invalid keep-last to fail" >&2
    exit 1
fi
rg -q -- '--keep-last must be greater than zero' "$TMP_DIR/bad-keep-last.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/bad-window body --keep-within=-1 2>"$TMP_DIR/bad-keep-within.err"; then
    echo "Expected invalid keep-within to fail" >&2
    exit 1
fi
rg -q -- '--keep-within must be zero or greater' "$TMP_DIR/bad-keep-within.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/conflicting-retention body --keep-all --keep-last 1 2>"$TMP_DIR/conflicting-retention.err"; then
    echo "Expected conflicting retention options to fail" >&2
    exit 1
fi
rg -q 'Use only one retention option' "$TMP_DIR/conflicting-retention.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/bad-ref body --ref-url relative/path 2>"$TMP_DIR/bad-ref-url.err"; then
    echo "Expected invalid reference URL to fail" >&2
    exit 1
fi
rg -q 'Reference URLs must be absolute URLs' "$TMP_DIR/bad-ref-url.err"
rg -F -q 'Usage: metabrain put [<options>] <path> [<body>]' "$TMP_DIR/bad-ref-url.err"

BAD_PATCH_FILE="$TMP_DIR/bad.patch"
printf 'not a patch\n' >"$BAD_PATCH_FILE"
if "${METABRAIN[@]}" patch --store "$STORE" --path /notes/patchable --patch-file "$BAD_PATCH_FILE" 2>"$TMP_DIR/bad-patch.err"; then
    echo "Expected malformed patch to fail" >&2
    exit 1
fi
rg -q 'Patch does not contain any hunks' "$TMP_DIR/bad-patch.err"

BAD_UTF8_PATCH_FILE="$TMP_DIR/bad-utf8.patch"
printf '\xff' >"$BAD_UTF8_PATCH_FILE"
if "${METABRAIN[@]}" patch --store "$STORE" --path /notes/patchable --patch-file "$BAD_UTF8_PATCH_FILE" 2>"$TMP_DIR/bad-utf8-patch.err"; then
    echo "Expected invalid UTF-8 patch to fail" >&2
    exit 1
fi
rg -q 'Patch file must be UTF-8 text' "$TMP_DIR/bad-utf8-patch.err"

MISMATCH_PATCH_FILE="$TMP_DIR/mismatch.patch"
cat >"$MISMATCH_PATCH_FILE" <<'PATCH'
@@ -1 +1 @@
-one old patchable memory
+one newer patchable memory
PATCH
if "${METABRAIN[@]}" patch --store "$STORE" --path /notes/patchable --patch-file "$MISMATCH_PATCH_FILE" 2>"$TMP_DIR/mismatch-patch.err"; then
    echo "Expected patch context mismatch to fail" >&2
    exit 1
fi
rg -q 'Patch context mismatch' "$TMP_DIR/mismatch-patch.err"

if "${METABRAIN[@]}" patch --store "$STORE" --path /missing --patch-file "$PATCH_FILE" 2>"$TMP_DIR/missing-patch.err"; then
    echo "Expected missing patch document to fail" >&2
    exit 1
fi
rg -q 'Document not found' "$TMP_DIR/missing-patch.err"

if "${METABRAIN[@]}" versions --store "$STORE" 2>"$TMP_DIR/missing-version-reference.err"; then
    echo "Expected missing version reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-version-reference.err"
rg -F -q 'Usage: metabrain versions [--store <store>] [--id <id>] [--path <path>] [<path>]' "$TMP_DIR/missing-version-reference.err"

if "${METABRAIN[@]}" prune --store "$STORE" --path /notes/today 2>"$TMP_DIR/missing-retention.err"; then
    echo "Expected missing prune retention policy to fail" >&2
    exit 1
fi
rg -q 'Provide one of --keep-all, --keep-last, or --keep-within' "$TMP_DIR/missing-retention.err"
rg -F -q 'Usage: metabrain prune [--store <store>] [--id <id>] [--path <path>] [<path>] [--keep-all] [--keep-last <keep-last>] [--keep-within <keep-within>]' "$TMP_DIR/missing-retention.err"

if "${METABRAIN[@]}" get --store "$STORE" 2>"$TMP_DIR/missing-reference.err"; then
    echo "Expected missing reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-reference.err"
rg -F -q 'Usage: metabrain get [--store <store>] [--id <id>] [--path <path>] [<path>]' "$TMP_DIR/missing-reference.err"
