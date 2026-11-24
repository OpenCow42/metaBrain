"""Exercise citation benchmark reports with real CLI and daemon binaries."""

import argparse
import json
import math
import os
from pathlib import Path
import runpy
import statistics
import subprocess
import sys
import tempfile


MODES = ("direct", "daemon")
COUNTS = (1, 3)
WORKLOADS = ("rewrite", "outgoing", "incoming", "resolve")
WARMUPS = 1
SAMPLES = 4
LABEL = "citation-perf-smoke"
COMMAND_TIMEOUT_SECONDS = 30
RUNNER = Path(__file__).with_name("citation-performance.py").resolve()


def run_benchmark(binaries, temp_root):
    arguments = [
        sys.executable, str(RUNNER), "--mode", "both", "--counts", *map(str, COUNTS),
        "--warmups", str(WARMUPS), "--samples", str(SAMPLES),
        "--label", LABEL, "--command-timeout", str(COMMAND_TIMEOUT_SECONDS),
    ]
    with tempfile.TemporaryDirectory(prefix="test-metabrain-citation-", dir=temp_root) as directory:
        environment = {
            **os.environ,
            "METABRAIN_BIN": str(binaries["mb"]),
            "METABRAIN_DAEMON_BIN": str(binaries["mbd"]),
            "METABRAIN_TMPDIR": directory,
        }
        duplicate_counts = subprocess.run(
            [sys.executable, str(RUNNER), "--counts", "1", "1"], env=environment, capture_output=True, timeout=5,
        )
        assert duplicate_counts.returncode == 2 and b"--counts values must be distinct" in duplicate_counts.stderr
        assert not duplicate_counts.stdout
        process = subprocess.run(arguments, env=environment, capture_output=True)
        assert process.returncode == 0, process.stderr.decode(errors="replace")
        assert not list(Path(directory).iterdir()), "Benchmark left temporary files behind"
    return json.loads(process.stdout)


def verify_summary_quantiles():
    # With twenty samples the nearest-rank p95 is below the maximum.
    summarize = runpy.run_path(str(RUNNER))["summarize"]
    samples = [(rank * 1_000_000, rank * 10) for rank in range(20, 0, -1)]
    summary = summarize("direct", 1, "rewrite", samples)
    assert summary["latencyMs"] == {"p50": 10.5, "p95": 19.0}, summary
    assert summary["stdoutBytes"] == {"p50": 105, "max": 200}, summary


def verify_report(report, binaries):
    assert report["schemaVersion"] == 1
    for key in ("os", "release", "architecture"):
        assert isinstance(report["system"][key], str) and report["system"][key], key
    config = report["config"]
    assert config["mode"] == "both"
    assert config["counts"] == list(COUNTS)
    assert config["warmups"] == WARMUPS
    assert config["samples"] == SAMPLES
    assert config["label"] == LABEL
    assert config["daemonTransport"] == "loopback-http"
    assert config["commandTimeoutSeconds"] == COMMAND_TIMEOUT_SECONDS
    assert config["percentiles"] == {"p50": "median", "p95": "nearest-rank"}
    assert config["binaries"] == {key: str(path) for key, path in binaries.items()}

    rows = report["rows"]
    by_key = {(row["mode"], row["count"], row["workload"]): row for row in rows}
    expected_keys = {(mode, count, workload) for mode in MODES for count in COUNTS for workload in WORKLOADS}
    assert set(by_key) == expected_keys, set(by_key) ^ expected_keys
    assert len(rows) == len(by_key), "Duplicate benchmark row"

    for key, row in by_key.items():
        assert len(row["samples"]) == SAMPLES, key
        latencies = sorted(sample["elapsedNs"] for sample in row["samples"])
        sizes = [sample["stdoutBytes"] for sample in row["samples"]]
        assert all(type(value) is int and value > 0 for value in latencies + sizes), (key, row["samples"])
        median_ms = statistics.median(latencies) / 1_000_000
        nearest_rank_ms = latencies[math.ceil(0.95 * len(latencies)) - 1] / 1_000_000
        assert math.isclose(row["latencyMs"]["p50"], median_ms, rel_tol=1e-12), key
        assert math.isclose(row["latencyMs"]["p95"], nearest_rank_ms, rel_tol=1e-12), key
        assert row["stdoutBytes"] == {"p50": statistics.median(sizes), "max": max(sizes)}, key

    # Both transports should emit the same size of JSON for the deterministic link graph.
    for workload in ("outgoing", "incoming"):
        for count in COUNTS:
            assert by_key["direct", count, workload]["stdoutBytes"] == by_key["daemon", count, workload]["stdoutBytes"], (
                count, workload
            )
        for mode in MODES:
            assert by_key[mode, 3, workload]["stdoutBytes"]["p50"] > by_key[mode, 1, workload]["stdoutBytes"]["p50"], (
                mode, workload
            )
    return by_key["direct", 1, "rewrite"]["samples"]


def verify_rewrite_bytes(binary, temp_root, samples):
    with tempfile.TemporaryDirectory(prefix="test-metabrain-rewrite-", dir=temp_root) as directory:
        command = [str(binary), "--no-server", "--store", str(Path(directory) / "store.leveldb")]

        def run(*arguments):
            result = subprocess.run(
                [*command, *arguments, "--format", "json"], capture_output=True, timeout=COMMAND_TIMEOUT_SECONDS,
            )
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            return result.stdout

        run("init", "--empty")
        run("put", "/source.md", "First revision.", "--keep-last", "1")
        raw = run("put", "/source.md", "Second revision.", "--body-only")
        assert raw.endswith(b"\n"), raw
        update = json.loads(raw)
        assert update["status"] == "updated" and update["version"] == 2, update
        # All sampled rewrites also use a one-digit revision and a generated document ID.
        assert {sample["stdoutBytes"] for sample in samples} == {len(raw)}, raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mb", default=os.environ.get("METABRAIN_BIN"), help="Path to the built mb executable")
    parser.add_argument("--mbd", default=os.environ.get("METABRAIN_DAEMON_BIN"), help="Path to the built mbd executable")
    parser.add_argument("--tmpdir", default=os.environ.get("METABRAIN_TMPDIR"), help="Temporary fixture parent directory")
    args = parser.parse_args()
    if not args.mb or not args.mbd:
        parser.error("Provide --mb and --mbd or set METABRAIN_BIN and METABRAIN_DAEMON_BIN")
    binaries = {"mb": Path(args.mb).expanduser().resolve(), "mbd": Path(args.mbd).expanduser().resolve()}
    for key, binary in binaries.items():
        if not binary.is_file() or not os.access(binary, os.X_OK):
            parser.error(f"--{key} must point to an executable: {binary}")
    temp_root = Path(args.tmpdir).expanduser().resolve() if args.tmpdir else None
    verify_summary_quantiles()
    report = run_benchmark(binaries, temp_root)
    rewrite_samples = verify_report(report, binaries)
    verify_rewrite_bytes(binaries["mb"], temp_root, rewrite_samples)
    print(f"Verified {len(report['rows'])} citation benchmark rows in direct and daemon modes.")


if __name__ == "__main__":
    main()
