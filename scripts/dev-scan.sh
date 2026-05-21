#!/usr/bin/env bash
# 内部 helper：由 dev-smoke.sh 在 SCAN_DRIVER=host 时调用，单独使用请优先 ./devctl up。
# 注意：这是直接在宿主机上跑扫描端的旧路径，macOS 上 masscan 等工具兼容性差。
set -euo pipefail

ROOT_DIR="${DEVCTL_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCAN_DIR="$ROOT_DIR/ScopeSentry-Scan"
SERVER_DIR="$ROOT_DIR/ScopeSentry"
LOCAL_DEV_DIR="${LOCAL_DEV_DIR:-$ROOT_DIR/.local-dev}"
CACHE_DIR="${CACHE_DIR:-$LOCAL_DEV_DIR/cache}"
RUNTIME_DIR="${SCAN_RUNTIME_DIR:-$LOCAL_DEV_DIR/runtime/scan-host}"
GO_CACHE_DIR="${GO_CACHE_DIR:-$CACHE_DIR/go-build/scope-scan}"
GO_MOD_CACHE_DIR="${GO_MOD_CACHE_DIR:-$CACHE_DIR/go-mod}"

cd "$SERVER_DIR"

if [[ ! -f .env ]]; then
  echo "Missing $SERVER_DIR/.env"
  exit 1
fi

set -a
source ./.env
set +a

cd "$SCAN_DIR"
mkdir -p "$RUNTIME_DIR"
mkdir -p "$GO_CACHE_DIR"
mkdir -p "$GO_MOD_CACHE_DIR"

GOCACHE="$GO_CACHE_DIR" GOMODCACHE="$GO_MOD_CACHE_DIR" \
  go build -o "$RUNTIME_DIR/scopesentry-scan-dev" ./cmd/ScopeSentry/main.go

exec env \
  NodeName="${NODE_NAME:-${NodeName:-local-dev-node}}" \
  TimeZoneName="${TimeZoneName:-Asia/Shanghai}" \
  MONGODB_IP="${MONGODB_IP:-127.0.0.1}" \
  MONGODB_PORT="${MONGODB_PORT:-27017}" \
  MONGODB_DATABASE="${MONGODB_DATABASE:-ScopeSentry}" \
  MONGODB_USER="${MONGODB_USER:-${MONGO_INITDB_ROOT_USERNAME:-admin}}" \
  MONGODB_PASSWORD="${MONGODB_PASSWORD:-${MONGO_INITDB_ROOT_PASSWORD:-mongodb_password}}" \
  REDIS_IP="${REDIS_IP:-127.0.0.1}" \
  REDIS_PORT="${REDIS_PORT:-6379}" \
  REDIS_PASSWORD="${REDIS_PASSWORD:-redis_password}" \
  INTERACTSH_URL="${INTERACTSH_URL:-}" \
  INTERACTSH_TOKEN="${INTERACTSH_TOKEN:-}" \
  NUCLEI_DEBUG="${NUCLEI_DEBUG:-}" \
  NUCLEI_STATS="${NUCLEI_STATS:-}" \
  NUCLEI_STATS_INTERVAL="${NUCLEI_STATS_INTERVAL:-}" \
  NUCLEI_DEBUG_REQUEST="${NUCLEI_DEBUG_REQUEST:-}" \
  NUCLEI_DEBUG_RESPONSE="${NUCLEI_DEBUG_RESPONSE:-}" \
  NUCLEI_TASK_ENGINE_TRACE="${NUCLEI_TASK_ENGINE_TRACE:-}" \
  "$RUNTIME_DIR/scopesentry-scan-dev"
