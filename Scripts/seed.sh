#!/usr/bin/env bash
# Loads a realistic mixed-type dataset into a Redis server.
#
#   Scripts/seed.sh [key-count=100000] [port=6379] [extra redis-cli args...]
#   Scripts/seed.sh 1000000            # 1M keys into localhost:6379
#   Scripts/seed.sh 50000 6380 --tls --cacert .dev-redis/tls/ca.crt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT=${1:-100000}
PORT=${2:-6379}
shift $(( $# > 2 ? 2 : $# ))

swift build -c release --package-path "$ROOT/Packages/RediKit" --product redi-seed >/dev/null
"$(swift build -c release --package-path "$ROOT/Packages/RediKit" --show-bin-path)/redi-seed" --keys "$COUNT" \
  | redis-cli -p "$PORT" "$@" --pipe
