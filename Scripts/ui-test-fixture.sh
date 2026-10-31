#!/usr/bin/env bash
# Starts a throwaway redis-server with the keys the UI tests expect, runs the UI tests against it,
# then stops it.
#
#   Scripts/ui-test-fixture.sh [xcodebuild test filter, default: RediUITests]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.dev-redis/ui-tests"
PORT=${REDI_UI_TEST_PORT:-6399}
FILTER=${1:-RediUITests}
mkdir -p "$STATE"

redis-server --port "$PORT" --bind 127.0.0.1 --save "" --appendonly no --daemonize yes \
  --pidfile "$STATE/redis.pid" --logfile "$STATE/redis.log"
trap 'kill "$(cat "$STATE/redis.pid")" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do redis-cli -p "$PORT" ping >/dev/null 2>&1 && break; sleep 0.1; done

redis-cli -p "$PORT" >/dev/null <<'EOF'
HSET ui:hash field-1 value-1 field-2 value-2 field-3 "{\"json\":true}"
RPUSH ui:list a b c
SADD ui:set red green blue
ZADD ui:zset 1 one 2 two 3 three
XADD ui:stream 1-1 type created user 42
XADD ui:stream 2-1 type updated user 43
SET ui:string "hello world"
SET ui:json-string "{\"name\":\"Redi\",\"tags\":[\"fast\",\"native\"]}"
SET ui:expiring soon EX 3600
EOF
for i in $(seq 1 200); do echo "SET ui:bulk:$i v$i"; done | redis-cli -p "$PORT" >/dev/null

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TEST_RUNNER_REDI_UI_TEST_PORT=$PORT xcodebuild -project "$ROOT/Redi.xcodeproj" -scheme Redi -destination 'platform=macOS' \
  ${DERIVED_DATA:+-derivedDataPath "$DERIVED_DATA"} ${RESULT_BUNDLE:+-resultBundlePath "$RESULT_BUNDLE"} \
  test -only-testing:"$FILTER"
