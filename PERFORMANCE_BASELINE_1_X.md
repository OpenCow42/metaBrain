# Performance Baseline For 1.x

Branch: `codex/performance-baseline-main`
Target base: `main`
Captured: 2026-05-21

This branch adds benchmark coverage and a storage-stat capture executable for
the current 1.x storage model. It is intentionally independent of the Mark II
implementation branch so it can target `main` and provide a clean snapshot of
pre-2.0 performance.

## Base

- Base commit: `b3831e8630192b5042785ef2236d170f273f8821`
- Base tag: `1.1.2`
- Host: `MacBookPro18,3`
- CPU architecture: `arm64`
- CPU count: 8
- Memory: 16 GB
- OS: Darwin 25.5.0
- Swift: Apple Swift 6.3.2

## Added Coverage

- Expands `MetaBrainCoreBenchmarks` with large Markdown, JSON, JSONL, get,
  retained-history dump, and repeated local-edit fixtures.
- Adds `MetaBrainCurrentBaseCapture`, a benchmark-only executable that emits
  JSON timing and LevelDB key-family storage stats for representative 1.x
  scenarios.
- Does not change `MetaBrainCore`, `MetaBrainCLI`, public APIs, or stored
  document behavior.

## Reproduction Commands

```sh
swift build -c release --target MetaBrainCurrentBaseCapture
swift build -c release --target MetaBrainCoreBenchmarks
swift run -c release MetaBrainCurrentBaseCapture
swift package benchmark run --target MetaBrainCoreBenchmarks --no-progress --time-units milliseconds
```

## Package Benchmark Snapshot

Command:

```sh
swift package benchmark run --target MetaBrainCoreBenchmarks --no-progress --time-units milliseconds
```

Result: passed.

| Benchmark | p50 wall-clock ms | Samples |
| --- | ---: | ---: |
| MetaBrainStore put small documents | 2 | 5 |
| MetaBrainStore put multi-chunk documents | 7 | 5 |
| MetaBrainStore put large Markdown JSON and JSONL | 34 | 5 |
| MetaBrainStore get large Markdown JSON and JSONL | 583 | 2 |
| MetaBrainStore put metadata and reference heavy documents | 5 | 5 |
| MetaBrainStore update existing large document | 18 | 5 |
| MetaBrainStore patch one line in large document | 18 | 5 |
| MetaBrainStore repeated local edits large Markdown keepAll | 34 | 5 |
| MetaBrainStore search seeded corpus | 695 | 2 |
| MetaBrainStore tree list and dump nested corpus | 652 | 2 |
| MetaBrainStore versions and prune long history | 27 | 5 |
| MetaBrainStore dump all retained JSONL history | 909 | 2 |

## Capture Snapshot

Command:

```sh
swift run -c release MetaBrainCurrentBaseCapture
```

Result: passed.

| Scenario | Key count | Value bytes | Directory bytes | Key timings ms |
| --- | ---: | ---: | ---: | --- |
| put-get-large-markdown-json-jsonl | 68,891 | 1,044,959 | 3,555,328 | markdown put 859.52; JSON put 266.76; JSONL put 339.70; get all 25.42 |
| search-dump-seeded-corpus | 46,313 | 445,044 | 3,178,496 | seed 428.40; search 3,084.18; dump current 11.32; dump all retained 19.20 |
| repeated-local-edits-large-markdown | 2,008 | 417,554 | 2,920,448 | seed put 42.12; 80 patches 8,744.68; 20 gets 11.44; versions 44.79 |
| versions-dump-prune-long-history-jsonl | 1,142 | 72,716 | 3,801,088 | 70 updates 4,134.33; versions 29.60; dump all retained 34.60; prune 29.48; versions after prune 8.36 |

The capture executable prints full JSON, including per-key-family byte counts,
to stdout. Generated output is summarized here instead of being committed as a
large result artifact.
