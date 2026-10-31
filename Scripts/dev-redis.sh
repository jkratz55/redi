#!/usr/bin/env bash
# Local Redis topologies for developing and testing Redi, using the Homebrew redis-server.
#
#   Scripts/dev-redis.sh <topology> <start|stop|status>
#
# Topologies (all bound to 127.0.0.1, no persistence, state under .dev-redis/):
#   standalone  port 6379
#   cluster     ports 30001-30006 (3 primaries + 3 replicas; avoids 7000, which macOS AirPlay uses)
#   sentinel    primary 6390, replica 6391, sentinels 26379-26381 (master name: redi-primary)
#   tls         TLS-only port 6380, client certs optional (run Scripts/gen-tls-certs.sh first)
#   all         every topology above
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.dev-redis"
REDIS_SERVER="${REDIS_SERVER:-$(command -v redis-server || true)}"
REDIS_CLI="${REDIS_CLI:-$(command -v redis-cli || true)}"
CLUSTER_PORTS=(30001 30002 30003 30004 30005 30006)
COMMON=(--bind 127.0.0.1 --save "" --appendonly no --protected-mode no --daemonize yes --loglevel warning)

die() { echo "error: $*" >&2; exit 1; }
[[ -x "$REDIS_SERVER" && -x "$REDIS_CLI" ]] || die "redis-server/redis-cli not found (brew install redis)"

start_server() { # name port [extra args...]
  local name=$1 port=$2; shift 2
  local dir="$STATE/$name"
  mkdir -p "$dir"
  if [[ -f "$dir/redis.pid" ]] && kill -0 "$(cat "$dir/redis.pid")" 2>/dev/null; then
    echo "  $name already running on $port"; return
  fi
  "$REDIS_SERVER" "${COMMON[@]}" --port "$port" --dir "$dir" \
    --pidfile "$dir/redis.pid" --logfile "$dir/redis.log" "$@"
  wait_for "$port" "$@"
  echo "  $name listening on $port"
}

wait_for() { # port [args...] — waits until PING succeeds (plain or TLS)
  local port=$1; shift
  for _ in $(seq 1 50); do
    if [[ " $* " == *" --tls-port "* ]]; then
      "$REDIS_CLI" -p "$port" --tls --cacert "$STATE/tls/ca.crt" ping >/dev/null 2>&1 && return
    else
      "$REDIS_CLI" -p "$port" ping >/dev/null 2>&1 && return
    fi
    sleep 0.1
  done
  die "server on port $port didn't start (see $STATE)"
}

stop_dir() { # dir
  local pidfile="$1/redis.pid"
  [[ -f "$pidfile" ]] || return 0
  local pid; pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; fi
  rm -f "$pidfile"
}

standalone() {
  case $1 in
    start) start_server standalone 6379 ;;
    stop) stop_dir "$STATE/standalone" ;;
    status) "$REDIS_CLI" -p 6379 info server | grep -E "redis_version|tcp_port" || echo "  not running" ;;
  esac
}

cluster() {
  case $1 in
    start)
      for port in "${CLUSTER_PORTS[@]}"; do
        start_server "cluster-$port" "$port" --cluster-enabled yes \
          --cluster-config-file "nodes-$port.conf" --cluster-node-timeout 5000
      done
      if ! "$REDIS_CLI" -p 30001 cluster info | grep -q "cluster_state:ok"; then
        "$REDIS_CLI" --cluster create "${CLUSTER_PORTS[@]/#/127.0.0.1:}" --cluster-replicas 1 --cluster-yes >/dev/null
        for _ in $(seq 1 50); do
          "$REDIS_CLI" -p 30001 cluster info | grep -q "cluster_state:ok" && break
          sleep 0.2
        done
      fi
      echo "  cluster: $("$REDIS_CLI" -p 30001 cluster info | grep cluster_state | tr -d '\r')"
      ;;
    stop)
      for port in "${CLUSTER_PORTS[@]}"; do stop_dir "$STATE/cluster-$port"; done
      rm -rf "$STATE"/cluster-*
      ;;
    status) "$REDIS_CLI" -p 30001 cluster nodes 2>/dev/null || echo "  not running" ;;
  esac
}

sentinel() {
  case $1 in
    start)
      start_server sentinel-primary 6390
      start_server sentinel-replica 6391 --replicaof 127.0.0.1 6390
      for port in 26379 26380 26381; do
        local dir="$STATE/sentinel-$port"
        mkdir -p "$dir"
        if [[ -f "$dir/redis.pid" ]] && kill -0 "$(cat "$dir/redis.pid")" 2>/dev/null; then continue; fi
        # Sentinel rewrites its config file, so each one gets its own writable copy.
        cat > "$dir/sentinel.conf" <<EOF
port $port
bind 127.0.0.1
daemonize yes
pidfile $dir/redis.pid
logfile $dir/redis.log
dir $dir
sentinel monitor redi-primary 127.0.0.1 6390 2
sentinel down-after-milliseconds redi-primary 5000
sentinel failover-timeout redi-primary 10000
sentinel parallel-syncs redi-primary 1
EOF
        "$REDIS_SERVER" "$dir/sentinel.conf" --sentinel
        wait_for "$port"
        echo "  sentinel listening on $port"
      done
      ;;
    stop)
      for name in sentinel-26379 sentinel-26380 sentinel-26381 sentinel-replica sentinel-primary; do stop_dir "$STATE/$name"; done
      rm -rf "$STATE"/sentinel-*
      ;;
    status) "$REDIS_CLI" -p 26379 sentinel get-master-addr-by-name redi-primary 2>/dev/null || echo "  not running" ;;
  esac
}

tls() {
  case $1 in
    start)
      [[ -f "$STATE/tls/server.crt" ]] || die "no certificates; run Scripts/gen-tls-certs.sh"
      start_server tls 6380 --port 0 --tls-port 6380 \
        --tls-cert-file "$STATE/tls/server.crt" --tls-key-file "$STATE/tls/server.key" \
        --tls-ca-cert-file "$STATE/tls/ca.crt" --tls-auth-clients optional
      ;;
    stop) stop_dir "$STATE/tls" ;;
    status) "$REDIS_CLI" -p 6380 --tls --cacert "$STATE/tls/ca.crt" ping 2>/dev/null || echo "  not running" ;;
  esac
}

topology=${1:-}
action=${2:-}
[[ "$action" =~ ^(start|stop|status)$ ]] || die "usage: $0 <standalone|cluster|sentinel|tls|all> <start|stop|status>"
case $topology in
  standalone|cluster|sentinel|tls) echo "$topology: $action"; "$topology" "$action" ;;
  all)
    for t in standalone cluster sentinel; do echo "$t: $action"; "$t" "$action"; done
    if [[ -f "$STATE/tls/server.crt" || "$action" != start ]]; then echo "tls: $action"; tls "$action"; fi
    ;;
  *) die "unknown topology '$topology'" ;;
esac
