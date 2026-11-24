# Citation performance

Run the end-to-end benchmark from the repository root with Python 3 and release
builds of `mb` and `mbd`. Save the JSON when comparing revisions.

```sh
swift build -c release
python3 Benchmarks/citation-performance.py --label "$(git rev-parse --short HEAD)" > citation-report.json
```

Each run uses a fresh temporary store for each combination of link count and
mode. The defaults are 1, 32, and 256 links, three warmups, and twelve measured
samples per workload. Direct mode passes `--no-server`. Daemon mode starts a
private `mbd` on an ephemeral loopback HTTP port. To use particular binaries,
set `METABRAIN_BIN` and `METABRAIN_DAEMON_BIN`.

| Workload | Timed operation at link count N |
| --- | --- |
| `rewrite` | Update one Markdown note containing N resolved block citations to N distinct targets. Each edit changes the body, advances the revision, and retains the most recent version. |
| `outgoing` | Read all N outgoing occurrences from that note and resolve the cited block in each distinct target. |
| `incoming` | Read the N incoming occurrences on one block cited by N distinct Markdown notes. |
| `resolve` | Create a target with a named block that N existing notes already cite. Every sample introduces a fresh target. |

Each sample measures a new `mb` process from launch through exit with JSON
output captured. This includes reading the rewrite body file, communicating
with the selected store, and serializing the response. The harness records
latency with a monotonic clock and counts the exact bytes on stdout, including
the trailing newline. It verifies source and target IDs, revisions, fragments,
and occurrence counts outside the timed interval. For `resolve`, the reported
bytes belong to the `put` response. A separate backlink query verifies the
resolved edges.

This example extends the daemon run to 1,024 links.

```sh
python3 Benchmarks/citation-performance.py --mode daemon --counts 1 32 256 1024 --warmups 5 --samples 30 > daemon-citations.json
```

You can also run the small integration check against existing release binaries.

```sh
python3 Benchmarks/test_citation_performance.py --mb .build/release/mb --mbd .build/release/mbd
```

The CLI smoke suite runs this check at 1 and 3 links. It verifies the metrics,
including that the byte count matches a separate capture of raw CLI output.

Compare rows with the same mode, count, and workload on comparable hardware
and builds. Each row contains the median and nearest-rank p95 latency in
milliseconds, median and maximum response bytes, and the raw paired samples
in nanoseconds and bytes. With twelve samples, nearest-rank p95 is the slowest
sample. This command prints one row per combination of mode, count, and workload.

```sh
jq -r '.rows[] | [.mode, .count, .workload, .latencyMs.p50, .latencyMs.p95, .stdoutBytes.p50, .stdoutBytes.max] | @tsv' citation-report.json
```

## Baseline

The [checked-in CSV](../Benchmarks/Baselines/citation-macos-arm64.csv) records
all 24 workload, count, and mode combinations. The capture used the default
settings on November 24, 2026, on an Apple M1 Pro running macOS 26.7.3,
with Apple Swift 6.3.3 release binaries built from `f8b81cc`.

Reading outgoing links through `mbd` grew from a median of 10.33 ms and
364 bytes at one link to 32.61 ms and 93,637 bytes at 256 links. Creating a
target with 256 pending citations took a median of 65.12 ms directly and
31.05 ms through `mbd`. Both commands acknowledged that write in 132 bytes.
