#!/usr/bin/env bash
set -euo pipefail

rm -f default.profraw

llvm_profdata="${LLVM_PROFDATA:-$(command -v llvm-profdata || true)}"
llvm_cov="${LLVM_COV:-$(command -v llvm-cov || true)}"
if [[ -z "${llvm_profdata}" || -z "${llvm_cov}" ]]; then
  if command -v xcrun >/dev/null 2>&1; then
    llvm_profdata="${llvm_profdata:-$(xcrun --find llvm-profdata)}"
    llvm_cov="${llvm_cov:-$(xcrun --find llvm-cov)}"
  fi
fi

if [[ -z "${llvm_profdata}" || -z "${llvm_cov}" ]]; then
  echo "Unable to locate llvm-profdata and llvm-cov." >&2
  exit 1
fi

echo "Running Swift tests with coverage..."
swift test --quiet --enable-code-coverage
echo "Building coverage-instrumented CLI..."
swift build --quiet --product mb --enable-code-coverage --build-path .build/coverage-cli
echo "Building coverage-instrumented daemon..."
swift build --quiet --product mbd --enable-code-coverage --build-path .build/coverage-daemon

test_binary="$(find .build -path '*/metaBrainPackageTests.xctest/Contents/MacOS/metaBrainPackageTests' -type f | head -n 1)"
if [[ -z "${test_binary}" ]]; then
  test_binary="$(find .build -path '*/metaBrainPackageTests.xctest' -type f -perm -111 | head -n 1)"
fi
test_profile="$(find .build -path '*/codecov/default.profdata' -type f | head -n 1)"
cli_binary="$(find .build/coverage-cli -path '*/debug/mb' -type f -perm -111 | head -n 1)"
cli_codecov_dir="$(dirname "${cli_binary}")/codecov"
daemon_binary="$(find .build/coverage-daemon -path '*/debug/mbd' -type f -perm -111 | head -n 1)"
daemon_codecov_dir="$(dirname "${daemon_binary}")/codecov"

if [[ -z "${test_binary}" || -z "${test_profile}" || ! -x "${cli_binary}" || ! -x "${daemon_binary}" ]]; then
  echo "Unable to locate SwiftPM coverage artifacts." >&2
  exit 1
fi

mkdir -p "${cli_codecov_dir}"
rm -f "${cli_codecov_dir}"/cli-*.profraw
mkdir -p "${daemon_codecov_dir}"
rm -f "${daemon_codecov_dir}"/daemon-*.profraw

export METABRAIN_BIN="${cli_binary}"
export LLVM_PROFILE_FILE="${cli_codecov_dir}/cli-%p.profraw"
echo "Running CLI smoke coverage..."
Tests/MetaBrainCLITests/cli-smoke.sh

cli_profiles=("${cli_codecov_dir}"/cli-*.profraw)
if [[ ! -f "${cli_profiles[0]}" ]]; then
  echo "Unable to locate CLI coverage profile artifacts." >&2
  exit 1
fi

export METABRAIN_DAEMON_BIN="${daemon_binary}"
export LLVM_PROFILE_FILE="${daemon_codecov_dir}/daemon-%p.profraw"
echo "Running daemon smoke coverage..."
Tests/MetaBrainServerTests/daemon-smoke.sh

daemon_profiles=("${daemon_codecov_dir}"/daemon-*.profraw)
if [[ ! -f "${daemon_profiles[0]}" ]]; then
  echo "Unable to locate daemon coverage profile artifacts." >&2
  exit 1
fi

merged_profile="${cli_codecov_dir}/merged-core-cli-daemon.profdata"
"${llvm_profdata}" merge -sparse "${test_profile}" "${cli_profiles[@]}" "${daemon_profiles[@]}" -o "${merged_profile}"

core_report="$("${llvm_cov}" report "${test_binary}" \
  -instr-profile "${merged_profile}" \
  Sources/MetaBrainCore)"

cli_report="$("${llvm_cov}" report "${cli_binary}" \
  -instr-profile "${merged_profile}" \
  Sources/MetaBrainCLI)"

server_support_report="$("${llvm_cov}" report "${test_binary}" \
  -instr-profile "${merged_profile}" \
  Sources/MetaBrainServerSupport)"

server_report="$("${llvm_cov}" report "${daemon_binary}" \
  -instr-profile "${merged_profile}" \
  Sources/MetaBrainServer)"

echo "Coverage report:"
echo "${core_report}"
echo "${cli_report}"
echo "${server_support_report}"
echo "${server_report}"

coverage_lines() {
  awk '/^TOTAL[[:space:]]/ { if ($8 == 0) exit 1; printf "%.2f%%", ($8 - $9) * 100 / $8 }'
}

core_lines="$(printf '%s\n' "${core_report}" | coverage_lines)"
cli_lines="$(printf '%s\n' "${cli_report}" | coverage_lines)"
server_support_lines="$(printf '%s\n' "${server_support_report}" | coverage_lines)"
server_lines="$(printf '%s\n' "${server_report}" | coverage_lines)"

if [[ "${core_lines}" != "100.00%" ]]; then
  echo "Expected 100.00% MetaBrainCore line coverage, got ${core_lines}." >&2
  exit 1
fi

if [[ "${cli_lines}" != "100.00%" ]]; then
  echo "Expected 100.00% MetaBrainCLI line coverage, got ${cli_lines}." >&2
  exit 1
fi

if [[ "${server_support_lines}" != "100.00%" ]]; then
  echo "Expected 100.00% MetaBrainServerSupport line coverage, got ${server_support_lines}." >&2
  exit 1
fi

if [[ "${server_lines}" != "100.00%" ]]; then
  echo "Expected 100.00% MetaBrainServer line coverage, got ${server_lines}." >&2
  exit 1
fi
