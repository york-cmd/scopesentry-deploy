#!/usr/bin/env bash
# 内部 helper：由 dev-smoke.sh 调用，单独使用请优先 ./devctl up（或 ./devctl restart server）。
# 这里保留是为了让 smoke 链路在不依赖 devctl 守护进程逻辑的前提下也能直接启动后端。
set -euo pipefail

ROOT_DIR="${DEVCTL_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SERVER_DIR="$ROOT_DIR/ScopeSentry"
LOCAL_DEV_DIR="${LOCAL_DEV_DIR:-$ROOT_DIR/.local-dev}"
CACHE_DIR="${CACHE_DIR:-$LOCAL_DEV_DIR/cache}"
RUNTIME_DIR="${SERVER_RUNTIME_DIR:-$LOCAL_DEV_DIR/runtime/server}"
GO_CACHE_DIR="${GO_CACHE_DIR:-$CACHE_DIR/go-build/scope-sentry}"
GO_MOD_CACHE_DIR="${GO_MOD_CACHE_DIR:-$CACHE_DIR/go-mod}"

cd "$SERVER_DIR"

if [[ ! -f .env ]]; then
  echo "Missing $SERVER_DIR/.env"
  exit 1
fi

set -a
source ./.env
set +a

mkdir -p "$RUNTIME_DIR"
mkdir -p "$GO_CACHE_DIR"
mkdir -p "$GO_MOD_CACHE_DIR"

GOCACHE="$GO_CACHE_DIR" GOMODCACHE="$GO_MOD_CACHE_DIR" \
  go build -o "$RUNTIME_DIR/scope-sentry-dev" ./cmd/main

exec env \
  TIMEZONE="${TIMEZONE:-Asia/Shanghai}" \
  MONGODB_IP="${MONGODB_IP:-127.0.0.1}" \
  MONGODB_PORT="${MONGODB_PORT:-27017}" \
  MONGODB_DATABASE="${MONGODB_DATABASE:-ScopeSentry}" \
  MONGODB_USER="${MONGODB_USER:-${MONGO_INITDB_ROOT_USERNAME:-admin}}" \
  MONGODB_PASSWORD="${MONGODB_PASSWORD:-${MONGO_INITDB_ROOT_PASSWORD:-mongodb_password}}" \
  REDIS_IP="${REDIS_IP:-127.0.0.1}" \
  REDIS_PORT="${REDIS_PORT:-6379}" \
  REDIS_PASSWORD="${REDIS_PASSWORD:-redis_password}" \
  "$RUNTIME_DIR/scope-sentry-dev"
