#!/usr/bin/env bash
set -euo pipefail

echo "Running Swift tests with coverage..."
swift test --quiet --enable-code-coverage
echo "Building coverage-instrumented CLI..."
swift build --quiet --product metabrain --enable-code-coverage --build-path .build/coverage-cli

test_binary="$(find .build -path '*/metaBrainPackageTests.xctest/Contents/MacOS/metaBrainPackageTests' -type f | head -n 1)"
test_profile="$(find .build -path '*/codecov/default.profdata' -type f | head -n 1)"
cli_binary="$(find .build/coverage-cli -path '*/debug/metabrain' -type f -perm +111 | head -n 1)"
cli_codecov_dir="$(dirname "${cli_binary}")/codecov"

if [[ -z "${test_binary}" || -z "${test_profile}" || ! -x "${cli_binary}" ]]; then
  echo "Unable to locate SwiftPM coverage artifacts." >&2
  exit 1
fi

mkdir -p "${cli_codecov_dir}"
rm -f "${cli_codecov_dir}"/cli-*.profraw

export METABRAIN_BIN="${cli_binary}"
export LLVM_PROFILE_FILE="${cli_codecov_dir}/cli-%p.profraw"
echo "Running CLI smoke coverage..."
Tests/MetaBrainCLITests/cli-smoke.sh

cli_profiles=("${cli_codecov_dir}"/cli-*.profraw)
if [[ ! -f "${cli_profiles[0]}" ]]; then
  echo "Unable to locate CLI coverage profile artifacts." >&2
  exit 1
fi

merged_profile="${cli_codecov_dir}/merged-core-cli.profdata"
xcrun llvm-profdata merge -sparse "${test_profile}" "${cli_profiles[@]}" -o "${merged_profile}"

report="$(xcrun llvm-cov report "${test_binary}" \
  -object "${cli_binary}" \
  -instr-profile "${merged_profile}" \
  Sources/MetaBrainCore \
  Sources/MetaBrainCLI)"

echo "Coverage report:"
echo "${report}"

core_lines="$(printf '%s\n' "${report}" | awk '/MetaBrainCore\// { covered += $8 - $9; total += $8 } END { if (total == 0) exit 1; printf "%.2f%%", covered * 100 / total }')"
cli_lines="$(printf '%s\n' "${report}" | awk '/MetaBrainCLI\// { covered += $8 - $9; total += $8 } END { if (total == 0) exit 1; printf "%.2f%%", covered * 100 / total }')"

if [[ "${core_lines}" != "100.00%" ]]; then
  echo "Expected 100.00% MetaBrainCore line coverage, got ${core_lines}." >&2
  exit 1
fi

if [[ "${cli_lines}" != "100.00%" ]]; then
  echo "Expected 100.00% MetaBrainCLI line coverage, got ${cli_lines}." >&2
  exit 1
fi
