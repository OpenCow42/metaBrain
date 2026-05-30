#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "cli-server-performance.sh is currently calibrated for macOS only." >&2
    exit 1
fi

TMP_PARENT="${METABRAIN_TMPDIR:-}"
if [[ -z "$TMP_PARENT" ]]; then
    if [[ -d /private/tmp ]]; then
        TMP_PARENT=/private/tmp
    else
        TMP_PARENT=/tmp
    fi
fi

TMP_DIR="$(mktemp -d "$TMP_PARENT/metabrain-perf.XXXXXX")"
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
elif [[ -x "$ROOT_DIR/.build/release/mb" ]]; then
    MB_BIN="$ROOT_DIR/.build/release/mb"
elif [[ -x "$ROOT_DIR/.build/debug/mb" ]]; then
    MB_BIN="$ROOT_DIR/.build/debug/mb"
else
    echo "Unable to locate mb. Set METABRAIN_BIN or run swift build first." >&2
    exit 1
fi

if [[ -n "${METABRAIN_DAEMON_BIN:-}" ]]; then
    MBD_BIN="$METABRAIN_DAEMON_BIN"
elif [[ -x "$ROOT_DIR/.build/release/mbd" ]]; then
    MBD_BIN="$ROOT_DIR/.build/release/mbd"
elif [[ -x "$ROOT_DIR/.build/debug/mbd" ]]; then
    MBD_BIN="$ROOT_DIR/.build/debug/mbd"
else
    echo "Unable to locate mbd. Set METABRAIN_DAEMON_BIN or run swift build first." >&2
    exit 1
fi

WRITE_COUNT="${METABRAIN_PERF_WRITES:-40}"
READ_COUNT="${METABRAIN_PERF_READS:-80}"
UPDATE_COUNT="${METABRAIN_PERF_UPDATES:-40}"
SEARCH_COUNT="${METABRAIN_PERF_SEARCHES:-20}"

now_ms() {
    python3 -c 'import time; print(time.perf_counter_ns() // 1_000_000)'
}

ops_per_second() {
    awk -v ops="$1" -v ms="$2" 'BEGIN { if (ms <= 0) { print "inf" } else { printf "%.2f", (ops * 1000) / ms } }'
}

speedup() {
    awk -v direct_ms="$1" -v server_ms="$2" 'BEGIN { if (server_ms <= 0) { print "inf" } else { printf "%.2fx", direct_ms / server_ms } }'
}

run_cli_workload() {
    local mode="$1"
    local store="$2"
    local server_endpoint="${3:-}"
    local -a common_args

    case "$mode" in
        direct)
            common_args=(--store "$store" --no-server)
            ;;
        server)
            common_args=(--server "$server_endpoint")
            ;;
        *)
            echo "unknown workload mode: $mode" >&2
            exit 1
            ;;
    esac

    "$MB_BIN" init "${common_args[@]}" >/dev/null

    for i in $(seq 1 "$WRITE_COUNT"); do
        "$MB_BIN" put "/perf/doc-$i" "initial body $i common-token group-$((i % 8))" "${common_args[@]}" --format json >/dev/null
    done

    for i in $(seq 1 "$READ_COUNT"); do
        local doc=$(( (i - 1) % WRITE_COUNT + 1 ))
        "$MB_BIN" get "/perf/doc-$doc" "${common_args[@]}" --format json >/dev/null
    done

    for i in $(seq 1 "$UPDATE_COUNT"); do
        local doc=$(( (i - 1) % WRITE_COUNT + 1 ))
        "$MB_BIN" put "/perf/doc-$doc" "updated body $i common-token group-$((doc % 8))" "${common_args[@]}" --format json >/dev/null
    done

    for i in $(seq 1 "$SEARCH_COUNT"); do
        "$MB_BIN" search "common-token" "${common_args[@]}" --limit 10 --format jsonl >/dev/null
    done
}

start_server() {
    local store="$1"
    local stdout="$TMP_DIR/mbd.out"
    local stderr="$TMP_DIR/mbd.err"

    "$MBD_BIN" serve --store "$store" --host 127.0.0.1 --port 0 --log-level error >"$stdout" 2>"$stderr" &
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

DIRECT_STORE="$TMP_DIR/direct-store.leveldb"
SERVER_STORE="$TMP_DIR/server-store.leveldb"
TOTAL_OPS=$((1 + WRITE_COUNT + READ_COUNT + UPDATE_COUNT + SEARCH_COUNT))
SERVER_ENDPOINT=""

direct_start="$(now_ms)"
run_cli_workload direct "$DIRECT_STORE"
direct_end="$(now_ms)"
DIRECT_MS=$((direct_end - direct_start))

start_server "$SERVER_STORE"
server_start="$(now_ms)"
run_cli_workload server "$SERVER_STORE" "$SERVER_ENDPOINT"
server_end="$(now_ms)"
SERVER_MS=$((server_end - server_start))

DIRECT_OPS="$(ops_per_second "$TOTAL_OPS" "$DIRECT_MS")"
SERVER_OPS="$(ops_per_second "$TOTAL_OPS" "$SERVER_MS")"
SERVER_SPEEDUP="$(speedup "$DIRECT_MS" "$SERVER_MS")"

cat <<REPORT
metaBrain CLI/server serial performance
platform: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))
mb: $MB_BIN
mbd: $MBD_BIN
server: $SERVER_ENDPOINT
workload: writes=$WRITE_COUNT reads=$READ_COUNT updates=$UPDATE_COUNT searches=$SEARCH_COUNT total_commands=$TOTAL_OPS

mode,total_ms,commands_per_second
direct-cli,$DIRECT_MS,$DIRECT_OPS
server-cli,$SERVER_MS,$SERVER_OPS

server_speedup: $SERVER_SPEEDUP
REPORT
