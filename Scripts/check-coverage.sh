#!/usr/bin/env bash
set -euo pipefail

minimum=100
if [[ "$#" -gt 0 ]]; then
  if [[ "$#" -ne 2 || "$1" != "--minimum" || ! "$2" =~ ^(9[5-9]|100)$ ]]; then
    echo "Usage: bash Scripts/check-coverage.sh [--minimum 95..100]" >&2
    exit 2
  fi
  minimum="$2"
fi

rm -f default.profraw

build_dir="$PWD/.build"

llvm_profdata="${LLVM_PROFDATA:-}"
llvm_cov="${LLVM_COV:-}"
if [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
  llvm_profdata="${llvm_profdata:-$(xcrun --find llvm-profdata || true)}"
  llvm_cov="${llvm_cov:-$(xcrun --find llvm-cov || true)}"
fi
llvm_profdata="${llvm_profdata:-$(command -v llvm-profdata || true)}"
llvm_cov="${llvm_cov:-$(command -v llvm-cov || true)}"

if [[ -z "${llvm_profdata}" || -z "${llvm_cov}" ]]; then
  echo "Unable to locate llvm-profdata and llvm-cov." >&2
  exit 1
fi

echo "Running Swift tests with coverage..."
swift test --quiet --enable-code-coverage
echo "Building coverage-instrumented CLI..."
swift build --quiet --product mb --enable-code-coverage --build-path "${build_dir}/coverage-cli" \
  -Xswiftc -DMETABRAIN_COVERAGE_SMOKE
echo "Building coverage-instrumented daemon..."
swift build --quiet --product mbd --enable-code-coverage --build-path "${build_dir}/coverage-daemon"

test_binary="$(find "${build_dir}" -path '*/metaBrainPackageTests.xctest/Contents/MacOS/metaBrainPackageTests' -type f | head -n 1)"
if [[ ! -x "${test_binary}" ]]; then
  test_binary="${build_dir}/debug/metaBrainPackageTests.xctest"
fi
test_profile="${build_dir}/debug/codecov/default.profdata"
cli_binary="${build_dir}/coverage-cli/debug/mb"
cli_codecov_dir="$(dirname "${cli_binary}")/codecov"
daemon_binary="${build_dir}/coverage-daemon/debug/mbd"
daemon_codecov_dir="$(dirname "${daemon_binary}")/codecov"

if [[ ! -x "${test_binary}" || ! -s "${test_profile}" || ! -x "${cli_binary}" || ! -x "${daemon_binary}" ]]; then
  echo "Unable to locate SwiftPM coverage artifacts." >&2
  exit 1
fi

mkdir -p "${cli_codecov_dir}"
rm -f "${cli_codecov_dir}"/cli-*.profraw
mkdir -p "${daemon_codecov_dir}"
rm -f "${daemon_codecov_dir}"/daemon-*.profraw

export METABRAIN_BIN="${cli_binary}"
export METABRAIN_DAEMON_BIN="${daemon_binary}"
export METABRAIN_CLIENT_BIN="${cli_binary}"
export LLVM_PROFILE_FILE="${cli_codecov_dir}/cli-%p.profraw"
echo "Running CLI smoke coverage..."
# Port 0 keeps pre-daemon probes isolated until the smoke daemon gets a real port.
METABRAIN_COVERAGE_LOOPBACK_PORT=0 Tests/MetaBrainCLITests/cli-smoke.sh

cli_profiles=("${cli_codecov_dir}"/cli-*.profraw)
if [[ ! -f "${cli_profiles[0]}" ]]; then
  echo "Unable to locate CLI coverage profile artifacts." >&2
  exit 1
fi

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

status=0
check_target() {
  if ! awk -v name="$1" -v minimum="$minimum" '
    /^TOTAL[[:space:]]/ && $8 > 0 {
      found = 1
      if (($8 - $9) * 100 < minimum * $8) {
        printf "Expected at least %d%% %s line coverage, got %s (%d lines missed).\n", minimum, name, $10, $9
        exit 1
      }
    }
    END { if (!found) exit 1 }
  ' <<<"$2"; then
    status=1
  fi
}
check_target MetaBrainCore "$core_report"
check_target MetaBrainCLI "$cli_report"
check_target MetaBrainServerSupport "$server_support_report"
check_target MetaBrainServer "$server_report"
exit "$status"
