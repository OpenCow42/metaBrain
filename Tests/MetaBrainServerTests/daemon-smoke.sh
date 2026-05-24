#!/usr/bin/env bash
set -euo pipefail

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
