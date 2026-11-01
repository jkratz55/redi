# Redi

A fast, native Redis client for macOS, covering the same ground as Redis Insight, built with
Swift, SwiftUI and AppKit.

- **Connections**: standalone, Cluster and Sentinel; TLS (custom CA, client certificate and key as
  PEM files; choosing a `.p12` shows the `openssl` commands that convert it); SSH tunnels through
  the system `ssh` (your `~/.ssh/config`, agents and ProxyJump work); passwords in the Keychain;
  `redis://` URL paste; import from Redis Insight; read-only and production markers.
- **Key Browser**: list and namespace-tree views over millions of keys, filtering by pattern and
  type, editors for strings, hashes (with field TTLs), lists, sets, sorted sets, streams (with
  consumer groups) and JSON; rename, TTL, delete with undo, bulk delete.
- **CLI** (⌘`): its own connection, `redis-cli` formatting, history, Tab completion and inline hints,
  confirmations for destructive commands, node targeting in clusters. Plus a **Command Helper**.
- **Workbench**: multi-line editor with highlighting and completion, pipelines, repeat prefixes,
  result cards with table and JSON views.
- **Pub/Sub**: channels, patterns and sharded channels, with automatic resubscription.
- **Analysis**: live Overview charts, Slow Log, Profiler (MONITOR), Database Analysis (memory by
  type and namespace, biggest keys, TTL distribution, recommendations), cluster Nodes view.

See [docs/perf.md](docs/perf.md) for performance budgets and measurements.

## Layout

```
Redi/                  App (SwiftUI shell, AppKit tables and text views)
Packages/RediKit/      Everything else, testable without the app
  RedisWire            RESP2/RESP3 values, incremental parser, encoder
  RedisClient          Connections, TLS, SSH tunnels, cluster topology, Sentinel
  RediCore             Sessions/routing, profiles, browser, commands, streaming, analysis
Scripts/               Dev servers, seeding, UI-test fixture, icon, release
```

## Building and testing

`xcode-select` may point at the Command Line Tools; prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if so.

```sh
# Package tests (live tests run against throwaway redis-server instances when Homebrew Redis is installed)
swift test --package-path Packages/RediKit

# Optional live topologies picked up by the tests
Scripts/gen-tls-certs.sh && Scripts/dev-redis.sh all start      # cluster, sentinel, TLS
docker compose -f Scripts/docker-compose.yml up -d ssh-bastion redis-private

# App unit tests and UI tests (the fixture script starts a seeded server)
xcodebuild -project Redi.xcodeproj -scheme Redi -destination 'platform=macOS' test -only-testing:RediTests
Scripts/ui-test-fixture.sh

# Sample data
Scripts/seed.sh 1000000 6379
```

## Releasing

`Scripts/release.sh <version> <build>` archives, signs with Developer ID, notarizes, staples and
builds a DMG, then signs it for Sparkle. Read the header of the script for one-time setup: the notary
profile and the Sparkle EdDSA keys. The updater stays disabled until `REDI_SPARKLE_PUBLIC_KEY` is set.
