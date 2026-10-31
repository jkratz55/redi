# Performance

Redi is measured against the budgets in the project plan. All numbers are from Apple Silicon,
Release builds, macOS 27.2, against a local Redis 8.10.3.

| Budget | Target | Measured | How |
|---|---|---|---|
| RESP parser, 1M-element reply | < 200 ms | **35 ms** (17 MB) | `swift test -c release -Xswiftc -enable-testing --filter RESPPerformance` |
| Index + namespace tree, 1M keys | < 1 s | **0.27 s** | `swift test -c release -Xswiftc -enable-testing --filter KeyTreeTests` |
| Scan All, 1M keys, in the app (tree view) | — | **3.6 s** | `testScanAllLargeKeyspace` UI test (below) |
| Memory with 1M keys loaded | < 250 MB | **132–148 MB** | `footprint` sampled during the UI test |
| Cold launch | < 400 ms | **0.38 s** average (Debug build, XCTest launch metric) | `testLaunchPerformance` |
| Memory at launch (Connections window) | < 80 MB with 10k keys | **29 MB** | `footprint` after launch |
| Idle CPU | 0% | **0.0%** after the scan and while idle | `ps -o %cpu` sampled every 2 s |
| App bundle size | — | 1.6 MB (before Sparkle) | `du -sh Redi.app` |

## How the numbers stay low

- Keys are stored in paged byte arenas (`KeyIndex`), not one `String` per key; only on-screen
  rows are decoded.
- The namespace tree hashes byte slices of those arenas instead of allocating segment strings.
- TYPE/TTL/MEMORY USAGE are fetched only for visible rows, in one pipeline, debounced on scroll.
- Pub/Sub and MONITOR use fixed-size ring buffers and batch UI updates (50 ms batches, ≤ 10 Hz
  table reloads).
- Overview polling runs only while its window is visible on screen (`NSWindow.occlusionState`), with
  timer tolerance so the system can coalesce wakeups.
- Every long or blocking job (scans, analysis, CLI, Workbench, Pub/Sub, MONITOR) has its own
  connection, so none of them delays interactive commands.

## Reproducing the 1M-key run

```sh
redis-server --port 6397 --save "" --daemonize yes
Scripts/seed.sh 1000000 6397
TEST_RUNNER_REDI_PERF_PORT=6397 xcodebuild -project Redi.xcodeproj -scheme Redi \
  -configuration Release ENABLE_TESTABILITY=YES -destination 'platform=macOS' \
  test -only-testing:RediUITests/RediUITests/testScanAllLargeKeyspace
# meanwhile: footprint $(pgrep -x Redi)
```

## Profiling

Signposts (`OSSignposter`, subsystem `com.github.jkratz55.Redi`, category `Browser`) mark scan
pages, page appends and metadata fetches. Record with the *Points of Interest* instrument
alongside Time Profiler and Hangs.

Not yet measured: a comparison against Redis Insight on the same dataset, and an Instruments
Hangs pass while scrolling the 1M-key list.
