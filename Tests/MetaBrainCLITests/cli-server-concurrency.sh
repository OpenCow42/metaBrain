#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_PARENT="${METABRAIN_TMPDIR:-}"
if [[ -z "$TMP_PARENT" ]]; then
    if [[ -d /private/tmp ]]; then
        TMP_PARENT=/private/tmp
    else
        TMP_PARENT=/tmp
    fi
fi

TMP_DIR="$(mktemp -d "$TMP_PARENT/metabrain-concurrency.XXXXXX")"
server_pid=""

cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

if [[ -n "${METABRAIN_BIN:-}" ]]; then
    MB_BIN="$METABRAIN_BIN"
elif [[ -x "$ROOT_DIR/.build/debug/mb" ]]; then
    MB_BIN="$ROOT_DIR/.build/debug/mb"
else
    echo "Unable to locate mb. Set METABRAIN_BIN or run swift build first." >&2
    exit 1
fi

if [[ -n "${METABRAIN_DAEMON_BIN:-}" ]]; then
    MBD_BIN="$METABRAIN_DAEMON_BIN"
elif [[ -x "$ROOT_DIR/.build/debug/mbd" ]]; then
    MBD_BIN="$ROOT_DIR/.build/debug/mbd"
else
    echo "Unable to locate mbd. Set METABRAIN_DAEMON_BIN or run swift build first." >&2
    exit 1
fi

STORE="$TMP_DIR/server-store.leveldb"
SERVER_ENDPOINT=""
SEED_COUNT="${METABRAIN_CONCURRENCY_SEEDS:-8}"
WRITE_COUNT="${METABRAIN_CONCURRENCY_WRITES:-16}"
READ_COUNT="${METABRAIN_CONCURRENCY_READS:-32}"
SEARCH_COUNT="${METABRAIN_CONCURRENCY_SEARCHES:-8}"

start_server() {
    local stdout="$TMP_DIR/mbd.out"
    local stderr="$TMP_DIR/mbd.err"

    "$MBD_BIN" serve \
        --store "$STORE" \
        --host 127.0.0.1 \
        --port 0 \
        --maximum-concurrent-requests 32 \
        --maximum-queued-requests 128 \
        --log-level error \
        >"$stdout" 2>"$stderr" &
    server_pid="$!"

    local port=""
    for _ in $(seq 1 400); do
        if [[ -s "$stdout" ]]; then
            port="$(sed -n 's/^mbd serving on loopback http 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$stdout" | head -n 1)"
            if [[ -n "$port" ]]; then
                SERVER_ENDPOINT="http://127.0.0.1:$port"
                return
            fi
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo "mbd serve exited before reporting a port." >&2
            cat "$stdout" >&2 || true
            cat "$stderr" >&2 || true
            exit 1
        fi
        sleep 0.05
    done

    echo "mbd serve did not report a port." >&2
    cat "$stdout" >&2 || true
    cat "$stderr" >&2 || true
    exit 1
}

assert_get_body() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$("$MB_BIN" --server "$SERVER_ENDPOINT" get "$path" --format json)"
    printf '%s\n' "$actual" | rg -F -q '"path":"'"$path"'"'
    printf '%s\n' "$actual" | rg -F -q '"body":"'"$expected"'"'
}

labels=()
pids=()

run_bg() {
    local label="$1"
    shift
    (
        "$@"
    ) >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err" &
    labels+=("$label")
    pids+=("$!")
}

wait_for_workload() {
    local failures=0

    for index in "${!pids[@]}"; do
        local pid="${pids[$index]}"
        local label="${labels[$index]}"

        if ! wait "$pid"; then
            failures=$((failures + 1))
            echo "Concurrent CLI operation failed: $label" >&2
            cat "$TMP_DIR/$label.out" >&2 || true
            cat "$TMP_DIR/$label.err" >&2 || true
        fi
    done

    if [[ "$failures" -ne 0 ]]; then
        echo "$failures concurrent CLI operation(s) failed." >&2
        exit 1
    fi
}

start_server
"$MB_BIN" --server "$SERVER_ENDPOINT" init >/dev/null

for i in $(seq 1 "$SEED_COUNT"); do
    "$MB_BIN" --server "$SERVER_ENDPOINT" put \
        "/concurrent/seed-$i" \
        "seed body $i concurrent-token" \
        --tag concurrent \
        --meta kind=seed \
        --keep-all \
        --format json \
        >/dev/null
done

for i in $(seq 1 "$READ_COUNT"); do
    doc=$(( (i - 1) % SEED_COUNT + 1 ))
    run_bg "read-$i" \
        "$MB_BIN" --server "$SERVER_ENDPOINT" get "/concurrent/seed-$doc" --format json
done

for i in $(seq 1 "$SEARCH_COUNT"); do
    run_bg "search-$i" \
        "$MB_BIN" --server "$SERVER_ENDPOINT" search concurrent-token --path-prefix /concurrent --limit 5 --format jsonl
done

for i in $(seq 1 "$WRITE_COUNT"); do
    run_bg "write-$i" \
        "$MB_BIN" --server "$SERVER_ENDPOINT" put \
        "/concurrent/write-$i" \
        "write body $i concurrent-token" \
        --tag concurrent \
        --meta kind=write \
        --format json
done

for i in $(seq 1 "$SEED_COUNT"); do
    run_bg "update-$i" \
        "$MB_BIN" --server "$SERVER_ENDPOINT" put \
        "/concurrent/seed-$i" \
        "updated seed body $i concurrent-token" \
        --tag concurrent \
        --meta kind=updated \
        --keep-all \
        --format json
done

wait_for_workload

for i in $(seq 1 "$WRITE_COUNT"); do
    assert_get_body "/concurrent/write-$i" "write body $i concurrent-token"
done

for i in $(seq 1 "$SEED_COUNT"); do
    assert_get_body "/concurrent/seed-$i" "updated seed body $i concurrent-token"
    versions="$("$MB_BIN" --server "$SERVER_ENDPOINT" versions "/concurrent/seed-$i" --format jsonl)"
    version_count="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
    if [[ "$version_count" != "2" ]]; then
        echo "Expected two versions for /concurrent/seed-$i, got $version_count: $versions" >&2
        exit 1
    fi
done

LIST_JSONL="$("$MB_BIN" --server "$SERVER_ENDPOINT" list /concurrent --format jsonl)"
listed_count="$(printf '%s\n' "$LIST_JSONL" | rg -c '"path":"/concurrent/(seed|write)-[0-9]+"')"
expected_count=$((SEED_COUNT + WRITE_COUNT))
if [[ "$listed_count" != "$expected_count" ]]; then
    echo "Expected $expected_count concurrent documents, got $listed_count: $LIST_JSONL" >&2
    exit 1
fi

SEARCH_JSONL="$("$MB_BIN" --server "$SERVER_ENDPOINT" search concurrent-token --path-prefix /concurrent --limit "$expected_count" --format jsonl)"
search_count="$(printf '%s\n' "$SEARCH_JSONL" | rg -c '"path":"/concurrent/(seed|write)-[0-9]+"')"
if [[ "$search_count" -lt "$expected_count" ]]; then
    echo "Expected search to find at least $expected_count concurrent documents, got $search_count: $SEARCH_JSONL" >&2
    exit 1
fi

echo "cli server concurrent read/write smoke passed"
