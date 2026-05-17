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
"${METABRAIN[@]}" help search | rg -q 'Search current document content'

if "${METABRAIN[@]}" help missing 2>"$TMP_DIR/help-missing.err"; then
    echo "Expected unknown help topic to fail" >&2
    exit 1
fi
rg -F -q 'Usage: metabrain help [<command>]' "$TMP_DIR/help-missing.err"

if "${METABRAIN[@]}" init --unknown-option 2>"$TMP_DIR/init-invalid.err"; then
    echo "Expected invalid init option to fail" >&2
    exit 1
fi
rg -F -q 'Usage: metabrain init [--store <store>]' "$TMP_DIR/init-invalid.err"

if "${METABRAIN[@]}" search query --limit 0 2>"$TMP_DIR/search-invalid.err"; then
    echo "Expected invalid search limit to fail" >&2
    exit 1
fi
rg -F -q 'Usage: metabrain search [--store <store>] <query>' "$TMP_DIR/search-invalid.err"

"${METABRAIN[@]}" init --store "$STORE" | rg -q 'Initialized metaBrain store'
"${METABRAIN[@]}" put --store "$STORE" /notes/today 'alpha beta searchable memory' --title Today --tag search --meta status=active --meta kind=daily | rg -q '^version: 1$'
"${METABRAIN[@]}" get --store "$STORE" --path /notes/today | rg -q 'alpha beta searchable memory'
"${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag search --meta status=active | rg -q '/notes/today'
"${METABRAIN[@]}" search --store "$STORE" 'alpha beta' --tag missing | rg -q '^No results\.$'
"${METABRAIN[@]}" put --store "$STORE" /notes/today 'alpha beta updated memory' --keep-last 2 | rg -q '^version: 2$'
"${METABRAIN[@]}" versions --store "$STORE" --path /notes/today | rg -q '^2 '
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
env METABRAIN_HOME="$TMP_DIR/home-root" "${METABRAIN[@]}" init --store '~' | rg -q "Initialized metaBrain store at $TMP_DIR/home-root"
env METABRAIN_HOME="$TMP_DIR/home-nested" "${METABRAIN[@]}" init --store '~/.metabrain/store.leveldb' | rg -q "Initialized metaBrain store at $TMP_DIR/home-nested/.metabrain/store.leveldb"

"${METABRAIN[@]}" put --store "$STORE" /refs/target 'target needle reference' --title Target | rg -q '^version: 1$'
TARGET_ID="$("${METABRAIN[@]}" get --store "$STORE" --path /refs/target | awk '/^id: / { print $2 }')"
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

if "${METABRAIN[@]}" get --store "$STORE" --id abc --path /notes/today 2>"$TMP_DIR/double-reference.err"; then
    echo "Expected duplicate reference options to fail" >&2
    exit 1
fi
rg -q 'Use only one of --id or --path' "$TMP_DIR/double-reference.err"
rg -F -q 'Usage: metabrain get [--store <store>] [--id <id>] [--path <path>]' "$TMP_DIR/double-reference.err"

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

if "${METABRAIN[@]}" versions --store "$STORE" 2>"$TMP_DIR/missing-version-reference.err"; then
    echo "Expected missing version reference options to fail" >&2
    exit 1
fi
rg -q 'Provide either --id or --path' "$TMP_DIR/missing-version-reference.err"
rg -F -q 'Usage: metabrain versions [--store <store>] [--id <id>] [--path <path>]' "$TMP_DIR/missing-version-reference.err"

if "${METABRAIN[@]}" prune --store "$STORE" --path /notes/today 2>"$TMP_DIR/missing-retention.err"; then
    echo "Expected missing prune retention policy to fail" >&2
    exit 1
fi
rg -q 'Provide one of --keep-all, --keep-last, or --keep-within' "$TMP_DIR/missing-retention.err"
rg -F -q 'Usage: metabrain prune [--store <store>] [--id <id>] [--path <path>] [--keep-all] [--keep-last <keep-last>] [--keep-within <keep-within>]' "$TMP_DIR/missing-retention.err"

if "${METABRAIN[@]}" get --store "$STORE" 2>"$TMP_DIR/missing-reference.err"; then
    echo "Expected missing reference options to fail" >&2
    exit 1
fi
rg -q 'Provide either --id or --path' "$TMP_DIR/missing-reference.err"
rg -F -q 'Usage: metabrain get [--store <store>] [--id <id>] [--path <path>]' "$TMP_DIR/missing-reference.err"
