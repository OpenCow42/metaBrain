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
    METABRAIN=(swift run mb)
fi

cd "$ROOT_DIR"

assert_put_json() {
    local actual="$1"
    local expected_path="$2"
    local expected_status="$3"
    local expected_version="$4"
    local pattern='^\{"documentID":"[0-9a-f-]+","operation":"put","path":"'"$expected_path"'","status":"'"$expected_status"'","version":'"$expected_version"'\}$'

    if [[ "$actual" == *$'\n'* ]] || ! printf '%s\n' "$actual" | rg -q "$pattern"; then
        echo "Expected put JSON for $expected_path v$expected_version, got: $actual" >&2
        exit 1
    fi
}

assert_put_text() {
    local actual="$1"
    local expected_path="$2"
    local expected_version="$3"
    local pattern="^id: [0-9a-f-]+"$'\n'"path: $expected_path"$'\n'"version: $expected_version$"

    if [[ ! "$actual" =~ $pattern ]]; then
        echo "Expected put text for $expected_path v$expected_version, got: $actual" >&2
        exit 1
    fi
}

assert_patch_write_json() {
    local actual="$1"
    local expected_path="$2"
    local expected_version="$3"
    local pattern='^\{"documentID":"[0-9a-f-]+","operation":"patch","path":"'"$expected_path"'","status":"patched","version":'"$expected_version"'\}$'

    if [[ "$actual" == *$'\n'* ]] || ! printf '%s\n' "$actual" | rg -q "$pattern"; then
        echo "Expected patch JSON for $expected_path v$expected_version, got: $actual" >&2
        exit 1
    fi
}

assert_patch_check_json() {
    local actual="$1"
    local expected='{"check":true,"operation":"patch","status":"applies","success":true}'

    if [[ "$actual" != "$expected" ]]; then
        echo "Expected patch check JSON, got: $actual" >&2
        exit 1
    fi
}

assert_move_json() {
    local actual="$1"
    local expected_from="$2"
    local expected_path="$3"
    local expected_status="$4"
    local expected_version="$5"
    local pattern='^\{"documentID":"[0-9a-f-]+","from":"'"$expected_from"'","operation":"move","path":"'"$expected_path"'","status":"'"$expected_status"'","version":'"$expected_version"'\}$'

    if [[ "$actual" == *$'\n'* ]] || ! printf '%s\n' "$actual" | rg -q "$pattern"; then
        echo "Expected move JSON from $expected_from to $expected_path v$expected_version, got: $actual" >&2
        exit 1
    fi
}

assert_get_json() {
    local actual="$1"
    local expected_path="$2"
    local expected_body="$3"
    local expected_version="$4"

    if [[ "$actual" == *$'\n'* ]]; then
        echo "Expected get JSON on one line, got: $actual" >&2
        exit 1
    fi

    printf '%s\n' "$actual" | rg -q '^\{.*\}$'
    printf '%s\n' "$actual" | rg -q '"documentID":"[0-9a-f-]+"'
    printf '%s\n' "$actual" | rg -F -q '"path":"'"$expected_path"'"'
    printf '%s\n' "$actual" | rg -F -q '"body":"'"$expected_body"'"'
    printf '%s\n' "$actual" | rg -F -q '"version":'"$expected_version"
    printf '%s\n' "$actual" | rg -q '"createdAt":"[^"]+"'
    printf '%s\n' "$actual" | rg -q '"updatedAt":"[^"]+"'
}

assert_get_today_text() {
    local actual="$1"
    local pattern='^id: [0-9a-f-]+'$'\n''path: /notes/today'$'\n''title: Today'$'\n''version: 1'$'\n''tags: search, daily'$'\n''metadata: kind=daily, status=active'$'\n\n''alpha beta searchable memory$'

    if [[ ! "$actual" =~ $pattern ]]; then
        echo "Expected get text output for /notes/today, got: $actual" >&2
        exit 1
    fi
}

assert_line_count() {
    local actual="$1"
    local expected="$2"
    local count

    if [[ -z "$actual" ]]; then
        count=0
    else
        count="$(printf '%s\n' "$actual" | wc -l | tr -d ' ')"
    fi

    if [[ "$count" != "$expected" ]]; then
        echo "Expected $expected output lines, got $count: $actual" >&2
        exit 1
    fi
}

assert_search_jsonl_result() {
    local actual="$1"
    local expected_path="$2"
    local expected_term="$3"

    assert_line_count "$actual" 1
    printf '%s\n' "$actual" | rg -q '^\{.*\}$'
    printf '%s\n' "$actual" | rg -q '"documentID":"[0-9a-f-]+"'
    printf '%s\n' "$actual" | rg -F -q '"path":"'"$expected_path"'"'
    printf '%s\n' "$actual" | rg -q '"chunkOrdinal":[0-9]+'
    printf '%s\n' "$actual" | rg -q '"score":[0-9]+(\.[0-9]+)?'
    printf '%s\n' "$actual" | rg -F -q "$expected_term"
    printf '%s\n' "$actual" | rg -F -q '"context":['
    printf '%s\n' "$actual" | rg -F -q '"linkedDocuments":['
    printf '%s\n' "$actual" | rg -F -q '"backlinks":['
}

assert_versions_jsonl() {
    local actual="$1"
    local expected_path="$2"
    local expected_count="$3"

    assert_line_count "$actual" "$expected_count"
    printf '%s\n' "$actual" | rg -q '^\{.*\}$'
    printf '%s\n' "$actual" | rg -q '"documentID":"[0-9a-f-]+"'
    printf '%s\n' "$actual" | rg -F -q '"path":"'"$expected_path"'"'
    printf '%s\n' "$actual" | rg -q '"sequence":[0-9]+'
    printf '%s\n' "$actual" | rg -q '"createdAt":"[^"]+"'
    printf '%s\n' "$actual" | rg -q '"isPinned":(true|false)'
    if printf '%s\n' "$actual" | rg -F -q '"body":'; then
        echo "Expected versions JSONL summary without body snapshots, got: $actual" >&2
        exit 1
    fi
}

assert_prune_json() {
    local actual="$1"
    local expected_pruned="$2"
    local expected_retained="$3"
    local expected='{"operation":"prune","prunedVersionCount":'"$expected_pruned"',"retainedVersionCount":'"$expected_retained"',"status":"completed"}'

    if [[ "$actual" != "$expected" ]]; then
        echo "Expected prune JSON, got: $actual" >&2
        exit 1
    fi
}

assert_delete_json() {
    local actual="$1"
    local expected_reference="$2"
    local expected_deleted="$3"
    local expected='{"deleted":'"$expected_deleted"',"operation":"delete","reference":"'"$expected_reference"'","status":"completed"}'

    if [[ "$actual" != "$expected" ]]; then
        echo "Expected delete JSON, got: $actual" >&2
        exit 1
    fi
}

assert_remove_version_json() {
    local actual="$1"
    local expected_reference="$2"
    local expected_removed="$3"
    local expected_sequence="$4"
    local expected='{"operation":"remove-version","reference":"'"$expected_reference"'","removed":'"$expected_removed"',"sequence":'"$expected_sequence"',"status":"completed"}'

    if [[ "$actual" != "$expected" ]]; then
        echo "Expected remove-version JSON, got: $actual" >&2
        exit 1
    fi
}

"${METABRAIN[@]}" | rg -q 'Agent discovery:'
"${METABRAIN[@]}" --help | rg -q 'Common workflow:'
"${METABRAIN[@]}" help | rg -q 'mb help search'
"${METABRAIN[@]}" help | rg -q 'mb help list'
"${METABRAIN[@]}" help | rg -q 'mb help tree'
"${METABRAIN[@]}" help | rg -q 'mb help dump'
"${METABRAIN[@]}" help | rg -q 'mb help move'
"${METABRAIN[@]}" help | rg -q 'mb help version'
"${METABRAIN[@]}" help init | rg -q 'Create or open a metaBrain store'
"${METABRAIN[@]}" help version | rg -q 'Print the metaBrain version and check GitHub releases'
"${METABRAIN[@]}" help put | rg -q 'Create or update a document at a path'
"${METABRAIN[@]}" help patch | rg -q 'Patch a document body with a unified diff'
"${METABRAIN[@]}" help move | rg -q 'Move an existing document to a new path without changing its ID'
"${METABRAIN[@]}" help move | rg -q 'document IDs are preserved'
"${METABRAIN[@]}" help move | rg -q 'Path references are location aliases'
"${METABRAIN[@]}" help get | rg -q 'Read a document by path or ID'
"${METABRAIN[@]}" help list | rg -q 'List stored document paths in a folder'
"${METABRAIN[@]}" help tree | rg -q 'Show the stored document path tree'
"${METABRAIN[@]}" help search | rg -q 'Search current document content'
"${METABRAIN[@]}" help dump | rg -q 'Dump stored documents as JSONL'
"${METABRAIN[@]}" help versions | rg -q 'List stored versions for a document'
"${METABRAIN[@]}" help prune | rg -q 'Prune document versions using a retention policy'
"${METABRAIN[@]}" help delete | rg -q 'Delete a document and all retained versions'
"${METABRAIN[@]}" help remove-version | rg -q 'Remove one retained historical document version'
VERSION_DEFAULT_JSON="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --no-release-check)"
if [[ "$VERSION_DEFAULT_JSON" != '{"currentTag":"9.8.7","releaseCheck":null}' ]]; then
    echo "Expected version default JSON output without release check, got: $VERSION_DEFAULT_JSON" >&2
    exit 1
fi
VERSION_TEXT="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --no-release-check --format text)"
if [[ "$VERSION_TEXT" != $'version: 9.8.7\nreleaseCheck: skipped' ]]; then
    echo "Expected version text output without release check, got: $VERSION_TEXT" >&2
    exit 1
fi
VERSION_JSON="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --no-release-check --format json)"
if [[ "$VERSION_JSON" != "$VERSION_DEFAULT_JSON" ]]; then
    echo "Expected version JSON output without release check, got: $VERSION_JSON" >&2
    exit 1
fi

if "${METABRAIN[@]}" help missing 2>"$TMP_DIR/help-missing.err"; then
    echo "Expected unknown help topic to fail" >&2
    exit 1
fi
rg -F -q 'Usage: mb help [<command>]' "$TMP_DIR/help-missing.err"
rg -F -q 'delete' "$TMP_DIR/help-missing.err"
rg -F -q 'remove-version' "$TMP_DIR/help-missing.err"

if "${METABRAIN[@]}" init --unknown-option 2>"$TMP_DIR/init-invalid.err"; then
    echo "Expected invalid init option to fail" >&2
    exit 1
fi
rg -F -q 'Usage: mb init [--store <store>] [--format <format>]' "$TMP_DIR/init-invalid.err"

if "${METABRAIN[@]}" search query --limit 0 2>"$TMP_DIR/search-invalid.err"; then
    echo "Expected invalid search limit to fail" >&2
    exit 1
fi
rg -F -q 'Usage: mb search [--store <store>]' "$TMP_DIR/search-invalid.err"
rg -F -q '[--format <format>]' "$TMP_DIR/search-invalid.err"

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
PUT_TODAY_JSON="$("${METABRAIN[@]}" put --store "$STORE" /notes/today 'alpha beta searchable memory' --title Today --tag search --tag daily --meta status=active --meta kind=daily)"
assert_put_json "$PUT_TODAY_JSON" /notes/today created 1
GET_TODAY_DEFAULT_JSON="$("${METABRAIN[@]}" get --store "$STORE" /notes/today)"
assert_get_json "$GET_TODAY_DEFAULT_JSON" /notes/today 'alpha beta searchable memory' 1
printf '%s\n' "$GET_TODAY_DEFAULT_JSON" | rg -F -q '"metadata":{"kind":"daily","status":"active"}'
printf '%s\n' "$GET_TODAY_DEFAULT_JSON" | rg -F -q '"references":[]'
printf '%s\n' "$GET_TODAY_DEFAULT_JSON" | rg -F -q '"tags":["search","daily"]'
printf '%s\n' "$GET_TODAY_DEFAULT_JSON" | rg -F -q '"title":"Today"'
GET_TODAY_TEXT="$("${METABRAIN[@]}" get --store "$STORE" --format text /notes/today)"
assert_get_today_text "$GET_TODAY_TEXT"
GET_TODAY_JSONL="$("${METABRAIN[@]}" get --store "$STORE" --format jsonl --path /notes/today)"
if [[ "$GET_TODAY_JSONL" != "$GET_TODAY_DEFAULT_JSON" ]]; then
    echo "Expected get JSONL to match compact JSON output, got: $GET_TODAY_JSONL" >&2
    exit 1
fi
GET_TODAY_ID="$(printf '%s\n' "$GET_TODAY_DEFAULT_JSON" | sed -E 's/.*"documentID":"([^"]+)".*/\1/')"
GET_TODAY_BY_ID_JSONL="$("${METABRAIN[@]}" get --store "$STORE" --format jsonl --id "$GET_TODAY_ID")"
assert_get_json "$GET_TODAY_BY_ID_JSONL" /notes/today 'alpha beta searchable memory' 1
PUT_ARCHIVE_TEXT="$("${METABRAIN[@]}" put --store "$STORE" --format text /notes/archive/final 'archived memory')"
assert_put_text "$PUT_ARCHIVE_TEXT" /notes/archive/final 1
PUT_PATCHABLE_JSONL="$("${METABRAIN[@]}" put --store "$STORE" --format jsonl /notes/patchable 'one old patchable memory' --tag patch)"
assert_put_json "$PUT_PATCHABLE_JSONL" /notes/patchable created 1
DUMP_NOTES_DEFAULT_JSONL="$("${METABRAIN[@]}" dump --store "$STORE" /notes)"
assert_line_count "$DUMP_NOTES_DEFAULT_JSONL" 3
printf '%s\n' "$DUMP_NOTES_DEFAULT_JSONL" >"$TMP_DIR/dump-notes.jsonl"
rg -F -q '"path":"/notes/archive/final"' "$TMP_DIR/dump-notes.jsonl"
rg -F -q '"path":"/notes/today"' "$TMP_DIR/dump-notes.jsonl"
rg -F -q '"body":"alpha beta searchable memory"' "$TMP_DIR/dump-notes.jsonl"
rg -F -q '"references":[]' "$TMP_DIR/dump-notes.jsonl"
rg -q '"documentID":"[0-9a-f-]+"' "$TMP_DIR/dump-notes.jsonl"
if rg -F -q '"path":"/refs/target"' "$TMP_DIR/dump-notes.jsonl"; then
    echo "Expected /notes dump to exclude unrelated paths" >&2
    exit 1
fi
DUMP_NOTES_TEXT="$("${METABRAIN[@]}" dump --store "$STORE" /notes --format text)"
if [[ "$DUMP_NOTES_TEXT" != "$DUMP_NOTES_DEFAULT_JSONL" ]]; then
    echo "Expected dump text output to match legacy JSONL output, got: $DUMP_NOTES_TEXT" >&2
    exit 1
fi
DUMP_NOTES_JSONL="$("${METABRAIN[@]}" dump --store "$STORE" /notes --format jsonl)"
if [[ "$DUMP_NOTES_JSONL" != "$DUMP_NOTES_DEFAULT_JSONL" ]]; then
    echo "Expected explicit dump JSONL output to match default output, got: $DUMP_NOTES_JSONL" >&2
    exit 1
fi
DUMP_NOTES_JSON="$("${METABRAIN[@]}" dump --store "$STORE" /notes --format json)"
assert_line_count "$DUMP_NOTES_JSON" 1
printf '%s\n' "$DUMP_NOTES_JSON" | rg -q '^\[.*\]$'
printf '%s\n' "$DUMP_NOTES_JSON" | rg -F -q '"path":"/notes/archive/final"'
printf '%s\n' "$DUMP_NOTES_JSON" | rg -F -q '"path":"/notes/today"'
printf '%s\n' "$DUMP_NOTES_JSON" | rg -F -q '"body":"alpha beta searchable memory"'
DUMP_MISSING_DEFAULT_JSONL="$("${METABRAIN[@]}" dump --store "$STORE" /missing)"
if [[ -n "$DUMP_MISSING_DEFAULT_JSONL" ]]; then
    echo "Expected missing dump path to produce no default JSONL entries, got: $DUMP_MISSING_DEFAULT_JSONL" >&2
    exit 1
fi
DUMP_MISSING_JSONL="$("${METABRAIN[@]}" dump --store "$STORE" /missing --format jsonl)"
if [[ -n "$DUMP_MISSING_JSONL" ]]; then
    echo "Expected missing dump path to produce no explicit JSONL entries, got: $DUMP_MISSING_JSONL" >&2
    exit 1
fi
DUMP_MISSING_JSON="$("${METABRAIN[@]}" dump --store "$STORE" /missing --format json)"
if [[ "$DUMP_MISSING_JSON" != "[]" ]]; then
    echo "Expected missing dump path to produce an empty JSON array, got: $DUMP_MISSING_JSON" >&2
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
PATCH_CHECK_JSON="$("${METABRAIN[@]}" patch --store "$STORE" /notes/patchable --patch-file "$PATCH_FILE" --check)"
assert_patch_check_json "$PATCH_CHECK_JSON"
"${METABRAIN[@]}" get --store "$STORE" /notes/patchable | rg -q 'one old patchable memory'
PATCH_WRITE_JSON="$("${METABRAIN[@]}" patch --store "$STORE" /notes/patchable --patch-file "$PATCH_FILE")"
assert_patch_write_json "$PATCH_WRITE_JSON" /notes/patchable 2
"${METABRAIN[@]}" get --store "$STORE" /notes/patchable | rg -q 'one fresh patchable memory'
SEARCH_PATCH_DEFAULT_JSONL="$("${METABRAIN[@]}" search --store "$STORE" fresh --tag patch)"
assert_search_jsonl_result "$SEARCH_PATCH_DEFAULT_JSONL" /notes/patchable fresh
SEARCH_PATCH_EXPLICIT_JSONL="$("${METABRAIN[@]}" search --store "$STORE" fresh --tag patch --format jsonl)"
if [[ "$SEARCH_PATCH_EXPLICIT_JSONL" != "$SEARCH_PATCH_DEFAULT_JSONL" ]]; then
    echo "Expected explicit search JSONL to match default JSONL output, got: $SEARCH_PATCH_EXPLICIT_JSONL" >&2
    exit 1
fi
"${METABRAIN[@]}" search --store "$STORE" fresh --tag patch --format text | rg -q '^/notes/patchable'
SEARCH_OLD_DEFAULT_JSONL="$("${METABRAIN[@]}" search --store "$STORE" old --tag patch)"
if [[ -n "$SEARCH_OLD_DEFAULT_JSONL" ]]; then
    echo "Expected default search JSONL with no results to produce no output, got: $SEARCH_OLD_DEFAULT_JSONL" >&2
    exit 1
fi
SEARCH_OLD_JSON="$("${METABRAIN[@]}" search --store "$STORE" old --tag patch --format json)"
if [[ "$SEARCH_OLD_JSON" != "[]" ]]; then
    echo "Expected search JSON with no results to produce [], got: $SEARCH_OLD_JSON" >&2
    exit 1
fi
"${METABRAIN[@]}" search --store "$STORE" old --tag patch --format text | rg -q '^No results\.$'
"${METABRAIN[@]}" put --store "$STORE" --format text /notes/stdin-patch 'stdin old memory' | rg -q '^version: 1$'
STDIN_PATCH_FILE="$TMP_DIR/stdin-patch.diff"
cat >"$STDIN_PATCH_FILE" <<'PATCH'
@@ -1 +1 @@
-stdin old memory
\ No newline at end of file
+stdin fresh memory
\ No newline at end of file
PATCH
"${METABRAIN[@]}" patch --store "$STORE" --path /notes/stdin-patch --patch-file - --format text --check <"$STDIN_PATCH_FILE" | rg -q '^patch applies$'
PATCH_STDIN_TEXT="$("${METABRAIN[@]}" patch --store "$STORE" --path /notes/stdin-patch --patch-file - --format text <"$STDIN_PATCH_FILE")"
assert_put_text "$PATCH_STDIN_TEXT" /notes/stdin-patch 2
"${METABRAIN[@]}" get --store "$STORE" --path /notes/stdin-patch | rg -q 'stdin fresh memory'
"${METABRAIN[@]}" put --store "$STORE" --format text /notes/jsonl-patch 'jsonl old memory' | rg -q '^version: 1$'
JSONL_PATCH_FILE="$TMP_DIR/jsonl-patch.diff"
cat >"$JSONL_PATCH_FILE" <<'PATCH'
@@ -1 +1 @@
-jsonl old memory
\ No newline at end of file
+jsonl fresh memory
\ No newline at end of file
PATCH
PATCH_JSONL_CHECK="$("${METABRAIN[@]}" patch --store "$STORE" /notes/jsonl-patch --patch-file "$JSONL_PATCH_FILE" --format jsonl --check)"
assert_patch_check_json "$PATCH_JSONL_CHECK"
"${METABRAIN[@]}" get --store "$STORE" /notes/jsonl-patch | rg -q 'jsonl old memory'
PATCH_JSONL_WRITE="$("${METABRAIN[@]}" patch --store "$STORE" /notes/jsonl-patch --patch-file "$JSONL_PATCH_FILE" --format jsonl)"
assert_patch_write_json "$PATCH_JSONL_WRITE" /notes/jsonl-patch 2
"${METABRAIN[@]}" get --store "$STORE" /notes/jsonl-patch | rg -q 'jsonl fresh memory'
LIST_ROOT_JSONL="$("${METABRAIN[@]}" list --store "$STORE")"
assert_line_count "$LIST_ROOT_JSONL" 1
printf '%s\n' "$LIST_ROOT_JSONL" | rg -q '^\{.*"hasChildren":true.*"name":"notes".*"path":"/notes".*\}$'
LIST_ROOT_TEXT="$("${METABRAIN[@]}" list --store "$STORE" --format text)"
printf '%s\n' "$LIST_ROOT_TEXT" | rg -q '^notes/$'
LIST_ROOT_EXPLICIT_JSONL="$("${METABRAIN[@]}" list --store "$STORE" --format jsonl)"
if [[ "$LIST_ROOT_EXPLICIT_JSONL" != "$LIST_ROOT_JSONL" ]]; then
    echo "Expected explicit list JSONL to match default JSONL output, got: $LIST_ROOT_EXPLICIT_JSONL" >&2
    exit 1
fi
LIST_NOTES_JSON="$("${METABRAIN[@]}" list --store "$STORE" /notes --format json)"
assert_line_count "$LIST_NOTES_JSON" 1
printf '%s\n' "$LIST_NOTES_JSON" | rg -q '^\[.*\]$'
printf '%s\n' "$LIST_NOTES_JSON" | rg -F -q '"path":"/notes/today"'
printf '%s\n' "$LIST_NOTES_JSON" | rg -q '"documentID":"[0-9a-f-]+"'
printf '%s\n' "$LIST_NOTES_JSON" | rg -q '"createdAt":"[^"]+"'
printf '%s\n' "$LIST_NOTES_JSON" | rg -q '"updatedAt":"[^"]+"'
LIST_NOTES_JSONL="$("${METABRAIN[@]}" list --store "$STORE" /notes --format jsonl)"
printf '%s\n' "$LIST_NOTES_JSONL" | rg -F -q '"path":"/notes/today"'
printf '%s\n' "$LIST_NOTES_JSONL" | rg -F -q '"path":"/notes/archive"'
"${METABRAIN[@]}" list --store "$STORE" --recursive | rg -F -q '"path":"/notes/archive/final"'
"${METABRAIN[@]}" list --store "$STORE" --format text --recursive | rg -q '^notes/archive/final$'
"${METABRAIN[@]}" list --store "$STORE" /notes --format text | rg -q '^today$'
"${METABRAIN[@]}" list --store "$STORE" /notes --format text --recursive | rg -q '^archive/final$'
"${METABRAIN[@]}" list --store "$STORE" /notes --recursive --directories-only | rg -F -q '"path":"/notes/archive"'
"${METABRAIN[@]}" list --store "$STORE" /notes --format text --recursive --directories-only | rg -q '^archive/$'
"${METABRAIN[@]}" list --store "$STORE" /notes --format text --dates | rg -q '^today  created=.* updated=.*'
TREE_ROOT_JSONL="$("${METABRAIN[@]}" tree --store "$STORE")"
printf '%s\n' "$TREE_ROOT_JSONL" | rg -F -q '{"createdAt":null,"documentID":null,"hasChildren":true,"kind":"root","name":"/","path":"/","updatedAt":null}'
printf '%s\n' "$TREE_ROOT_JSONL" | rg -F -q '{"createdAt":null,"documentID":null,"hasChildren":true,"kind":"entry","name":"notes","path":"/notes","updatedAt":null}'
printf '%s\n' "$TREE_ROOT_JSONL" | rg -q '^\{"createdAt":"[^"]+","documentID":"[0-9a-f-]+","hasChildren":false,"kind":"entry","name":"today","path":"/notes/today","updatedAt":"[^"]+"\}$'
TREE_ROOT_JSON="$("${METABRAIN[@]}" tree --store "$STORE" --format json)"
assert_line_count "$TREE_ROOT_JSON" 1
printf '%s\n' "$TREE_ROOT_JSON" | rg -q '^\[.*\]$'
printf '%s\n' "$TREE_ROOT_JSON" | rg -F -q '"kind":"root"'
printf '%s\n' "$TREE_ROOT_JSON" | rg -F -q '"path":"/notes/today"'
TREE_ROOT_EXPLICIT_JSONL="$("${METABRAIN[@]}" tree --store "$STORE" --format jsonl)"
if [[ "$TREE_ROOT_EXPLICIT_JSONL" != "$TREE_ROOT_JSONL" ]]; then
    echo "Expected explicit tree JSONL to match default JSONL output, got: $TREE_ROOT_EXPLICIT_JSONL" >&2
    exit 1
fi
TREE_TEXT="$("${METABRAIN[@]}" tree --store "$STORE" --format text --max-depth 2)"
printf '%s\n' "$TREE_TEXT" | rg -q '^/$'
printf '%s\n' "$TREE_TEXT" | rg -q '^`-- notes/$'
TREE_DIRECTORIES_JSONL="$("${METABRAIN[@]}" tree --store "$STORE" /notes --directories-only)"
assert_line_count "$TREE_DIRECTORIES_JSONL" 2
printf '%s\n' "$TREE_DIRECTORIES_JSONL" | rg -F -q '"kind":"root","name":"notes","path":"/notes"'
printf '%s\n' "$TREE_DIRECTORIES_JSONL" | rg -F -q '"kind":"entry","name":"archive","path":"/notes/archive"'
if printf '%s\n' "$TREE_DIRECTORIES_JSONL" | rg -F -q '"path":"/notes/today"'; then
    echo "Expected tree --directories-only to exclude documents" >&2
    exit 1
fi
"${METABRAIN[@]}" tree --store "$STORE" /notes --format text --directories-only | rg -q '^`-- archive/$'
TREE_MAX_DEPTH_ZERO_JSONL="$("${METABRAIN[@]}" tree --store "$STORE" --max-depth 0)"
assert_line_count "$TREE_MAX_DEPTH_ZERO_JSONL" 1
printf '%s\n' "$TREE_MAX_DEPTH_ZERO_JSONL" | rg -F -q '{"createdAt":null,"documentID":null,"hasChildren":false,"kind":"root","name":"/","path":"/","updatedAt":null}'
TREE_MAX_DEPTH_TWO_JSONL="$("${METABRAIN[@]}" tree --store "$STORE" --max-depth 2)"
assert_line_count "$TREE_MAX_DEPTH_TWO_JSONL" 7
printf '%s\n' "$TREE_MAX_DEPTH_TWO_JSONL" | rg -F -q '"path":"/notes/archive"'
if printf '%s\n' "$TREE_MAX_DEPTH_TWO_JSONL" | rg -F -q '"path":"/notes/archive/final"'; then
    echo "Expected tree --max-depth 2 to exclude deeper descendants" >&2
    exit 1
fi
LIST_MISSING_DEFAULT="$("${METABRAIN[@]}" list --store "$STORE" /missing)"
if [[ -n "$LIST_MISSING_DEFAULT" ]]; then
    echo "Expected missing list path to produce no default JSONL output, got: $LIST_MISSING_DEFAULT" >&2
    exit 1
fi
LIST_MISSING_JSON="$("${METABRAIN[@]}" list --store "$STORE" /missing --format json)"
if [[ "$LIST_MISSING_JSON" != "[]" ]]; then
    echo "Expected missing list path to produce empty JSON array, got: $LIST_MISSING_JSON" >&2
    exit 1
fi
LIST_MISSING_JSONL="$("${METABRAIN[@]}" list --store "$STORE" /missing --format jsonl)"
if [[ -n "$LIST_MISSING_JSONL" ]]; then
    echo "Expected missing list path to produce no explicit JSONL output, got: $LIST_MISSING_JSONL" >&2
    exit 1
fi
"${METABRAIN[@]}" list --store "$STORE" /missing --format text | rg -q '^No documents\.$'
TREE_MISSING_DEFAULT="$("${METABRAIN[@]}" tree --store "$STORE" /missing)"
if [[ -n "$TREE_MISSING_DEFAULT" ]]; then
    echo "Expected missing tree path to produce no default JSONL output, got: $TREE_MISSING_DEFAULT" >&2
    exit 1
fi
TREE_MISSING_JSON="$("${METABRAIN[@]}" tree --store "$STORE" /missing --format json)"
if [[ "$TREE_MISSING_JSON" != "[]" ]]; then
    echo "Expected missing tree path to produce empty JSON array, got: $TREE_MISSING_JSON" >&2
    exit 1
fi
TREE_MISSING_JSONL="$("${METABRAIN[@]}" tree --store "$STORE" /missing --format jsonl)"
if [[ -n "$TREE_MISSING_JSONL" ]]; then
    echo "Expected missing tree path to produce no explicit JSONL output, got: $TREE_MISSING_JSONL" >&2
    exit 1
fi
"${METABRAIN[@]}" tree --store "$STORE" /missing --format text | rg -q '^No documents\.$'
"${METABRAIN[@]}" tree --store "$STORE" --format text --max-depth 0 | rg -q '^/$'
TREE_MISSING_MAX_DEPTH_ZERO="$("${METABRAIN[@]}" tree --store "$STORE" /missing --max-depth 0)"
assert_line_count "$TREE_MISSING_MAX_DEPTH_ZERO" 1
printf '%s\n' "$TREE_MISSING_MAX_DEPTH_ZERO" | rg -F -q '{"createdAt":null,"documentID":null,"hasChildren":false,"kind":"root","name":"missing","path":"/missing","updatedAt":null}'
"${METABRAIN[@]}" get --store "$STORE" --format text /notes/today | rg -q 'alpha beta searchable memory'
"${METABRAIN[@]}" get --store "$STORE" --format text --path /notes/today | rg -q 'alpha beta searchable memory'
SEARCH_FILTERED_JSONL="$("${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag search --tag daily --meta status=active --meta kind=daily)"
assert_search_jsonl_result "$SEARCH_FILTERED_JSONL" /notes/today 'alpha beta'
printf '%s\n' "$SEARCH_FILTERED_JSONL" | rg -F -q '"title":"Today"'
SEARCH_FILTERED_TEXT="$("${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag search --tag daily --meta status=active --meta kind=daily --format text)"
printf '%s\n' "$SEARCH_FILTERED_TEXT" | rg -q '/notes/today'
printf '%s\n' "$SEARCH_FILTERED_TEXT" | rg -q '^title: Today$'
SEARCH_FILTERED_JSON="$("${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag search --tag daily --meta status=active --meta kind=daily --format json)"
assert_line_count "$SEARCH_FILTERED_JSON" 1
printf '%s\n' "$SEARCH_FILTERED_JSON" | rg -q '^\[.*\]$'
printf '%s\n' "$SEARCH_FILTERED_JSON" | rg -F -q '"path":"/notes/today"'
printf '%s\n' "$SEARCH_FILTERED_JSON" | rg -F -q '"title":"Today"'
SEARCH_MISSING_TAG_JSONL="$("${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag missing)"
if [[ -n "$SEARCH_MISSING_TAG_JSONL" ]]; then
    echo "Expected filtered search with no results to produce no default JSONL output, got: $SEARCH_MISSING_TAG_JSONL" >&2
    exit 1
fi
"${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag missing --format text | rg -q '^No results\.$'
PUT_TODAY_UPDATE_JSON="$("${METABRAIN[@]}" put --store "$STORE" /notes/today 'alpha beta updated memory' --keep-last 2)"
assert_put_json "$PUT_TODAY_UPDATE_JSON" /notes/today updated 2
"${METABRAIN[@]}" dump --store "$STORE" /notes/today --versions >"$TMP_DIR/dump-today-versions.jsonl"
rg -F -q '"version":1' "$TMP_DIR/dump-today-versions.jsonl"
rg -F -q '"version":2' "$TMP_DIR/dump-today-versions.jsonl"
rg -F -q '"isCurrent":true' "$TMP_DIR/dump-today-versions.jsonl"
DUMP_OUTPUT_DIR="$TMP_DIR/dump-files"
"${METABRAIN[@]}" dump --store "$STORE" /notes/today --output-dir "$DUMP_OUTPUT_DIR" >"$TMP_DIR/dump-today-files.jsonl"
rg -F -q '"fileSystemPath":"' "$TMP_DIR/dump-today-files.jsonl"
DUMP_FILE="$(find "$DUMP_OUTPUT_DIR" -type f -name 'today__*__v2__*.md' | head -n 1)"
if [[ -z "$DUMP_FILE" || ! -f "$DUMP_FILE" ]]; then
    echo "Expected dump --output-dir to create a versioned copy" >&2
    exit 1
fi
rg -F -q 'alpha beta updated memory' "$DUMP_FILE"
VERSIONS_TODAY_DEFAULT_JSONL="$("${METABRAIN[@]}" versions --store "$STORE" /notes/today)"
assert_versions_jsonl "$VERSIONS_TODAY_DEFAULT_JSONL" /notes/today 2
printf '%s\n' "$VERSIONS_TODAY_DEFAULT_JSONL" | rg -F -q '"sequence":1'
printf '%s\n' "$VERSIONS_TODAY_DEFAULT_JSONL" | rg -F -q '"sequence":2'
VERSIONS_TODAY_EXPLICIT_JSONL="$("${METABRAIN[@]}" versions --store "$STORE" --path /notes/today --format jsonl)"
assert_versions_jsonl "$VERSIONS_TODAY_EXPLICIT_JSONL" /notes/today 2
VERSIONS_TODAY_BY_ID_JSONL="$("${METABRAIN[@]}" versions --store "$STORE" --id "$GET_TODAY_ID")"
assert_versions_jsonl "$VERSIONS_TODAY_BY_ID_JSONL" /notes/today 2
VERSIONS_TODAY_TEXT="$("${METABRAIN[@]}" versions --store "$STORE" /notes/today --format text)"
printf '%s\n' "$VERSIONS_TODAY_TEXT" | rg -q '^1 [^ ]+ path=/notes/today pinned=false$'
printf '%s\n' "$VERSIONS_TODAY_TEXT" | rg -q '^2 [^ ]+ path=/notes/today pinned=false$'
VERSIONS_TODAY_JSON="$("${METABRAIN[@]}" versions --store "$STORE" /notes/today --format json)"
assert_line_count "$VERSIONS_TODAY_JSON" 1
printf '%s\n' "$VERSIONS_TODAY_JSON" | rg -q '^\[.*\]$'
printf '%s\n' "$VERSIONS_TODAY_JSON" | rg -q '"documentID":"[0-9a-f-]+"'
printf '%s\n' "$VERSIONS_TODAY_JSON" | rg -F -q '"path":"/notes/today"'
printf '%s\n' "$VERSIONS_TODAY_JSON" | rg -F -q '"sequence":1'
printf '%s\n' "$VERSIONS_TODAY_JSON" | rg -F -q '"sequence":2'
if printf '%s\n' "$VERSIONS_TODAY_JSON" | rg -F -q '"body":'; then
    echo "Expected versions JSON summary without body snapshots, got: $VERSIONS_TODAY_JSON" >&2
    exit 1
fi
PRUNE_TODAY_DEFAULT_JSON="$("${METABRAIN[@]}" prune --store "$STORE" /notes/today --keep-last 1)"
assert_prune_json "$PRUNE_TODAY_DEFAULT_JSON" 1 1
PRUNE_TODAY_TEXT="$("${METABRAIN[@]}" prune --store "$STORE" --path /notes/today --keep-last 1 --format text)"
if [[ "$PRUNE_TODAY_TEXT" != $'pruned: 0\nretained: 1' ]]; then
    echo "Expected prune text output, got: $PRUNE_TODAY_TEXT" >&2
    exit 1
fi
PRUNE_TODAY_BY_ID_JSONL="$("${METABRAIN[@]}" prune --store "$STORE" --id "$GET_TODAY_ID" --keep-last 1 --format jsonl)"
assert_prune_json "$PRUNE_TODAY_BY_ID_JSONL" 0 1
"${METABRAIN[@]}" versions --store "$STORE" --path /notes/today --format text | rg -q '^2 '

BODY_FILE="$TMP_DIR/body.txt"
printf 'file body with gamma delta searchable terms\n' >"$BODY_FILE"
PUT_FILE_JSONL="$("${METABRAIN[@]}" put --store "$STORE" --format jsonl /notes/file --body-file "$BODY_FILE" --keep-all)"
assert_put_json "$PUT_FILE_JSONL" /notes/file created 1
"${METABRAIN[@]}" get --store "$STORE" --path /notes/file | rg -q 'file body with gamma delta'
SEARCH_LIMIT_JSONL="$("${METABRAIN[@]}" search --store "$STORE" gamma --path-prefix /notes --limit 1)"
assert_search_jsonl_result "$SEARCH_LIMIT_JSONL" /notes/file gamma
"${METABRAIN[@]}" search --store "$STORE" gamma --path-prefix /notes --limit 1 --format text | rg -q '^/notes/file'
VERSIONS_MISSING_DEFAULT_JSONL="$("${METABRAIN[@]}" versions --store "$STORE" --path /missing)"
if [[ -n "$VERSIONS_MISSING_DEFAULT_JSONL" ]]; then
    echo "Expected missing versions default JSONL to emit no stdout, got: $VERSIONS_MISSING_DEFAULT_JSONL" >&2
    exit 1
fi
VERSIONS_MISSING_JSONL="$("${METABRAIN[@]}" versions --store "$STORE" --path /missing --format jsonl)"
if [[ -n "$VERSIONS_MISSING_JSONL" ]]; then
    echo "Expected missing versions JSONL to emit no stdout, got: $VERSIONS_MISSING_JSONL" >&2
    exit 1
fi
VERSIONS_MISSING_JSON="$("${METABRAIN[@]}" versions --store "$STORE" --path /missing --format json)"
if [[ "$VERSIONS_MISSING_JSON" != "[]" ]]; then
    echo "Expected missing versions JSON array to be [], got: $VERSIONS_MISSING_JSON" >&2
    exit 1
fi
"${METABRAIN[@]}" versions --store "$STORE" --path /missing --format text | rg -q '^No versions\.$'
PRUNE_MISSING_JSON="$("${METABRAIN[@]}" prune --store "$STORE" --path /missing --keep-within 0)"
assert_prune_json "$PRUNE_MISSING_JSON" 0 0

PUT_MOVE_TARGET_JSON="$("${METABRAIN[@]}" put --store "$STORE" /move/target 'relocation anchor')"
assert_put_json "$PUT_MOVE_TARGET_JSON" /move/target created 1
MOVE_TARGET_ID="$(printf '%s\n' "$PUT_MOVE_TARGET_JSON" | sed -E 's/.*"documentID":"([^"]+)".*/\1/')"
PUT_MOVE_SOURCE_JSON="$("${METABRAIN[@]}" put --store "$STORE" /move/source 'relocated body' --title Move --tag moving --meta kind=move --ref-id "$MOVE_TARGET_ID")"
assert_put_json "$PUT_MOVE_SOURCE_JSON" /move/source created 1
MOVE_SOURCE_ID="$(printf '%s\n' "$PUT_MOVE_SOURCE_JSON" | sed -E 's/.*"documentID":"([^"]+)".*/\1/')"
MOVE_SOURCE_JSON="$("${METABRAIN[@]}" move --store "$STORE" /move/source /move/archive/source)"
assert_move_json "$MOVE_SOURCE_JSON" /move/source /move/archive/source moved 2
printf '%s\n' "$MOVE_SOURCE_JSON" | rg -F -q '"documentID":"'"$MOVE_SOURCE_ID"'"'
if "${METABRAIN[@]}" get --store "$STORE" /move/source 2>"$TMP_DIR/move-old-get.err"; then
    echo "Expected moved old path get to fail" >&2
    exit 1
fi
rg -q 'Document not found' "$TMP_DIR/move-old-get.err"
MOVE_SOURCE_GET_JSON="$("${METABRAIN[@]}" get --store "$STORE" /move/archive/source)"
assert_get_json "$MOVE_SOURCE_GET_JSON" /move/archive/source 'relocated body' 2
printf '%s\n' "$MOVE_SOURCE_GET_JSON" | rg -F -q '"documentID":"'"$MOVE_SOURCE_ID"'"'
printf '%s\n' "$MOVE_SOURCE_GET_JSON" | rg -F -q '"title":"Move"'
printf '%s\n' "$MOVE_SOURCE_GET_JSON" | rg -F -q '"tags":["moving"]'
printf '%s\n' "$MOVE_SOURCE_GET_JSON" | rg -F -q '"metadata":{"kind":"move"}'
printf '%s\n' "$MOVE_SOURCE_GET_JSON" | rg -F -q '"references":[{"kind":"documentID","value":"'"$MOVE_TARGET_ID"'"}]'
MOVE_SOURCE_BY_ID_TEXT="$("${METABRAIN[@]}" move --store "$STORE" --id "$MOVE_SOURCE_ID" /move/archive/source --format text)"
EXPECTED_MOVE_SOURCE_BY_ID_TEXT='id: '"$MOVE_SOURCE_ID"$'\n''from: /move/archive/source'$'\n''path: /move/archive/source'$'\n''version: 2'$'\n''status: unchanged'
if [[ "$MOVE_SOURCE_BY_ID_TEXT" != "$EXPECTED_MOVE_SOURCE_BY_ID_TEXT" ]]; then
    echo "Expected move by ID same path text output, got: $MOVE_SOURCE_BY_ID_TEXT" >&2
    exit 1
fi
if "${METABRAIN[@]}" move --store "$STORE" /move/missing /move/new-missing 2>"$TMP_DIR/move-missing.err"; then
    echo "Expected missing move source to fail" >&2
    exit 1
fi
rg -F -q 'Document not found: /move/missing.' "$TMP_DIR/move-missing.err"

"${METABRAIN[@]}" put --store "$STORE" --format text /delete/target 'delete target v1 needle' --keep-all | rg -q '^version: 1$'
"${METABRAIN[@]}" put --store "$STORE" --format text /delete/target 'delete target v2 needle' --keep-all | rg -q '^version: 2$'
DELETE_TARGET_TEXT="$("${METABRAIN[@]}" delete --store "$STORE" /delete/target --format text)"
if [[ "$DELETE_TARGET_TEXT" != $'deleted: true\nreference: /delete/target' ]]; then
    echo "Expected delete text output, got: $DELETE_TARGET_TEXT" >&2
    exit 1
fi
if "${METABRAIN[@]}" get --store "$STORE" /delete/target 2>"$TMP_DIR/delete-get.err"; then
    echo "Expected deleted document get to fail" >&2
    exit 1
fi
rg -q 'Document not found' "$TMP_DIR/delete-get.err"
VERSIONS_DELETED="$("${METABRAIN[@]}" versions --store "$STORE" /delete/target)"
if [[ -n "$VERSIONS_DELETED" ]]; then
    echo "Expected deleted document to have no retained versions, got: $VERSIONS_DELETED" >&2
    exit 1
fi
SEARCH_DELETED="$("${METABRAIN[@]}" search --store "$STORE" 'delete target needle' --path-prefix /delete)"
if [[ -n "$SEARCH_DELETED" ]]; then
    echo "Expected deleted document to be absent from search, got: $SEARCH_DELETED" >&2
    exit 1
fi
if "${METABRAIN[@]}" list --store "$STORE" /delete --format text | rg -q 'target'; then
    echo "Expected deleted document to be absent from list output" >&2
    exit 1
fi
if "${METABRAIN[@]}" tree --store "$STORE" /delete --format text | rg -q 'target'; then
    echo "Expected deleted document to be absent from tree output" >&2
    exit 1
fi
DELETE_MISSING_JSON="$("${METABRAIN[@]}" delete --store "$STORE" /delete/missing --format json)"
assert_delete_json "$DELETE_MISSING_JSON" /delete/missing false
DELETE_MISSING_JSONL="$("${METABRAIN[@]}" delete --store "$STORE" /delete/missing --format jsonl)"
assert_delete_json "$DELETE_MISSING_JSONL" /delete/missing false

"${METABRAIN[@]}" put --store "$STORE" --format text /versions/remove-text 'remove version text v1' --keep-all | rg -q '^version: 1$'
"${METABRAIN[@]}" put --store "$STORE" --format text /versions/remove-text 'remove version text v2' --keep-all | rg -q '^version: 2$'
REMOVE_VERSION_TEXT="$("${METABRAIN[@]}" remove-version --store "$STORE" /versions/remove-text --sequence 1 --format text)"
if [[ "$REMOVE_VERSION_TEXT" != $'removed: true\nsequence: 1\nreference: /versions/remove-text' ]]; then
    echo "Expected remove-version text output, got: $REMOVE_VERSION_TEXT" >&2
    exit 1
fi
"${METABRAIN[@]}" versions --store "$STORE" /versions/remove-text --format text | rg -q '^2 '
if "${METABRAIN[@]}" versions --store "$STORE" /versions/remove-text --format text | rg -q '^1 '; then
    echo "Expected removed sequence 1 to be absent from versions output" >&2
    exit 1
fi
REMOVE_VERSION_JSONL="$("${METABRAIN[@]}" remove-version --store "$STORE" /versions/remove-text --sequence 1 --format jsonl)"
assert_remove_version_json "$REMOVE_VERSION_JSONL" /versions/remove-text false 1

"${METABRAIN[@]}" put --store "$STORE" --format text /versions/remove-json 'remove version json v1' --keep-all | rg -q '^version: 1$'
"${METABRAIN[@]}" put --store "$STORE" --format text /versions/remove-json 'remove version json v2' --keep-all | rg -q '^version: 2$'
REMOVE_VERSION_JSON="$("${METABRAIN[@]}" remove-version --store "$STORE" /versions/remove-json --sequence 1 --format json)"
assert_remove_version_json "$REMOVE_VERSION_JSON" /versions/remove-json true 1
if "${METABRAIN[@]}" remove-version --store "$STORE" /versions/remove-json --sequence 2 2>"$TMP_DIR/remove-current-version.err"; then
    echo "Expected current version removal to fail" >&2
    exit 1
fi
rg -q 'Cannot remove current version 2' "$TMP_DIR/remove-current-version.err"
REMOVE_VERSION_MISSING_JSON="$("${METABRAIN[@]}" remove-version --store "$STORE" /versions/missing --sequence 1 --format json)"
assert_remove_version_json "$REMOVE_VERSION_MISSING_JSON" /versions/missing false 1

mkdir -p "$TMP_DIR/home-root" "$TMP_DIR/home-nested"
env METABRAIN_HOME="$TMP_DIR/home-root" "${METABRAIN[@]}" init --store '~' --format text | rg -q "Initialized metaBrain store at $TMP_DIR/home-root"
env METABRAIN_HOME="$TMP_DIR/home-nested" "${METABRAIN[@]}" init --store '~/.metabrain/store.leveldb' --format text | rg -q "Initialized metaBrain store at $TMP_DIR/home-nested/.metabrain/store.leveldb"

"${METABRAIN[@]}" put --store "$STORE" --format text /refs/target 'target needle reference' --title Target | rg -q '^version: 1$'
TARGET_ID="$("${METABRAIN[@]}" get --store "$STORE" --format text --path /refs/target | awk '/^id: / { print $2 }')"
"${METABRAIN[@]}" get --store "$STORE" --id "$TARGET_ID" | rg -q 'target needle reference'
"${METABRAIN[@]}" put --store "$STORE" --format text /refs/source 'source needle reference' --ref-id "$TARGET_ID" --ref-path /refs/target --ref-url https://example.com/ref | rg -q '^version: 1$'
"${METABRAIN[@]}" get --store "$STORE" --path /refs/source | rg -F -q '"references":[{"kind":"documentID","value":"'"$TARGET_ID"'"},{"kind":"path","value":"/refs/target"},{"kind":"externalURL","value":"https://example.com/ref"}]'
"${METABRAIN[@]}" get --store "$STORE" --format text --path /refs/source | rg -q "references: $TARGET_ID, /refs/target, https://example.com/ref"
SEARCH_LINKED_JSONL="$("${METABRAIN[@]}" search --store "$STORE" source --include-linked-documents)"
assert_search_jsonl_result "$SEARCH_LINKED_JSONL" /refs/source source
printf '%s\n' "$SEARCH_LINKED_JSONL" | rg -F -q '"linkedDocuments":[{"kind":"documentID","value":"'"$TARGET_ID"'"}]'
"${METABRAIN[@]}" search --store "$STORE" source --include-linked-documents --format text | rg -q '^linked: [0-9a-f-]+$'
SEARCH_BACKLINKS_JSONL="$("${METABRAIN[@]}" search --store "$STORE" target --include-backlinks)"
assert_search_jsonl_result "$SEARCH_BACKLINKS_JSONL" /refs/target target
printf '%s\n' "$SEARCH_BACKLINKS_JSONL" | rg -q '"backlinks":\[\{"kind":"documentID","value":"[0-9a-f-]+"\}\]'
"${METABRAIN[@]}" search --store "$STORE" target --include-backlinks --format text | rg -q '^backlinks: [0-9a-f-]+$'

LONG_BODY="$TMP_DIR/long-body.txt"
for _ in {1..650}; do
    printf 'context '
done >"$LONG_BODY"
printf 'needle ' >>"$LONG_BODY"
"${METABRAIN[@]}" put --store "$STORE" --format text /notes/long --body-file "$LONG_BODY" | rg -q '^version: 1$'
"${METABRAIN[@]}" search --store "$STORE" needle --path-prefix /notes/long --format text >"$TMP_DIR/long-search.out"
rg -q '^context: 0$' "$TMP_DIR/long-search.out"
rg -q '\.\.\.$' "$TMP_DIR/long-search.out"
SEARCH_CONTEXT_JSONL="$("${METABRAIN[@]}" search --store "$STORE" needle --path-prefix /notes/long)"
assert_search_jsonl_result "$SEARCH_CONTEXT_JSONL" /notes/long needle
printf '%s\n' "$SEARCH_CONTEXT_JSONL" | rg -F -q '"context":[{"ordinal":0,'
printf '%s\n' "$SEARCH_CONTEXT_JSONL" | rg -F -q '"text":"'

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
rg -F -q 'Usage: mb get [--store <store>] [--id <id>] [--path <path>] [<path>] [--format <format>]' "$TMP_DIR/double-reference.err"

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
rg -F -q 'Usage: mb put [<options>] <path> [<body>]' "$TMP_DIR/invalid-meta.err"

if "${METABRAIN[@]}" put --store "$STORE" /notes/no-body 2>"$TMP_DIR/missing-body.err"; then
    echo "Expected missing body to fail" >&2
    exit 1
fi
rg -q 'Provide a document body argument or --body-file' "$TMP_DIR/missing-body.err"
rg -F -q 'Usage: mb put [<options>] <path> [<body>]' "$TMP_DIR/missing-body.err"

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
rg -F -q 'Usage: mb put [<options>] <path> [<body>]' "$TMP_DIR/bad-ref-url.err"

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
rg -F -q 'Usage: mb versions [--store <store>] [--id <id>] [--path <path>] [<path>] [--format <format>]' "$TMP_DIR/missing-version-reference.err"

if "${METABRAIN[@]}" delete --store "$STORE" 2>"$TMP_DIR/missing-delete-reference.err"; then
    echo "Expected missing delete reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-delete-reference.err"
rg -F -q 'Usage: mb delete [--store <store>] [--id <id>] [--path <path>] [<path>] [--format <format>]' "$TMP_DIR/missing-delete-reference.err"

if "${METABRAIN[@]}" remove-version --store "$STORE" --sequence 1 2>"$TMP_DIR/missing-remove-version-reference.err"; then
    echo "Expected missing remove-version reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-remove-version-reference.err"
rg -F -q 'Usage: mb remove-version [--store <store>] [--id <id>] [--path <path>] [<path>] [--format <format>] --sequence <sequence>' "$TMP_DIR/missing-remove-version-reference.err"

if "${METABRAIN[@]}" remove-version --store "$STORE" /versions/remove-json 2>"$TMP_DIR/missing-remove-version-sequence.err"; then
    echo "Expected missing remove-version sequence to fail" >&2
    exit 1
fi
rg -q 'Missing expected (argument|option).*--sequence <sequence>' "$TMP_DIR/missing-remove-version-sequence.err"
rg -F -q 'Usage: mb remove-version [--store <store>] [--id <id>] [--path <path>] [<path>] [--format <format>] --sequence <sequence>' "$TMP_DIR/missing-remove-version-sequence.err"

if "${METABRAIN[@]}" remove-version --store "$STORE" /versions/remove-json --sequence 0 2>"$TMP_DIR/zero-remove-version-sequence.err"; then
    echo "Expected zero remove-version sequence to fail" >&2
    exit 1
fi
rg -q -- '--sequence must be greater than zero' "$TMP_DIR/zero-remove-version-sequence.err"

if "${METABRAIN[@]}" prune --store "$STORE" --path /notes/today 2>"$TMP_DIR/missing-retention.err"; then
    echo "Expected missing prune retention policy to fail" >&2
    exit 1
fi
rg -q 'Provide one of --keep-all, --keep-last, or --keep-within' "$TMP_DIR/missing-retention.err"
rg -F -q 'Usage: mb prune [--store <store>] [--id <id>] [--path <path>] [<path>] [--keep-all] [--keep-last <keep-last>] [--keep-within <keep-within>] [--format <format>]' "$TMP_DIR/missing-retention.err"

if "${METABRAIN[@]}" get --store "$STORE" 2>"$TMP_DIR/missing-reference.err"; then
    echo "Expected missing reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-reference.err"
rg -F -q 'Usage: mb get [--store <store>] [--id <id>] [--path <path>] [<path>] [--format <format>]' "$TMP_DIR/missing-reference.err"
