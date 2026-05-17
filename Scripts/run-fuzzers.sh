#!/usr/bin/env bash
set -euo pipefail

max_total_time="60"
extra_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-total-time)
      if [[ $# -lt 2 ]]; then
        echo "--max-total-time requires a value in seconds." >&2
        exit 2
      fi
      max_total_time="$2"
      shift 2
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
  esac
done

probe_source="$(mktemp -t metabrain-fuzzer-probe.XXXXXX.swift)"
probe_object="$(mktemp -t metabrain-fuzzer-probe.XXXXXX.o)"
probe_log="$(mktemp -t metabrain-fuzzer-probe.XXXXXX.log)"
printf 'public func metabrainFuzzerProbe() {}\n' > "${probe_source}"
if ! swiftc -sanitize=fuzzer -parse-as-library -c "${probe_source}" -o "${probe_object}" 2>"${probe_log}"; then
  if grep -q "unsupported option '-sanitize=fuzzer'" "${probe_log}"; then
    cat <<'MESSAGE'
Skipping MetaBrainCoreFuzzer: this Swift toolchain does not support --sanitize fuzzer for the active target.
The deterministic fuzz/property suite remains available with Scripts/run-fuzz-tests.sh.
MESSAGE
    rm -f "${probe_source}" "${probe_object}" "${probe_log}"
    exit 0
  fi

  cat "${probe_log}" >&2
  cat >&2 <<'MESSAGE'
Unable to verify Swift libFuzzer support for this toolchain.
The deterministic fuzz/property suite remains available with Scripts/run-fuzz-tests.sh.
MESSAGE
  rm -f "${probe_source}" "${probe_object}" "${probe_log}"
  exit 1
fi
rm -f "${probe_source}" "${probe_object}" "${probe_log}"

echo "Building MetaBrainCoreFuzzer with Swift libFuzzer instrumentation..."
build_log="$(mktemp -t metabrain-fuzzer-build.XXXXXX)"
if ! swift build -c debug --sanitize fuzzer -Xswiftc -parse-as-library --target MetaBrainCoreFuzzer 2>&1 | tee "${build_log}"; then
  if grep -q "unsupported option '-sanitize=fuzzer'" "${build_log}"; then
    cat <<'MESSAGE'
Skipping MetaBrainCoreFuzzer: this Swift toolchain does not support --sanitize fuzzer for the active target.
The deterministic fuzz/property suite remains available with Scripts/run-fuzz-tests.sh.
MESSAGE
    rm -f "${build_log}"
    exit 0
  fi

  cat >&2 <<'MESSAGE'
Unable to build MetaBrainCoreFuzzer with --sanitize fuzzer.
Install or select a Swift toolchain with libFuzzer support, then rerun this script.
The deterministic fuzz/property suite remains available with Scripts/run-fuzz-tests.sh.
MESSAGE
  rm -f "${build_log}"
  exit 1
fi
rm -f "${build_log}"

bin_path="$(swift build -c debug --show-bin-path)"
binary="${bin_path}/MetaBrainCoreFuzzer"
corpus_dir=".build/fuzzing/corpus/MetaBrainCoreFuzzer"
findings_dir=".build/fuzzing/findings/MetaBrainCoreFuzzer"
seed_dir="Scripts/FuzzSeeds/MetaBrainCoreFuzzer"

if [[ ! -x "${binary}" ]]; then
  echo "Unable to locate built fuzzer binary at ${binary}." >&2
  exit 1
fi

mkdir -p "${corpus_dir}" "${findings_dir}"
if [[ -z "$(find "${corpus_dir}" -type f -print -quit)" ]]; then
  cp "${seed_dir}"/* "${corpus_dir}/"
fi

echo "Running MetaBrainCoreFuzzer for ${max_total_time}s..."
"${binary}" \
  -max_total_time="${max_total_time}" \
  -artifact_prefix="${findings_dir}/" \
  "${corpus_dir}" \
  "${findings_dir}" \
  "${extra_args[@]}"
