#!/usr/bin/env bash
set -euo pipefail

TMP_PARENT="${METABRAIN_TMPDIR:-/private/tmp}"
TMP_DIR="$(mktemp -d "$TMP_PARENT/metabrain-daemon.XXXXXX")"
serve_pid=""

cleanup() {
    if [[ -n "$serve_pid" ]] && kill -0 "$serve_pid" 2>/dev/null; then
        kill "$serve_pid" 2>/dev/null || true
        wait "$serve_pid" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

daemon_bin="${METABRAIN_DAEMON_BIN:-}"
if [[ -z "${daemon_bin}" ]]; then
    daemon_bin="$(find .build -path '*/debug/mbd' ! -path '.build/coverage-*' -type f -perm -111 | head -n 1)"
fi

if [[ -z "${daemon_bin}" || ! -x "${daemon_bin}" ]]; then
    echo "Unable to locate mbd binary. Set METABRAIN_DAEMON_BIN or run swift build first." >&2
    exit 1
fi

"${daemon_bin}" | rg -q 'Run the metaBrain local daemon'

VERSION_JSON="$(METABRAIN_VERSION=9.8.7 "${daemon_bin}" version)"
if [[ "${VERSION_JSON}" != '{"currentTag":"9.8.7","releaseCheck":null}' ]]; then
    echo "Expected daemon version JSON, got: ${VERSION_JSON}" >&2
    exit 1
fi

"${daemon_bin}" serve --help | rg -q -- '--maximum-concurrent-requests'
"${daemon_bin}" service print --help | rg -q -- '--user'

config_path="$TMP_DIR/mbd.json"
cat >"$config_path" <<JSON
{"storePath":"$TMP_DIR/store.leveldb","socketPath":"$TMP_DIR/mbd.sock","logLevel":"error"}
JSON

SERVICE_FILE="$("${daemon_bin}" service print --user --config "$config_path")"
printf '%s\n' "$SERVICE_FILE" | rg -q 'mbd'
printf '%s\n' "$SERVICE_FILE" | rg -F -q -- '--config'
printf '%s\n' "$SERVICE_FILE" | rg -F -q "$config_path"

if "${daemon_bin}" service install 2>"$TMP_DIR/service-install-missing-user.err"; then
    echo "Expected service install without --user to fail" >&2
    exit 1
fi
rg -F -q 'only user service files are supported; pass --user' "$TMP_DIR/service-install-missing-user.err"

if "${daemon_bin}" service uninstall 2>"$TMP_DIR/service-uninstall-missing-user.err"; then
    echo "Expected service uninstall without --user to fail" >&2
    exit 1
fi
rg -F -q 'only user service files are supported; pass --user' "$TMP_DIR/service-uninstall-missing-user.err"

if env -u HOME "${daemon_bin}" service install --user --config "$config_path" 2>"$TMP_DIR/service-install-missing-home.err"; then
    echo "Expected service install without HOME to fail" >&2
    exit 1
fi
rg -F -q 'service home directory cannot be empty' "$TMP_DIR/service-install-missing-home.err"

service_home="$TMP_DIR/home"
SERVICE_PATH="$(HOME="$service_home" "${daemon_bin}" service install --user --config "$config_path")"
if [[ ! -f "$SERVICE_PATH" ]]; then
    echo "Expected service install to write $SERVICE_PATH" >&2
    exit 1
fi
UNINSTALL_OUTPUT="$(HOME="$service_home" "${daemon_bin}" service uninstall --user)"
if [[ "$UNINSTALL_OUTPUT" != "$SERVICE_PATH" ]]; then
    echo "Expected service uninstall to print $SERVICE_PATH, got: $UNINSTALL_OUTPUT" >&2
    exit 1
fi

if "${daemon_bin}" serve --request-timeout-seconds 0 2>"$TMP_DIR/serve-invalid.err"; then
    echo "Expected invalid serve configuration to fail" >&2
    exit 1
fi
rg -F -q 'requestTimeoutSeconds must be greater than 0' "$TMP_DIR/serve-invalid.err"

socket_path="$TMP_DIR/serve.sock"
"${daemon_bin}" serve --store "$TMP_DIR/store.leveldb" --socket "$socket_path" --log-level error >"$TMP_DIR/serve.out" 2>"$TMP_DIR/serve.err" &
serve_pid="$!"

for _ in $(seq 1 200); do
    if [[ -S "$socket_path" ]]; then
        break
    fi
    if ! kill -0 "$serve_pid" 2>/dev/null; then
        echo "mbd serve exited early." >&2
        cat "$TMP_DIR/serve.out" >&2 || true
        cat "$TMP_DIR/serve.err" >&2 || true
        exit 1
    fi
    sleep 0.05
done

if [[ ! -S "$socket_path" ]]; then
    echo "mbd serve did not create unix socket." >&2
    cat "$TMP_DIR/serve.out" >&2 || true
    cat "$TMP_DIR/serve.err" >&2 || true
    exit 1
fi

HEALTH_RESPONSE="$(python3 - "$socket_path" <<'PY'
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(sys.argv[1])
client.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
client.shutdown(socket.SHUT_WR)
chunks = []
while True:
    chunk = client.recv(4096)
    if not chunk:
        break
    chunks.append(chunk)
client.close()
sys.stdout.write(b"".join(chunks).decode("utf-8"))
PY
)"

printf '%s\n' "$HEALTH_RESPONSE" | rg -q 'HTTP/1.1 200 OK'
printf '%s\n' "$HEALTH_RESPONSE" | rg -F -q '{"service":"mbd","status":"ok"}'

kill "$serve_pid" 2>/dev/null || true
wait "$serve_pid" 2>/dev/null || true
serve_pid=""

loopback_config="$TMP_DIR/loopback.json"
cat >"$loopback_config" <<JSON
{"storePath":"$TMP_DIR/loopback.leveldb","loopbackHost":"127.0.0.1","loopbackPort":0,"logLevel":"info"}
JSON

"${daemon_bin}" serve --config "$loopback_config" >"$TMP_DIR/loopback.out" 2>"$TMP_DIR/loopback.err" &
serve_pid="$!"

loopback_port=""
for _ in $(seq 1 200); do
    if [[ -s "$TMP_DIR/loopback.out" ]]; then
        loopback_port="$(sed -n 's/^mbd serving on loopback http 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$TMP_DIR/loopback.out" | head -n 1)"
        if [[ -n "$loopback_port" ]]; then
            break
        fi
    fi
    if ! kill -0 "$serve_pid" 2>/dev/null; then
        echo "loopback mbd serve exited early." >&2
        cat "$TMP_DIR/loopback.out" >&2 || true
        cat "$TMP_DIR/loopback.err" >&2 || true
        exit 1
    fi
    sleep 0.05
done

if [[ -z "$loopback_port" ]]; then
    echo "mbd serve did not report a loopback port." >&2
    cat "$TMP_DIR/loopback.out" >&2 || true
    cat "$TMP_DIR/loopback.err" >&2 || true
    exit 1
fi

LOOPBACK_RESPONSE="$(python3 - "$loopback_port" <<'PY'
import socket
import sys

client = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
client.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
client.shutdown(socket.SHUT_WR)
chunks = []
while True:
    chunk = client.recv(4096)
    if not chunk:
        break
    chunks.append(chunk)
client.close()
sys.stdout.write(b"".join(chunks).decode("utf-8"))
PY
)"

printf '%s\n' "$LOOPBACK_RESPONSE" | rg -q 'HTTP/1.1 200 OK'
printf '%s\n' "$LOOPBACK_RESPONSE" | rg -F -q '{"service":"mbd","status":"ok"}'

kill "$serve_pid" 2>/dev/null || true
wait "$serve_pid" 2>/dev/null || true
serve_pid=""
rg -F -q '"event":"request_started"' "$TMP_DIR/loopback.err"
rg -F -q '"event":"request_completed"' "$TMP_DIR/loopback.err"
