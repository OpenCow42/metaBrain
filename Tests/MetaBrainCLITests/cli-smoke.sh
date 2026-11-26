#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Foundation can rewrite existing /private/tmp paths to /tmp on macOS.
TMP_PARENT="${METABRAIN_TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_PARENT/metabrain-cli.XXXXXX")"
STORE="$TMP_DIR/store.leveldb"
release_server_pid=""
daemon_server_pid=""

cleanup() {
    if [[ -n "$daemon_server_pid" ]] && kill -0 "$daemon_server_pid" 2>/dev/null; then
        kill "$daemon_server_pid" 2>/dev/null || true
        wait "$daemon_server_pid" 2>/dev/null || true
    fi
    if [[ -n "$release_server_pid" ]] && kill -0 "$release_server_pid" 2>/dev/null; then
        kill "$release_server_pid" 2>/dev/null || true
        wait "$release_server_pid" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ -n "${METABRAIN_BIN:-}" ]]; then
    METABRAIN=("$METABRAIN_BIN")
else
    METABRAIN=(swift run --package-path "$ROOT_DIR" mb)
fi

if [[ -n "${METABRAIN_DAEMON_BIN:-}" ]]; then
    METABRAIN_DAEMON=("$METABRAIN_DAEMON_BIN")
elif [[ -x "$ROOT_DIR/.build/debug/mbd" ]]; then
    METABRAIN_DAEMON=("$ROOT_DIR/.build/debug/mbd")
else
    METABRAIN_DAEMON=(swift run mbd)
fi

cd "$ROOT_DIR"

AUTO_EXPECTED_PORT="${METABRAIN_COVERAGE_LOOPBACK_PORT:-6374}"

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
"${METABRAIN[@]}" help | rg -q 'mb help recall'
"${METABRAIN[@]}" man | rg -F -q 'mb get /AGENTS.md'
"${METABRAIN[@]}" man search | rg -F -q 'mb get /AGENTS.md'
"${METABRAIN[@]}" help ensure-guide | rg -F -q 'default /AGENTS.md'
"${METABRAIN[@]}" help | rg -q 'mb help list'
"${METABRAIN[@]}" help | rg -q 'mb help tree'
"${METABRAIN[@]}" help | rg -q 'mb help dump'
"${METABRAIN[@]}" help | rg -q 'mb help preview'
"${METABRAIN[@]}" help | rg -q 'mb help move'
"${METABRAIN[@]}" help | rg -q 'mb help version'
"${METABRAIN[@]}" help init | rg -q 'Create or open a metaBrain store'
"${METABRAIN[@]}" help version | rg -q 'Print the metaBrain version'
"${METABRAIN[@]}" help put | rg -q 'Create or update a document at a path'
"${METABRAIN[@]}" help patch | rg -q 'Patch a document body with a unified diff'
"${METABRAIN[@]}" help move | rg -q 'Move an existing document to a new path without changing its ID'
"${METABRAIN[@]}" help move | rg -q 'document IDs are preserved'
"${METABRAIN[@]}" help move | rg -q 'Path references are location aliases'
"${METABRAIN[@]}" help get | rg -q 'Read a document by path or ID'
"${METABRAIN[@]}" help lint | rg -q 'Audit current Markdown citations'
"${METABRAIN[@]}" help list | rg -q 'List stored document paths in a folder'
"${METABRAIN[@]}" help tree | rg -q 'Show the stored document path tree'
"${METABRAIN[@]}" help search | rg -q 'Search current document content'
"${METABRAIN[@]}" help recall | rg -q 'byte-budgeted JSON array'
"${METABRAIN[@]}" help dump | rg -q 'Dump stored documents as JSONL'
"${METABRAIN[@]}" help preview | rg -q 'Validate and preview a project'
"${METABRAIN[@]}" help versions | rg -q 'List stored versions for a document'
"${METABRAIN[@]}" help prune | rg -q 'Prune document versions using a retention policy'
"${METABRAIN[@]}" help delete | rg -q 'Delete a document and all retained versions'
"${METABRAIN[@]}" help remove-version | rg -q 'Remove one retained historical document version'
VERSION_DEFAULT_JSON="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --no-release-check)"
if ! printf '%s\n' "$VERSION_DEFAULT_JSON" | rg -F -q '"currentTag":"9.8.7"'; then
    echo "Expected version default JSON output without release check, got: $VERSION_DEFAULT_JSON" >&2
    exit 1
fi
printf '%s\n' "$VERSION_DEFAULT_JSON" | rg -F -q '"endpoint":"http://127.0.0.1:'"$AUTO_EXPECTED_PORT"'"'
printf '%s\n' "$VERSION_DEFAULT_JSON" | rg -F -q '"reachable":false'
VERSION_STANDARD_ENDPOINT="$(env -u METABRAIN_COVERAGE_LOOPBACK_PORT "${METABRAIN[@]}" version --no-release-check)"
printf '%s\n' "$VERSION_STANDARD_ENDPOINT" | rg -F -q '"endpoint":"http://127.0.0.1:6374"'
VERSION_TEXT="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --no-server --no-release-check --format text)"
if [[ "$VERSION_TEXT" != $'version: 9.8.7\nserver: skipped\nreleaseCheck: skipped' ]]; then
    echo "Expected version text output without release check, got: $VERSION_TEXT" >&2
    exit 1
fi
VERSION_JSON="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --no-server --no-release-check --format json)"
if [[ "$VERSION_JSON" != '{"currentTag":"9.8.7","releaseCheck":null,"server":null}' ]]; then
    echo "Expected version JSON output without release check, got: $VERSION_JSON" >&2
    exit 1
fi
VERSION_JSONL="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --no-server --no-release-check --format jsonl)"
if [[ "$VERSION_JSONL" != "$VERSION_JSON" ]]; then
    echo "Expected version JSONL output without release check, got: $VERSION_JSONL" >&2
    exit 1
fi

release_port_file="$TMP_DIR/release-port"
python3 - "$release_port_file" <<'PY' &
import http.server
import json
import os
import socketserver
import sys

class Server(http.server.HTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path != "/latest":
            self.respond(503, b'{}')
            return

        body = b'{"html_url":"https://example.com/metabrain/releases/9.9.9","tag_name":"9.9.9"}'
        self.respond(200, body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/recall" and request["maxBytes"] == 3:
            result = [{"documentID": "sample", "path": "/sample.md", "version": 1, "sources": [], "passages": []}]
        elif self.path == "/v1/search-evidence" and request["maxTokens"] == 31:
            result = {"items": [{"ref": "sample@1#0-6", "path": "/sample.md", "text": "Sample"}], "truncated": False}
        elif self.path == "/v1/get-passage" and request.get("heading") == "Sample":
            text = "# Sample\n"
            result = {"documentID": "sample", "path": "/sample.md", "version": 1,
                      "start": 0, "end": len(text), "heading": "Sample", "text": text}
        else:
            self.respond(404, b'{}')
            return
        self.respond(200, json.dumps(result).encode())

    def respond(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

server = Server(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as file:
    file.write(str(server.server_port))
    file.flush()
    os.fsync(file.fileno())
server.serve_forever()
PY
release_server_pid="$!"
for _ in $(seq 1 400); do
    if [[ -s "$release_port_file" ]]; then
        break
    fi
    if ! kill -0 "$release_server_pid" 2>/dev/null; then
        echo "Release test server exited early." >&2
        exit 1
    fi
    sleep 0.05
done
if [[ ! -s "$release_port_file" ]]; then
    echo "Release test server did not report a port." >&2
    exit 1
fi
release_port="$(cat "$release_port_file")"

# Exercise the CLI's output limits with a daemon that ignores the requested budget.
budget_store="$TMP_DIR/budget-store.leveldb"
"${METABRAIN[@]}" --no-server init --empty --store "$budget_store" >/dev/null
budget_command=("${METABRAIN[@]}" --store "$budget_store" --server "http://127.0.0.1:$release_port")
if "${budget_command[@]}" recall sample --max-bytes 3 >"$TMP_DIR/budget.out" 2>"$TMP_DIR/budget.err"; then
    echo "Expected an over-budget recall response to fail" >&2
    exit 1
fi
[[ ! -s "$TMP_DIR/budget.out" ]]
rg -F -q 'Recall response exceeded --max-bytes 3.' "$TMP_DIR/budget.err"
if "${budget_command[@]}" search sample --view evidence --max-tokens 31 >"$TMP_DIR/budget.out" 2>"$TMP_DIR/budget.err"; then
    echo "Expected an over-budget evidence response to fail" >&2
    exit 1
fi
[[ ! -s "$TMP_DIR/budget.out" ]]
rg -F -q 'Evidence output exceeded --max-tokens 31.' "$TMP_DIR/budget.err"

# Preserve a daemon passage's trailing newline without printing a second one.
"${budget_command[@]}" get /sample.md --heading Sample --format text >"$TMP_DIR/passage.out"
printf '# Sample\n' | cmp - "$TMP_DIR/passage.out"

VERSION_CHECKED_TEXT="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --format text --release-api-url "http://127.0.0.1:${release_port}/latest")"
printf '%s\n' "$VERSION_CHECKED_TEXT" | rg -F -q 'version: 9.8.7'
printf '%s\n' "$VERSION_CHECKED_TEXT" | rg -F -q 'latest: 9.9.9'
printf '%s\n' "$VERSION_CHECKED_TEXT" | rg -F -q 'updateAvailable: true'
printf '%s\n' "$VERSION_CHECKED_TEXT" | rg -F -q 'releaseCheck: checked'
printf '%s\n' "$VERSION_CHECKED_TEXT" | rg -F -q 'releaseURL: https://example.com/metabrain/releases/9.9.9'
VERSION_FAILED_TEXT="$(METABRAIN_VERSION=9.8.7 "${METABRAIN[@]}" version --format text --release-api-url "http://127.0.0.1:${release_port}/failed")"
printf '%s\n' "$VERSION_FAILED_TEXT" | rg -F -q 'releaseCheck: failed'
printf '%s\n' "$VERSION_FAILED_TEXT" | rg -F -q 'message: GitHub releases request returned HTTP 503.'

if "${METABRAIN[@]}" version --release-check-timeout 0 2>"$TMP_DIR/version-timeout.err"; then
    echo "Expected invalid release timeout to fail" >&2
    exit 1
fi
rg -F -q -- '--release-check-timeout must be greater than zero' "$TMP_DIR/version-timeout.err"

if "${METABRAIN[@]}" version --release-api-url relative/path 2>"$TMP_DIR/version-url.err"; then
    echo "Expected invalid release API URL to fail" >&2
    exit 1
fi
rg -F -q -- '--release-api-url must be an absolute URL' "$TMP_DIR/version-url.err"

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
rg -F -q 'Usage: mb init [--store <store>] [--server <server>] [--no-server] [--format <format>] [--empty]' "$TMP_DIR/init-invalid.err"

if "${METABRAIN[@]}" search query --limit 0 2>"$TMP_DIR/search-invalid.err"; then
    echo "Expected invalid search limit to fail" >&2
    exit 1
fi
rg -F -q 'Usage: mb search [<options>] [<query>]' "$TMP_DIR/search-invalid.err"
rg -F -q -- '--limit must be greater than zero' "$TMP_DIR/search-invalid.err"
"${METABRAIN[@]}" help search | rg -F -q -- '--format <format>'

if "${METABRAIN[@]}" tree --max-depth=-1 2>"$TMP_DIR/tree-invalid-depth.err"; then
    echo "Expected invalid tree max depth to fail" >&2
    exit 1
fi
rg -q -- '--max-depth must be zero or greater' "$TMP_DIR/tree-invalid-depth.err"

assert_missing_store() {
    local expected_store="$1"
    shift
    if "$@" >"$TMP_DIR/missing-store.out" 2>"$TMP_DIR/missing-store.err"; then
        echo "Expected command to fail for missing store: $expected_store" >&2
        exit 1
    fi
    rg -F -q "No metaBrain store found at $expected_store." "$TMP_DIR/missing-store.err"
    [[ ! -s "$TMP_DIR/missing-store.out" ]]
}

WORKSPACE="$TMP_DIR/discovery workspace"
WORKSPACE_CHILD="$WORKSPACE/sub/deeper"
WORKSPACE_CHILD_STORE="$WORKSPACE/sub/.metabrain/store.leveldb"
ENV_STORE="$TMP_DIR/env override/store.leveldb"
EXPLICIT_STORE="$TMP_DIR/explicit override/store.leveldb"
mkdir -p "$WORKSPACE_CHILD"
PHYSICAL_WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
(
    unset METABRAIN_STORE
    cd "$WORKSPACE_CHILD"
    for read_command in get list tree search recall dump versions; do
        assert_missing_store "$PHYSICAL_WORKSPACE/sub/deeper/.metabrain/store.leveldb" \
            "${METABRAIN[@]}" --no-server "$read_command" /needle
    done
    [[ ! -e "$WORKSPACE_CHILD/.metabrain" ]]
    assert_missing_store "$EXPLICIT_STORE" \
        "${METABRAIN[@]}" --no-server --store "$EXPLICIT_STORE" list
    [[ ! -e "$(dirname "$EXPLICIT_STORE")" ]]
    METABRAIN_STORE="$ENV_STORE" assert_missing_store "$ENV_STORE" \
        "${METABRAIN[@]}" --no-server list
    [[ ! -e "$(dirname "$ENV_STORE")" ]]

    cd "$WORKSPACE"
    "${METABRAIN[@]}" --no-server init >"$TMP_DIR/workspace-init.json"
    rg -F -q "\"storePath\":\"$PHYSICAL_WORKSPACE/.metabrain/store.leveldb\"" "$TMP_DIR/workspace-init.json"
    "${METABRAIN[@]}" --no-server put /needle 'workspace ancestor' >/dev/null
    cd "$WORKSPACE_CHILD"
    assert_get_json "$("${METABRAIN[@]}" --no-server get /needle)" /needle 'workspace ancestor' 1
    [[ ! -e "$WORKSPACE_CHILD/.metabrain" ]]

    "${METABRAIN[@]}" --no-server --store="$WORKSPACE_CHILD_STORE" put /needle 'nearest ancestor' >/dev/null
    assert_get_json "$("${METABRAIN[@]}" --no-server get /needle)" /needle 'nearest ancestor' 1
    "${METABRAIN[@]}" --no-server put /nearest 'added from child' >/dev/null
    assert_get_json "$("${METABRAIN[@]}" --no-server get --store "$WORKSPACE_CHILD_STORE" /nearest)" \
        /nearest 'added from child' 1
    [[ ! -e "$WORKSPACE_CHILD/.metabrain" ]]

    METABRAIN_STORE='../../env override/store.leveldb' \
        assert_missing_store "$PHYSICAL_WORKSPACE/env override/store.leveldb" "${METABRAIN[@]}" --no-server list
    METABRAIN_STORE="$ENV_STORE" "${METABRAIN[@]}" --no-server put /needle 'environment override' >/dev/null
    "${METABRAIN[@]}" --store "$EXPLICIT_STORE" --no-server put /needle 'explicit override' >/dev/null
    assert_get_json "$(METABRAIN_STORE="$ENV_STORE" "${METABRAIN[@]}" --no-server get /needle)" \
        /needle 'environment override' 1
    assert_get_json "$(METABRAIN_STORE="$ENV_STORE" "${METABRAIN[@]}" --store "$EXPLICIT_STORE" --no-server get /needle)" \
        /needle 'explicit override' 1
    assert_get_json "$(METABRAIN_STORE="$ENV_STORE" "${METABRAIN[@]}" --no-server get --store "$EXPLICIT_STORE" /needle)" \
        /needle 'explicit override' 1

    assert_missing_store "$PHYSICAL_WORKSPACE/missing-store/store.leveldb" \
        "${METABRAIN[@]}" --no-server --store ../../missing-store/store.leveldb get /needle
    [[ ! -e "$WORKSPACE/missing-store" ]]

    mkdir -p "$TMP_DIR/put-workspace/sub"
    cd "$TMP_DIR/put-workspace/sub"
    "${METABRAIN[@]}" --no-server put /first 'created by put' >/dev/null
    [[ -f .metabrain/store.leveldb/CURRENT ]]
    [[ ! -e ../.metabrain ]]
)

check_guarded_put() {
    local store="$1"
    shift
    local command=("$@" --store "$store")
    local result body_file="$TMP_DIR/guarded-put-body.txt"
    local error_file="$TMP_DIR/guarded-put.err"
    local original=(/guarded 'initial text' --title Retained --tag tagged --meta source=fixture --ref-path /other --keep-all)

    assert_missing_store "$store" "${command[@]}" put /guarded guarded --if-version 1
    assert_missing_store "$store" "${command[@]}" put /guarded guarded --body-only
    [[ ! -e "$(dirname "$store")" ]]

    result="$("${command[@]}" put "${original[@]}" --if-version 0)"
    assert_put_json "$result" /guarded created 1
    result="$("${command[@]}" put "${original[@]}" --if-version 0)"
    assert_put_json "$result" /guarded unchanged 1
    result="$("${command[@]}" put "${original[@]}")"
    assert_put_json "$result" /guarded unchanged 1

    if "${command[@]}" put /guarded 'different text' --if-version 0 2>"$error_file"; then
        echo "Expected a divergent create-only write to conflict" >&2
        exit 1
    fi
    rg -F -q 'expected version 0, found version 1' "$error_file"
    if "${command[@]}" put /guarded 'different text' --body-only --tag forbidden 2>"$error_file"; then
        echo "Expected body-only put to reject tag flags" >&2
        exit 1
    fi
    rg -F -q -- '--body-only preserves title, tags, metadata, references, and retention' "$error_file"

    printf 'new body from file' >"$body_file"
    result="$("${command[@]}" put /guarded --body-file "$body_file" --body-only --if-version 1)"
    assert_put_json "$result" /guarded updated 2
    result="$("${command[@]}" put /guarded --body-file "$body_file" --body-only --if-version 1)"
    assert_put_json "$result" /guarded unchanged 2
    result="$("${command[@]}" put /guarded 'new body from file' --body-only --format text)"
    printf '%s\n' "$result" | rg -q '^status: unchanged$'

    if "${command[@]}" put /guarded 'stale body' --body-only --if-version 1 2>"$error_file"; then
        echo "Expected a stale guarded write to conflict" >&2
        exit 1
    fi
    rg -F -q 'expected version 1, found version 2' "$error_file"

    result="$("${command[@]}" get /guarded)"
    assert_get_json "$result" /guarded 'new body from file' 2
    printf '%s\n' "$result" | rg -F -q '"title":"Retained"'
    printf '%s\n' "$result" | rg -F -q '"tags":["tagged"]'
    printf '%s\n' "$result" | rg -F -q '"metadata":{"source":"fixture"}'
    printf '%s\n' "$result" | rg -F -q '"references":[{"kind":"path","value":"/other"}]'

    result="$("${command[@]}" put /guarded 'replacement' --if-version 2)"
    assert_put_json "$result" /guarded updated 3
    result="$("${command[@]}" get /guarded)"
    printf '%s\n' "$result" | rg -F -q '"title":null'
    printf '%s\n' "$result" | rg -F -q '"tags":[]'
    printf '%s\n' "$result" | rg -F -q '"metadata":{}'
    printf '%s\n' "$result" | rg -F -q '"references":[]'
    assert_versions_jsonl "$("${command[@]}" versions /guarded)" /guarded 3
}

check_guarded_put "$TMP_DIR/guarded-direct/store.leveldb" "${METABRAIN[@]}" --no-server

check_project_operation() {
    local store="$1"
    shift
    local command=("$@" --store "$store")
    local operation="$TMP_DIR/project-operation.json" preview="$TMP_DIR/project-preview.json"
    local direct_preview="$TMP_DIR/project-direct-preview.json"
    local receipt="$TMP_DIR/project-receipt.json" retry="$TMP_DIR/project-retry.json"
    local output="$TMP_DIR/project-output.json" error="$TMP_DIR/project-operation.err"

    cat >"$operation" <<'JSON'
{"operationID":"c44983b2-46c5-44a7-9877-227ce5b412ca","project":{"rawValue":"/projects/demo"},"documents":[{"path":{"rawValue":"/projects/demo/source.md"},"body":"Source text","metadata":{},"references":[],"tags":[]},{"path":{"rawValue":"/projects/demo/decision.md"},"body":"[[source]]","metadata":{},"references":[],"tags":[]}]}
JSON
    "${METABRAIN[@]}" --store "$store" --no-server init --empty >/dev/null
    "${METABRAIN[@]}" operation --store "$store" --no-server inspect "$operation" --check-citations >"$direct_preview"
    "${command[@]}" operation inspect "$operation" --check-citations >"$preview"
    cmp "$direct_preview" "$preview"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["citationChecks"][0]["link"]["status"] == "resolved"' "$preview"
    if "${command[@]}" get /projects/demo/decision.md >"$output" 2>"$error"; then
        echo "Operation inspect wrote the decision before apply" >&2
        exit 1
    fi

    "${command[@]}" operation apply "$direct_preview" >"$receipt"
    "$@" operation apply "$preview" --store "$store" >"$retry"
    cmp "$receipt" "$retry"
    assert_get_json "$("${command[@]}" get /projects/demo/source.md)" /projects/demo/source.md 'Source text' 1
    assert_get_json "$("${command[@]}" get /projects/demo/decision.md)" /projects/demo/decision.md '[[source]]' 1

    python3 - "$operation" <<'PYOPERATION'
import json
from pathlib import Path
import sys

file = Path(sys.argv[1])
operation = json.loads(file.read_bytes())
operation["operationID"] = "f4f73f95-4c1c-441f-ac0d-59dd4af03f3d"
operation["documents"][0]["body"] = "Proposed update"
file.write_text(json.dumps(operation))
PYOPERATION
    "${command[@]}" operation inspect "$operation" >"$preview"
    "${command[@]}" put /projects/demo/decision.md 'Competing edit' >/dev/null
    if "${command[@]}" operation apply "$preview" >"$output" 2>"$error"; then
        echo "Expected a stale project operation preview to fail" >&2
        exit 1
    fi
    [[ ! -s "$output" && -s "$error" ]]
    assert_get_json "$("${command[@]}" get /projects/demo/source.md)" /projects/demo/source.md 'Source text' 1
}

check_project_operation "$TMP_DIR/operations-direct/store.leveldb" "${METABRAIN[@]}" --no-server
python3 Tests/MetaBrainCLITests/reference-validation.py "$TMP_DIR/references-direct/store.leveldb" "${METABRAIN[@]}" --no-server

check_wiki_preview() {
    local store="$1"
    shift
    local -a command=("$@" --store "$store")
    local board='{"nodes":[{"id":"item","type":"file","file":"item.md","x":0,"y":0,"width":10,"height":10}],"edges":[]}'
    local base=$'filters: \'file.hasTag("decision")\'\nviews:\n  - type: table\n    name: Decisions\n    order: [file.name, status]'
    local draft="$TMP_DIR/wiki-draft"
    local output="$TMP_DIR/wiki-preview.json"
    local errors="$TMP_DIR/wiki-preview.err"

    "${command[@]}" put /wiki/item.md '# Decision' --tag decision --meta status=accepted >/dev/null
    "${command[@]}" put /wiki-decoy/item.md '# Outside' --tag decision --meta status=decoy >/dev/null
    "${command[@]}" put /wiki/board.canvas "$board" >/dev/null
    "${command[@]}" put /wiki/view.base "$base" >/dev/null
    "${command[@]}" preview /wiki/board.canvas --project /wiki >"$output"
    python3 -c 'import json,sys; assert json.load(sys.stdin)["nodes"][0]["filePath"]["rawValue"] == "/wiki/item.md"' <"$output"
    "${command[@]}" preview /wiki/view.base --project /wiki >"$output"
    python3 -c 'import json,sys; assert json.load(sys.stdin)[0]["rows"] == [{"path":{"rawValue":"/wiki/item.md"},"cells":["item.md","accepted"]}]' <"$output"

    printf '%s\n' "$board" >"$draft"
    "${command[@]}" preview /wiki/draft.canvas --project /wiki --body-file "$draft" >"$output"
    "${command[@]}" put /wiki/draft.canvas/child.md '# A child is not the board' >/dev/null
    if "${command[@]}" preview /wiki/draft.canvas --project /wiki >"$output" 2>"$errors"; then
        echo "Preview accepted an unsaved draft with a descendant at its path" >&2
        exit 1
    fi
    rg -qi 'document.*not found' "$errors"

    if "${command[@]}" preview /wiki-decoy/board.canvas --project /wiki >"$output" 2>"$errors"; then
        echo "Preview accepted an out-of-project path" >&2
        exit 1
    fi
    rg -F -q 'strictly inside an explicit non-root --project' "$errors"
    if "${command[@]}" preview /wiki/item.md --project /wiki >"$output" 2>"$errors"; then
        echo "Preview accepted an unsupported extension" >&2
        exit 1
    fi
    rg -F -q 'requires a .canvas or .base document path' "$errors"
    printf '\377' >"$draft"
    if "${command[@]}" preview /wiki/board.canvas --project /wiki --body-file "$draft" >"$output" 2>"$errors"; then
        echo "Preview accepted an invalid UTF-8 draft" >&2
        exit 1
    fi
    rg -F -q 'Cannot read UTF-8 preview draft' "$errors"
    [[ ! -s "$output" ]]

    printf '%s\n' '{"nodes": [}' >"$draft"
    if "${command[@]}" preview /wiki/board.canvas --project /wiki --body-file "$draft" >"$output" 2>"$errors"; then
        echo "Preview accepted malformed Canvas JSON" >&2
        exit 1
    fi
    rg -F -q "Invalid Canvas JSON at '/wiki/board.canvas'" "$errors"
    [[ ! -s "$output" ]]
}

check_wiki_preview "$TMP_DIR/wiki-preview-direct/store.leveldb" "${METABRAIN[@]}" --no-server
python3 Tests/MetaBrainCLITests/source-capture.py "$TMP_DIR/capture-direct/store.leveldb" "${METABRAIN[@]}" --no-server
python3 Tests/MetaBrainCLITests/claim-evidence.py "$TMP_DIR/claims-direct/store.leveldb" "${METABRAIN[@]}" --no-server

GUIDED_STORE="$TMP_DIR/guided.leveldb"
"${METABRAIN[@]}" init --no-server --store "$GUIDED_STORE" >/dev/null
GUIDED_LIST="$("${METABRAIN[@]}" list --no-server --store "$GUIDED_STORE")"
assert_line_count "$GUIDED_LIST" 1
printf '%s\n' "$GUIDED_LIST" | rg -F -q '"path":"/AGENTS.md"'
"${METABRAIN[@]}" get --no-server --store "$GUIDED_STORE" /AGENTS.md --format text | rg -F -q 'Working with metaBrain'
"${METABRAIN[@]}" get --no-server --store "$GUIDED_STORE" /AGENTS.md --format text | rg -F -q 'mb recall'

IMPLICIT_STORE="$TMP_DIR/implicit.leveldb"
"${METABRAIN[@]}" put --no-server --store "$IMPLICIT_STORE" /first.md "First note" >/dev/null
"${METABRAIN[@]}" init --no-server --store "$IMPLICIT_STORE" >/dev/null
IMPLICIT_LIST="$("${METABRAIN[@]}" list --no-server --store "$IMPLICIT_STORE")"
assert_line_count "$IMPLICIT_LIST" 1
printf '%s\n' "$IMPLICIT_LIST" | rg -F -q '"path":"/first.md"'

check_recall() {
    local store="$1"
    shift
    local command=("$@" --store "$store")
    local output="$TMP_DIR/recall.out" original="$TMP_DIR/recall-original.json"
    local historical="$TMP_DIR/recall-historical.json" body_file="$TMP_DIR/recall-body.txt"
    local body='A “café” corpus recall note cites evidence and contains a slash / here.'
    local citations="$TMP_DIR/recall-citations.json"
    local selected_id selected_version budget

    printf '%s\n' "$body" >"$body_file"
    "${command[@]}" put /cases/first --body-file "$body_file" --keep-all \
        --title 'First note' --tag recall --meta state=current --ref-url https://example.com/evidence >/dev/null
    "${command[@]}" put /cases/second 'Another corpus recall note.' --tag recall --meta state=current >/dev/null
    "${command[@]}" put /cases/stale 'Corpus recall stale.' --tag recall --meta state=old >/dev/null
    "${command[@]}" put /cases-other/outside 'Corpus recall outside.' --tag recall --meta state=current >/dev/null

    "${command[@]}" recall 'corpus recall' --tag RECALL --meta STATE=Current --path-prefix /cases \
        --limit 2 --max-bytes 2048 >"$citations"
    python3 - "$citations" <<'PYRECALL'
import json
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
assert len(data) <= 2048 and data.endswith(b"\n") and data.count(b"\n") == 1, data
hits = json.loads(data)
assert len(hits) == 2 and {hit["path"] for hit in hits} == {"/cases/first", "/cases/second"}, hits
assert all(hit["version"] == 1 and hit["passages"] for hit in hits), hits
first = next(hit for hit in hits if hit["path"] == "/cases/first")
assert first["title"] == "First note" and "https://example.com/evidence" in first["sources"], first
assert any("café" in passage["text"] for passage in first["passages"]), first
PYRECALL

    "${command[@]}" recall 'corpus recall' --path-prefix /cases --limit 1 >"$output"
    python3 - "$output" <<'PYRECALL'
import json
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
assert len(data) <= 8192 and len(json.loads(data)) == 1, data
PYRECALL

    for budget in 3 64 192 384 8192; do
        "${command[@]}" recall 'corpus recall' --max-bytes "$budget" >"$output"
        python3 - "$output" "$budget" <<'PYRECALL'
import json
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
assert len(data) <= int(sys.argv[2]) and data.endswith(b"\n"), data
assert isinstance(json.loads(data), list), data
if int(sys.argv[2]) == 3:
    assert data == b"[]\n", data
PYRECALL
    done

    for budget in 2 1048577; do
        if "${command[@]}" recall corpus --max-bytes "$budget" >"$output" 2>"$TMP_DIR/recall.err"; then
            echo "Expected recall to reject byte budget $budget" >&2
            exit 1
        fi
        [[ ! -s "$output" ]]
        rg -F -q -- '--max-bytes must be between 3 and 1048576' "$TMP_DIR/recall.err"
    done

    read -r selected_id selected_version < <(python3 - "$citations" <<'PYRECALL'
import json
from pathlib import Path
import sys

first = next(hit for hit in json.loads(Path(sys.argv[1]).read_bytes()) if hit["path"] == "/cases/first")
print(first["documentID"], first["version"])
PYRECALL
    )
    "${command[@]}" get /cases/first --version "$selected_version" >"$original"
    "${command[@]}" put /cases/first 'Revised document.' --body-only --if-version "$selected_version" >/dev/null
    "${command[@]}" get --id "$selected_id" --version "$selected_version" >"$historical"
    cmp "$original" "$historical"
    python3 - "$citations" "$historical" <<'PYRECALL'
import json
from pathlib import Path
import sys

historical = json.loads(Path(sys.argv[2]).read_bytes())
first = next(hit for hit in json.loads(Path(sys.argv[1]).read_bytes()) if hit["documentID"] == historical["documentID"])
assert first["version"] == historical["version"]
assert all(historical["body"][passage["start"]:passage["end"]] == passage["text"] for passage in first["passages"])
PYRECALL
    assert_get_json "$("${command[@]}" get /cases/first)" /cases/first 'Revised document.' 2
    if "${command[@]}" get --id "$selected_id" --version 3 >"$output" 2>"$TMP_DIR/recall.err"; then
        echo "Expected an unretained version lookup to fail" >&2
        exit 1
    fi
    [[ ! -s "$output" ]]
    rg -F -q "$selected_id" "$TMP_DIR/recall.err"
}

check_recall "$TMP_DIR/recall-direct/store.leveldb" "${METABRAIN[@]}" --no-server
python3 Tests/MetaBrainCLITests/citation-search.py "$TMP_DIR/citations-direct/store.leveldb" "${METABRAIN[@]}" --no-server

INIT_DEFAULT_JSON="$("${METABRAIN[@]}" init --store "$STORE" --empty)"
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
[[ "$("${METABRAIN[@]}" list --store "$STORE" --format json)" == '[]' ]]
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
PUT_JSON_BODY_JSON="$("${METABRAIN[@]}" put --store "$STORE" /notes/config '{"enabled":true}')"
assert_put_json "$PUT_JSON_BODY_JSON" /notes/config created 1
"${METABRAIN[@]}" dump --store "$STORE" /notes/config --output-dir "$DUMP_OUTPUT_DIR" >"$TMP_DIR/dump-json-body-files.jsonl"
JSON_DUMP_FILE="$(find "$DUMP_OUTPUT_DIR" -type f -name 'config__*__v1__*.json' | head -n 1)"
if [[ -z "$JSON_DUMP_FILE" || ! -f "$JSON_DUMP_FILE" ]]; then
    echo "Expected extensionless JSON body dump to create a .json file" >&2
    exit 1
fi
rg -F -q '{"enabled":true}' "$JSON_DUMP_FILE"
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
MOVE_JSONL_TARGET_JSON="$("${METABRAIN[@]}" put --store "$STORE" /move/jsonl-source 'jsonl relocated body')"
assert_put_json "$MOVE_JSONL_TARGET_JSON" /move/jsonl-source created 1
MOVE_JSONL_OUTPUT="$("${METABRAIN[@]}" move --store "$STORE" /move/jsonl-source /move/jsonl-target --format jsonl)"
assert_move_json "$MOVE_JSONL_OUTPUT" /move/jsonl-source /move/jsonl-target moved 2
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
if "${METABRAIN[@]}" move --store "$STORE" /move/only-one-path 2>"$TMP_DIR/move-one-path.err"; then
    echo "Expected move with one path and no ID to fail" >&2
    exit 1
fi
rg -F -q 'Provide a source path and a destination path, or use --id with one destination path.' "$TMP_DIR/move-one-path.err"
if "${METABRAIN[@]}" move --store "$STORE" --id "$MOVE_SOURCE_ID" /move/a /move/b 2>"$TMP_DIR/move-id-two-paths.err"; then
    echo "Expected move with ID and two paths to fail" >&2
    exit 1
fi
rg -F -q 'Use --id with exactly one destination path.' "$TMP_DIR/move-id-two-paths.err"

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
SEARCH_LINKED_JSONL="$("${METABRAIN[@]}" search --store "$STORE" --path-prefix /refs source --include-linked-documents)"
assert_search_jsonl_result "$SEARCH_LINKED_JSONL" /refs/source source
printf '%s\n' "$SEARCH_LINKED_JSONL" | rg -F -q '"linkedDocuments":[{"kind":"documentID","value":"'"$TARGET_ID"'"}]'
"${METABRAIN[@]}" search --store "$STORE" --path-prefix /refs source --include-linked-documents --format text | rg -q '^linked: [0-9a-f-]+$'
SEARCH_BACKLINKS_JSONL="$("${METABRAIN[@]}" search --store "$STORE" --path-prefix /refs target --include-backlinks)"
assert_search_jsonl_result "$SEARCH_BACKLINKS_JSONL" /refs/target target
printf '%s\n' "$SEARCH_BACKLINKS_JSONL" | rg -q '"backlinks":\[\{"kind":"documentID","value":"[0-9a-f-]+"\}\]'
"${METABRAIN[@]}" search --store "$STORE" --path-prefix /refs target --include-backlinks --format text | rg -q '^backlinks: [0-9a-f-]+$'

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
rg -F -q 'Usage: mb get [<options>] [<path>]' "$TMP_DIR/double-reference.err"

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
rg -F -q 'Usage: mb versions [--store <store>] [--server <server>] [--no-server] [--id <id>] [--path <path>] [<path>] [--format <format>]' "$TMP_DIR/missing-version-reference.err"

if "${METABRAIN[@]}" delete --store "$STORE" 2>"$TMP_DIR/missing-delete-reference.err"; then
    echo "Expected missing delete reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-delete-reference.err"
rg -F -q 'Usage: mb delete [--store <store>] [--server <server>] [--no-server] [--id <id>] [--path <path>] [<path>] [--format <format>]' "$TMP_DIR/missing-delete-reference.err"

if "${METABRAIN[@]}" remove-version --store "$STORE" --sequence 1 2>"$TMP_DIR/missing-remove-version-reference.err"; then
    echo "Expected missing remove-version reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-remove-version-reference.err"
rg -F -q 'Usage: mb remove-version [--store <store>] [--server <server>] [--no-server] [--id <id>] [--path <path>] [<path>] [--format <format>] --sequence <sequence>' "$TMP_DIR/missing-remove-version-reference.err"

if "${METABRAIN[@]}" remove-version --store "$STORE" /versions/remove-json 2>"$TMP_DIR/missing-remove-version-sequence.err"; then
    echo "Expected missing remove-version sequence to fail" >&2
    exit 1
fi
rg -q 'Missing expected (argument|option).*--sequence <sequence>' "$TMP_DIR/missing-remove-version-sequence.err"
rg -F -q 'Usage: mb remove-version [--store <store>] [--server <server>] [--no-server] [--id <id>] [--path <path>] [<path>] [--format <format>] --sequence <sequence>' "$TMP_DIR/missing-remove-version-sequence.err"

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
rg -F -q 'Usage: mb prune [--store <store>] [--server <server>] [--no-server] [--id <id>] [--path <path>] [<path>] [--keep-all] [--keep-last <keep-last>] [--keep-within <keep-within>] [--format <format>]' "$TMP_DIR/missing-retention.err"

if "${METABRAIN[@]}" get --store "$STORE" 2>"$TMP_DIR/missing-reference.err"; then
    echo "Expected missing reference options to fail" >&2
    exit 1
fi
rg -q 'Provide exactly one of --id, --path, or a positional path' "$TMP_DIR/missing-reference.err"
rg -F -q 'Usage: mb get [<options>] [<path>]' "$TMP_DIR/missing-reference.err"

SERVER_STORE="$TMP_DIR/server-store.leveldb"
SERVER_SOCKET="$TMP_DIR/mbd.sock"
"${METABRAIN_DAEMON[@]}" serve --store "$SERVER_STORE" --socket "$SERVER_SOCKET" --log-level error >"$TMP_DIR/mbd.out" 2>"$TMP_DIR/mbd.err" &
daemon_server_pid="$!"
for _ in $(seq 1 400); do
    if [[ -S "$SERVER_SOCKET" ]]; then
        break
    fi
    if ! kill -0 "$daemon_server_pid" 2>/dev/null; then
        echo "Daemon exited early." >&2
        cat "$TMP_DIR/mbd.err" >&2
        exit 1
    fi
    sleep 0.05
done
if [[ ! -S "$SERVER_SOCKET" ]]; then
    echo "Daemon did not create socket." >&2
    cat "$TMP_DIR/mbd.err" >&2
    exit 1
fi

server_mb() {
    local command="$1"
    shift
    "${METABRAIN[@]}" "$command" --server "$SERVER_SOCKET" --store "$SERVER_STORE" "$@"
}

(
    unset METABRAIN_STORE
    cd "$WORKSPACE_CHILD"
    SERVER_MISSING_STORE="$TMP_DIR/server-missing/store.leveldb"
    for read_command in get list tree search recall dump versions; do
        assert_missing_store "$SERVER_MISSING_STORE" \
            "${METABRAIN[@]}" --server "$SERVER_SOCKET" --store="$SERVER_MISSING_STORE" "$read_command" /needle
    done
    [[ ! -e "$(dirname "$SERVER_MISSING_STORE")" ]]
    assert_get_json "$("${METABRAIN[@]}" --server="$SERVER_SOCKET" get /needle)" /needle 'nearest ancestor' 1
    assert_get_json "$("${METABRAIN[@]}" --store "$PHYSICAL_WORKSPACE/sub/.metabrain/store.leveldb" \
        --server "$SERVER_SOCKET" get /needle)" /needle 'nearest ancestor' 1
    assert_get_json "$(METABRAIN_STORE="$ENV_STORE" "${METABRAIN[@]}" --server "$SERVER_SOCKET" get /needle)" \
        /needle 'environment override' 1
    assert_get_json "$(METABRAIN_STORE="$ENV_STORE" "${METABRAIN[@]}" --store "$EXPLICIT_STORE" --server "$SERVER_SOCKET" get /needle)" \
        /needle 'explicit override' 1
    [[ ! -e "$WORKSPACE_CHILD/.metabrain" ]]
)

check_guarded_put "$TMP_DIR/guarded-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"
check_project_operation "$TMP_DIR/operations-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"
python3 Tests/MetaBrainCLITests/reference-validation.py "$TMP_DIR/references-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"
check_wiki_preview "$TMP_DIR/wiki-preview-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"
python3 Tests/MetaBrainCLITests/source-capture.py "$TMP_DIR/capture-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"
python3 Tests/MetaBrainCLITests/claim-evidence.py "$TMP_DIR/claims-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"

check_recall "$TMP_DIR/recall-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"
python3 Tests/MetaBrainCLITests/citation-search.py "$TMP_DIR/citations-daemon/store.leveldb" "${METABRAIN[@]}" --server "$SERVER_SOCKET"
python3 Tests/MetaBrainCLITests/citation-lint.py "$TMP_DIR/lint/store.leveldb" "$SERVER_SOCKET" "${METABRAIN[@]}"

SERVER_INIT_JSON="$(server_mb init)"
SERVER_EXPECTED_INIT_JSON="{\"operation\":\"init\",\"status\":\"initialized\",\"storePath\":\"$SERVER_STORE\"}"
if [[ "$SERVER_INIT_JSON" != "$SERVER_EXPECTED_INIT_JSON" ]]; then
    echo "Expected daemon init JSON output, got: $SERVER_INIT_JSON" >&2
    exit 1
fi

SERVER_FIRST_STORE="$TMP_DIR/server-first-store.leveldb"
SERVER_SECOND_STORE="$TMP_DIR/server-second-store.leveldb"
SERVER_FIRST_INIT_JSON="$("${METABRAIN[@]}" init --server "$SERVER_SOCKET" --store "$SERVER_FIRST_STORE")"
SERVER_SECOND_INIT_JSON="$("${METABRAIN[@]}" init --empty --server "$SERVER_SOCKET" --store "$SERVER_SECOND_STORE")"
if [[ "$SERVER_FIRST_INIT_JSON" != "{\"operation\":\"init\",\"status\":\"initialized\",\"storePath\":\"$SERVER_FIRST_STORE\"}" ]]; then
    echo "Expected first daemon store init JSON output, got: $SERVER_FIRST_INIT_JSON" >&2
    exit 1
fi
if [[ "$SERVER_SECOND_INIT_JSON" != "{\"operation\":\"init\",\"status\":\"initialized\",\"storePath\":\"$SERVER_SECOND_STORE\"}" ]]; then
    echo "Expected second daemon store init JSON output, got: $SERVER_SECOND_INIT_JSON" >&2
    exit 1
fi
"${METABRAIN[@]}" get /AGENTS.md --server "$SERVER_SOCKET" --store "$SERVER_FIRST_STORE" --format text | rg -F -q 'Working with metaBrain'
"${METABRAIN[@]}" init --server "$SERVER_SOCKET" --store "$SERVER_SECOND_STORE" >/dev/null
[[ "$("${METABRAIN[@]}" list --server "$SERVER_SOCKET" --store "$SERVER_SECOND_STORE" --format json)" == '[]' ]]
SERVER_FIRST_PUT_JSON="$("${METABRAIN[@]}" put /daemon/shared 'first daemon store' --server "$SERVER_SOCKET" --store "$SERVER_FIRST_STORE")"
SERVER_SECOND_PUT_JSON="$("${METABRAIN[@]}" put /daemon/shared 'second daemon store' --server "$SERVER_SOCKET" --store "$SERVER_SECOND_STORE")"
assert_put_json "$SERVER_FIRST_PUT_JSON" /daemon/shared created 1
assert_put_json "$SERVER_SECOND_PUT_JSON" /daemon/shared created 1
SERVER_FIRST_GET_JSON="$("${METABRAIN[@]}" get /daemon/shared --server "$SERVER_SOCKET" --store "$SERVER_FIRST_STORE")"
SERVER_SECOND_GET_JSON="$("${METABRAIN[@]}" get /daemon/shared --server "$SERVER_SOCKET" --store "$SERVER_SECOND_STORE")"
assert_get_json "$SERVER_FIRST_GET_JSON" /daemon/shared 'first daemon store' 1
assert_get_json "$SERVER_SECOND_GET_JSON" /daemon/shared 'second daemon store' 1

SERVER_VERSION_JSON="$(METABRAIN_VERSION=4.5.6 "${METABRAIN[@]}" --server "$SERVER_SOCKET" version --no-release-check)"
if ! printf '%s\n' "$SERVER_VERSION_JSON" | rg -F -q '"currentTag":"4.5.6"'; then
    echo "Expected CLI version in daemon version JSON output, got: $SERVER_VERSION_JSON" >&2
    exit 1
fi
printf '%s\n' "$SERVER_VERSION_JSON" | rg -F -q "\"endpoint\":\"$SERVER_SOCKET\""
printf '%s\n' "$SERVER_VERSION_JSON" | rg -F -q '"reachable":true'
if ! printf '%s\n' "$SERVER_VERSION_JSON" | rg -F -q '"server":{"currentTag":"'; then
    echo "Expected server version in daemon version JSON output, got: $SERVER_VERSION_JSON" >&2
    exit 1
fi

SERVER_PUT_TODAY_JSON="$(server_mb put /daemon/today 'daemon alpha memory' --title Daemon --tag daemon --meta kind=server --keep-all)"
assert_put_json "$SERVER_PUT_TODAY_JSON" /daemon/today created 1
SERVER_GET_TODAY_JSON="$(server_mb get /daemon/today)"
assert_get_json "$SERVER_GET_TODAY_JSON" /daemon/today 'daemon alpha memory' 1
printf '%s\n' "$SERVER_GET_TODAY_JSON" | rg -F -q '"title":"Daemon"'
printf '%s\n' "$SERVER_GET_TODAY_JSON" | rg -F -q '"tags":["daemon"]'
printf '%s\n' "$SERVER_GET_TODAY_JSON" | rg -F -q '"metadata":{"kind":"server"}'
SERVER_TODAY_ID="$(printf '%s\n' "$SERVER_GET_TODAY_JSON" | sed -E 's/.*"documentID":"([^"]+)".*/\1/')"

SERVER_BODY_FILE="$TMP_DIR/server-body.txt"
printf 'daemon body file memory\n' >"$SERVER_BODY_FILE"
SERVER_PUT_FILE_JSON="$(server_mb put /daemon/file --body-file "$SERVER_BODY_FILE" --ref-path /daemon/today --ref-url https://example.com/server-ref)"
assert_put_json "$SERVER_PUT_FILE_JSON" /daemon/file created 1

SERVER_PATCHABLE_JSON="$(server_mb put /daemon/patchable 'old daemon patch memory' --tag patch --keep-all)"
assert_put_json "$SERVER_PATCHABLE_JSON" /daemon/patchable created 1
SERVER_PATCH_FILE="$TMP_DIR/server.patch"
cat >"$SERVER_PATCH_FILE" <<'PATCH'
@@ -1 +1 @@
-old daemon patch memory
\ No newline at end of file
+fresh daemon patch memory
\ No newline at end of file
PATCH
SERVER_PATCH_CHECK_JSON="$(server_mb patch /daemon/patchable --patch-file "$SERVER_PATCH_FILE" --check)"
assert_patch_check_json "$SERVER_PATCH_CHECK_JSON"
SERVER_PATCH_WRITE_JSON="$(server_mb patch /daemon/patchable --patch-file "$SERVER_PATCH_FILE" --keep-last 2)"
assert_patch_write_json "$SERVER_PATCH_WRITE_JSON" /daemon/patchable 2

SERVER_LIST_JSONL="$(server_mb list /daemon)"
printf '%s\n' "$SERVER_LIST_JSONL" | rg -F -q '"path":"/daemon/today"'
SERVER_TREE_JSONL="$(server_mb tree /daemon --max-depth 1)"
printf '%s\n' "$SERVER_TREE_JSONL" | rg -F -q '"kind":"root","name":"daemon","path":"/daemon"'
printf '%s\n' "$SERVER_TREE_JSONL" | rg -F -q '"path":"/daemon/patchable"'
SERVER_SEARCH_JSONL="$(server_mb search fresh --tag patch)"
assert_search_jsonl_result "$SERVER_SEARCH_JSONL" /daemon/patchable fresh

SERVER_TODAY_UPDATE_JSON="$(server_mb put /daemon/today 'daemon alpha updated memory' --keep-all)"
assert_put_json "$SERVER_TODAY_UPDATE_JSON" /daemon/today updated 2
SERVER_VERSIONS_JSONL="$(server_mb versions --id "$SERVER_TODAY_ID")"
assert_versions_jsonl "$SERVER_VERSIONS_JSONL" /daemon/today 2
SERVER_DUMP_DIR="$TMP_DIR/server-dump-files"
server_mb dump /daemon/today --versions --output-dir "$SERVER_DUMP_DIR" >"$TMP_DIR/server-dump.jsonl"
rg -F -q '"fileSystemPath":"' "$TMP_DIR/server-dump.jsonl"
SERVER_DUMP_FILE="$(find "$SERVER_DUMP_DIR" -type f -name 'today__*__v2__*.md' | head -n 1)"
if [[ -z "$SERVER_DUMP_FILE" || ! -f "$SERVER_DUMP_FILE" ]]; then
    echo "Expected daemon dump --output-dir to create a versioned copy" >&2
    exit 1
fi
rg -F -q 'daemon alpha updated memory' "$SERVER_DUMP_FILE"

SERVER_MOVE_JSON="$(server_mb move /daemon/file /daemon/archive/file)"
assert_move_json "$SERVER_MOVE_JSON" /daemon/file /daemon/archive/file moved 2
SERVER_PRUNE_JSON="$(server_mb prune /daemon/today --keep-last 1)"
assert_prune_json "$SERVER_PRUNE_JSON" 1 1
SERVER_DELETE_JSON="$(server_mb delete /daemon/archive/file --format json)"
assert_delete_json "$SERVER_DELETE_JSON" /daemon/archive/file true
if server_mb get /daemon/archive/file 2>"$TMP_DIR/server-get-deleted.err"; then
    echo "Expected daemon deleted document get to fail" >&2
    exit 1
fi
rg -F -q 'server returned HTTP 404 document_not_found' "$TMP_DIR/server-get-deleted.err"

server_mb put /daemon/remove-version 'remove daemon v1' --keep-all --format text | rg -q '^version: 1$'
server_mb put /daemon/remove-version 'remove daemon v2' --keep-all --format text | rg -q '^version: 2$'
SERVER_REMOVE_VERSION_JSON="$(server_mb remove-version /daemon/remove-version --sequence 1 --format json)"
assert_remove_version_json "$SERVER_REMOVE_VERSION_JSON" /daemon/remove-version true 1

kill "$daemon_server_pid" 2>/dev/null || true
wait "$daemon_server_pid" 2>/dev/null || true
daemon_server_pid=""

AUTO_SERVER_STORE="$TMP_DIR/auto-server-store.leveldb"
auto_listen_options=(--host 127.0.0.1)
if [[ "$AUTO_EXPECTED_PORT" == "0" ]]; then
    auto_listen_options+=(--port 0)
fi
METABRAIN_VERSION=6.7.8 "${METABRAIN_DAEMON[@]}" serve --store "$AUTO_SERVER_STORE" "${auto_listen_options[@]}" --log-level error >"$TMP_DIR/mbd-auto.out" 2>"$TMP_DIR/mbd-auto.err" &
daemon_server_pid="$!"
AUTO_SERVER_PORT=""
for _ in $(seq 1 400); do
    if [[ -s "$TMP_DIR/mbd-auto.out" ]]; then
        AUTO_SERVER_PORT="$(sed -n 's/^mbd serving on loopback http 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$TMP_DIR/mbd-auto.out" | head -n 1)"
        if [[ -n "$AUTO_SERVER_PORT" ]]; then
            break
        fi
    fi
    if ! kill -0 "$daemon_server_pid" 2>/dev/null; then
        echo "Auto daemon exited early." >&2
        cat "$TMP_DIR/mbd-auto.err" >&2
        exit 1
    fi
    sleep 0.05
done
if [[ "$AUTO_EXPECTED_PORT" == "0" && -n "$AUTO_SERVER_PORT" && "$AUTO_SERVER_PORT" != "0" ]]; then
    export METABRAIN_COVERAGE_LOOPBACK_PORT="$AUTO_SERVER_PORT"
    AUTO_EXPECTED_PORT="$AUTO_SERVER_PORT"
fi
if [[ "$AUTO_SERVER_PORT" != "$AUTO_EXPECTED_PORT" || "$AUTO_SERVER_PORT" == "0" ]]; then
    echo "Expected auto daemon to use a bound port (requested $AUTO_EXPECTED_PORT), got: ${AUTO_SERVER_PORT:-<none>}" >&2
    cat "$TMP_DIR/mbd-auto.out" >&2 || true
    cat "$TMP_DIR/mbd-auto.err" >&2 || true
    exit 1
fi

AUTO_SELECTED_STORE="$TMP_DIR/auto-selected-store.leveldb"
AUTO_INIT_JSON="$("${METABRAIN[@]}" --server auto init --store "$AUTO_SELECTED_STORE")"
AUTO_EXPECTED_INIT_JSON="{\"operation\":\"init\",\"status\":\"initialized\",\"storePath\":\"$AUTO_SELECTED_STORE\"}"
if [[ "$AUTO_INIT_JSON" != "$AUTO_EXPECTED_INIT_JSON" ]]; then
    echo "Expected auto daemon init JSON output, got: $AUTO_INIT_JSON" >&2
    exit 1
fi
AUTO_VERSION_JSON="$(METABRAIN_VERSION=4.5.6 "${METABRAIN[@]}" version --no-release-check)"
printf '%s\n' "$AUTO_VERSION_JSON" | rg -F -q '"currentTag":"4.5.6"'
printf '%s\n' "$AUTO_VERSION_JSON" | rg -F -q '"server":{"currentTag":"6.7.8","endpoint":"http://127.0.0.1:'"$AUTO_EXPECTED_PORT"'","reachable":true}'
AUTO_VERSION_TEXT="$(METABRAIN_VERSION=4.5.6 "${METABRAIN[@]}" version --format text --no-release-check)"
printf '%s\n' "$AUTO_VERSION_TEXT" | rg -F -x -q 'serverVersion: 6.7.8'
AUTO_PUT_JSON="$("${METABRAIN[@]}" put --store "$AUTO_SELECTED_STORE" /auto/today 'auto daemon memory' --tag auto)"
assert_put_json "$AUTO_PUT_JSON" /auto/today created 1
AUTO_GET_JSON="$("${METABRAIN[@]}" get --store "$AUTO_SELECTED_STORE" /auto/today)"
assert_get_json "$AUTO_GET_JSON" /auto/today 'auto daemon memory' 1
printf '%s\n' "$AUTO_GET_JSON" | rg -F -q '"tags":["auto"]'
if [[ -e "$AUTO_SERVER_STORE" ]]; then
    echo "Expected daemon-backed CLI commands to use the selected store, not daemon default: $AUTO_SERVER_STORE" >&2
    exit 1
fi

NO_SERVER_STORE="$TMP_DIR/no-server-store.leveldb"
NO_SERVER_INIT_JSON="$("${METABRAIN[@]}" --no-server init --store "$NO_SERVER_STORE")"
NO_SERVER_EXPECTED_INIT_JSON="{\"operation\":\"init\",\"status\":\"initialized\",\"storePath\":\"$NO_SERVER_STORE\"}"
if [[ "$NO_SERVER_INIT_JSON" != "$NO_SERVER_EXPECTED_INIT_JSON" ]]; then
    echo "Expected --no-server init JSON output, got: $NO_SERVER_INIT_JSON" >&2
    exit 1
fi

kill "$daemon_server_pid" 2>/dev/null || true
wait "$daemon_server_pid" 2>/dev/null || true
daemon_server_pid=""

python3 Benchmarks/test_citation_performance.py \
    --mb "${METABRAIN_BIN:-$ROOT_DIR/.build/debug/mb}" \
    --mbd "${METABRAIN_DAEMON_BIN:-$ROOT_DIR/.build/debug/mbd}" \
    --tmpdir "$TMP_DIR"
