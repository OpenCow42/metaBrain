# Performance Baseline For 1.x

Branch: `codex/performance-baseline-main`
Target base: `main`
Captured: 2026-05-21
Updated: 2026-05-21

This branch adds benchmark coverage and a storage-stat capture executable for
the current 1.x storage model. It is intentionally independent of the Mark II
implementation branch so it can target `main` and provide a clean snapshot of
pre-2.0 performance.

## Base

- Base commit: `b3831e8630192b5042785ef2236d170f273f8821`
- Base tag: `1.1.2`
- Current `main` baseline commit for this update: `1ff69ee`
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
- Adds attribution groups for document records, retained versions, v1 current
  chunks, Mark II `chain/`, `segment/`, and `chunk/` families, indexes, path
  aliases, `other`, and top value families. The Mark II families are expected to
  remain zero in this 1.x baseline.
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
| MetaBrainStore get large Markdown JSON and JSONL | 576 | 2 |
| MetaBrainStore put metadata and reference heavy documents | 5 | 5 |
| MetaBrainStore update existing large document | 17 | 5 |
| MetaBrainStore patch one line in large document | 17 | 5 |
| MetaBrainStore repeated local edits large Markdown keepAll | 34 | 5 |
| MetaBrainStore search seeded corpus | 698 | 2 |
| MetaBrainStore tree list and dump nested corpus | 643 | 2 |
| MetaBrainStore versions and prune long history | 27 | 5 |
| MetaBrainStore dump all retained JSONL history | 914 | 2 |

## Capture Snapshot

Command:

```sh
swift run -c release MetaBrainCurrentBaseCapture
```

Result: passed.

| Scenario | Key count | Value bytes | Directory bytes | Key timings ms |
| --- | ---: | ---: | ---: | --- |
| put-get-large-markdown-json-jsonl | 68,891 | 1,043,722 | 3,555,328 | markdown put 888.15; JSON put 269.36; JSONL put 336.11; get all 25.39 |
| search-dump-seeded-corpus | 46,313 | 442,681 | 3,178,496 | seed 423.69; search 3,070.14; dump current 11.39; dump all retained 19.64 |
| repeated-local-edits-large-markdown | 2,008 | 417,080 | 2,920,448 | seed put 41.17; 80 patches 8,665.83; 20 gets 11.61; versions 44.83 |
| versions-dump-prune-long-history-jsonl | 1,142 | 72,440 | 3,792,896 | 70 updates 4,119.25; versions 29.66; dump all retained 33.82; prune 29.51; versions after prune 8.25 |

## Attribution Snapshot

Command:

```sh
swift run -c release MetaBrainCurrentBaseCapture
```

Result: passed after `swift package clean`, to avoid stale SwiftPM build
products from other branches.

| Scenario | Document record values | Retained version values | v1 current chunk values | Mark II chain/segment/chunk values | Index values | Largest value family |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| put-get-large-markdown-json-jsonl | 212,749 | 204,397 | 611,673 | 0 | 12,743 | `chunk/current/` 611,673 |
| search-dump-seeded-corpus | 147,443 | 121,607 | 130,036 | 0 | 37,403 | `chunk/current/` 130,036 |
| repeated-local-edits-large-markdown | 4,989 | 392,051 | 19,544 | 0 | 460 | `ver/` 392,051 |
| versions-dump-prune-long-history-jsonl | 3,222 | 61,344 | 7,382 | 0 | 456 | `ver/` 61,344 |

The capture executable prints full JSON, including per-key-family byte counts,
grouped attribution totals, and top value families to stdout. Generated output
is summarized here instead of being committed as a large result artifact.
