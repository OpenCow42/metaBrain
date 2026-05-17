#!/usr/bin/env bash
set -euo pipefail

export METABRAIN_FUZZ_COUNT="${METABRAIN_FUZZ_COUNT:-500}"

echo "Running deterministic MetaBrainCore fuzz/property tests with METABRAIN_FUZZ_COUNT=${METABRAIN_FUZZ_COUNT}..."
swift test --filter MetaBrainCoreFuzzTests
