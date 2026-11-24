#!/usr/bin/env python3
"""Measure citation operations through release mb and mbd executables."""

import argparse
from contextlib import contextmanager, nullcontext
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

from citation_workloads import run_workloads


ROOT = Path(__file__).resolve().parents[1]
DAEMON_READY = re.compile(r"^mbd serving on loopback http (127\.0\.0\.1:\d+)$", re.MULTILINE)
STARTUP_TIMEOUT = 20


def executable(override, name):
    suffix = ".exe" if os.name == "nt" else ""
    default = ROOT / ".build" / "release" / (name + suffix)
    configured = os.path.expanduser(os.environ.get(override) or str(default))
    found = shutil.which(configured)
    if not found:
        raise RuntimeError(f"Unable to execute {configured!r}. Build release {name} or set {override}.")
    return Path(found).resolve()


@contextmanager
def daemon_endpoint(binary, directory, store):
    config = directory / "mbd-config.json"
    config.write_text("{}", encoding="utf-8")
    stdout_path = directory / "mbd.out"
    stderr_path = directory / "mbd.err"
    command = [
        str(binary), "serve", "--config", str(config), "--store", str(store),
        "--host", "127.0.0.1", "--port", "0", "--log-level", "error",
    ]

    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        with subprocess.Popen(command, cwd=directory, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr) as daemon:
            try:
                deadline = time.monotonic() + STARTUP_TIMEOUT
                endpoint = None
                while time.monotonic() < deadline and daemon.poll() is None:
                    ready = DAEMON_READY.search(stdout_path.read_text(encoding="utf-8", errors="replace"))
                    if ready:
                        endpoint = "http://" + ready.group(1)
                        break
                    time.sleep(0.025)
                if endpoint is None:
                    log = stderr_path.read_text(encoding="utf-8", errors="replace")
                    if not log:
                        log = stdout_path.read_text(encoding="utf-8", errors="replace")
                    status = f"exited with status {daemon.returncode}" if daemon.returncode is not None else "timed out"
                    raise RuntimeError(f"mbd startup {status}. {log.strip()}")
                yield endpoint
            finally:
                if daemon.poll() is None:
                    daemon.terminate()
                    try:
                        daemon.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        daemon.kill()
                        daemon.wait()


def invoke_for(binary, directory, store, endpoint, timeout):
    selection = ["--server", endpoint] if endpoint else ["--no-server"]
    command_prefix = [str(binary), "--store", str(store), *selection]

    def invoke(*args):
        command = [*command_prefix, *args]
        started = time.perf_counter_ns()
        try:
            result = subprocess.run(
                command, cwd=directory, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"{shlex.join(args)[:400]} timed out after {error.timeout:g} seconds.") from error
        elapsed_ns = time.perf_counter_ns() - started
        stdout_bytes = len(result.stdout)
        if result.returncode:
            detail = result.stderr or result.stdout
            raise RuntimeError(
                f"{shlex.join(args)[:400]} exited with status {result.returncode}. "
                f"{detail[:1000].decode('utf-8', errors='replace').strip()}"
            )
        try:
            return json.loads(result.stdout), elapsed_ns, stdout_bytes
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise RuntimeError(f"{shlex.join(args)[:400]} returned invalid JSON. {error}") from error

    return invoke


def summarize(mode, count, workload, measurements):
    latencies = sorted(elapsed_ns for elapsed_ns, _ in measurements)
    sizes = [size for _, size in measurements]
    return {
        "mode": mode,
        "count": count,
        "workload": workload,
        "latencyMs": {
            "p50": statistics.median(latencies) / 1_000_000,
            "p95": latencies[math.ceil(0.95 * len(latencies)) - 1] / 1_000_000,
        },
        "stdoutBytes": {"p50": statistics.median(sizes), "max": max(sizes)},
        "samples": [{"elapsedNs": elapsed_ns, "stdoutBytes": size} for elapsed_ns, size in measurements],
    }


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--counts", nargs="+", type=int, default=[1, 32, 256], help="Corpus sizes (default: 1 32 256).")
    parser.add_argument("--warmups", type=int, default=3, help="Untimed runs per workload (default: 3).")
    parser.add_argument("--samples", type=int, default=12, help="Measured runs per workload (default: 12).")
    parser.add_argument("--mode", choices=("both", "direct", "daemon"), default="both")
    parser.add_argument("--label", help="Label this report with the revision or configuration under test.")
    parser.add_argument("--command-timeout", type=float, help="Optional timeout in seconds for each mb command.")
    args = parser.parse_args()
    if any(count < 1 for count in args.counts):
        parser.error("--counts values must be positive")
    if len(set(args.counts)) != len(args.counts):
        parser.error("--counts values must be distinct")
    if args.warmups < 0:
        parser.error("--warmups must be zero or greater")
    if args.samples < 1:
        parser.error("--samples must be positive")
    timeout = args.command_timeout
    if timeout is not None and (not math.isfinite(timeout) or timeout <= 0):
        parser.error("--command-timeout must be a finite positive number")
    return args


def main():
    args = parse_args()
    modes = ("direct", "daemon") if args.mode == "both" else (args.mode,)
    mb = executable("METABRAIN_BIN", "mb")
    mbd = executable("METABRAIN_DAEMON_BIN", "mbd") if "daemon" in modes else None
    temp_parent = os.environ.get("METABRAIN_TMPDIR") or None
    rows = []
    for index, count in enumerate(args.counts):
        ordered_modes = modes[::-1] if index % 2 else modes
        for mode in ordered_modes:
            with tempfile.TemporaryDirectory(prefix="mb-citation-perf-", dir=temp_parent) as directory:
                directory = Path(directory).resolve()
                store = directory / "store.leveldb"
                endpoint = daemon_endpoint(mbd, directory, store) if mode == "daemon" else nullcontext()
                try:
                    with endpoint as address:
                        invoke = invoke_for(mb, directory, store, address, args.command_timeout)
                        measurements = run_workloads(invoke, count, args.warmups, args.samples)
                except (OSError, RuntimeError, ValueError, AssertionError) as error:
                    raise RuntimeError(f"{mode}, count={count}: {error}") from error
                for workload, samples in sorted(measurements.items()):
                    rows.append(summarize(mode, count, workload, samples))

    report = {
        "schemaVersion": 1,
        "system": {"os": platform.system(), "release": platform.release(), "architecture": platform.machine()},
        "config": {
            "counts": args.counts,
            "warmups": args.warmups,
            "samples": args.samples,
            "mode": args.mode,
            "label": args.label,
            "commandTimeoutSeconds": args.command_timeout,
            "daemonTransport": "loopback-http" if mbd else None,
            "binaries": {"mb": str(mb), "mbd": str(mbd) if mbd else None},
            "percentiles": {"p50": "median", "p95": "nearest-rank"},
        },
        "rows": rows,
    }
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        sys.exit(f"citation-performance: {error}")
