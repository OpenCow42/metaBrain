#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
STORE="$TMP_DIR/store.leveldb"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"

swift run metabrain init --store "$STORE" | rg 'Initialized metaBrain store'
swift run metabrain put --store "$STORE" /notes/today 'alpha beta searchable memory' --title Today --tag search --meta status=active | rg '^version: 1$'
swift run metabrain get --store "$STORE" --path /notes/today | rg 'alpha beta searchable memory'
swift run metabrain search --store "$STORE" 'alpha beta' --tag search --meta status=active | rg '/notes/today'
swift run metabrain put --store "$STORE" /notes/today 'alpha beta updated memory' --keep-last 2 | rg '^version: 2$'
swift run metabrain versions --store "$STORE" --path /notes/today | rg '^2 '
swift run metabrain prune --store "$STORE" --path /notes/today --keep-last 1 | rg '^retained: 1$'
swift run metabrain versions --store "$STORE" --path /notes/today | rg '^2 '
