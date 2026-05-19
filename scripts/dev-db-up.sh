#!/usr/bin/env bash
# 内部 helper：由 dev-smoke.sh 和 dev-scan-docker.sh 调用以确保 MongoDB/Redis 在线。
# 单独使用请优先 ./devctl up（会复用同一份 docker-compose）。
set -euo pipefail

ROOT_DIR="${DEVCTL_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SERVER_DIR="$ROOT_DIR/ScopeSentry"
ACTION="${1:-up}"

cd "$SERVER_DIR"

case "$ACTION" in
  up)
    docker compose -f single-host-deployment.yml up -d mongodb redis
    echo "MongoDB is expected on 127.0.0.1:27017"
    echo "Redis is expected on 127.0.0.1:6379"
    ;;
  down)
    docker compose -f single-host-deployment.yml stop mongodb redis
    ;;
  ps)
    docker compose -f single-host-deployment.yml ps mongodb redis
    ;;
  logs)
    docker compose -f single-host-deployment.yml logs -f mongodb redis
    ;;
  *)
    echo "Usage: $0 [up|down|ps|logs]"
    exit 1
    ;;
esac
