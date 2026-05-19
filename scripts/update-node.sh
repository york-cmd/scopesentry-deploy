#!/usr/bin/env bash
# scopesentry node 更新脚本 —— 在节点上跑，从 GHCR 拉最新 scan 镜像并重启容器
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-node.sh | bash
# 或直接：
#   bash scripts/update-node.sh
#
# 假设节点已经通过 install-node.sh 装好，/etc/scopesentry-node/{node.env,docker-compose.yml} 存在。
set -euo pipefail

ETC_DIR="${SCOPESENTRY_NODE_ETC_DIR:-/etc/scopesentry-node}"
CONTAINER_NAME="${SCOPESENTRY_NODE_CONTAINER_NAME:-scopesentry-scan}"

err() { printf '\033[31m[update-node]\033[0m %s\n' "$*" >&2; }
log() { printf '\033[32m[update-node]\033[0m %s\n' "$*"; }

if [[ ! -f "$ETC_DIR/docker-compose.yml" || ! -f "$ETC_DIR/node.env" ]]; then
  err "$ETC_DIR 不存在配置文件。这台机器还没装过节点，请先到 UI 生成 install 命令并运行。"
  exit 1
fi

log "1/3 docker compose pull"
( cd "$ETC_DIR" && docker compose --env-file node.env pull )

log "2/3 docker compose up -d（拉新镜像后重启）"
( cd "$ETC_DIR" && docker compose --env-file node.env up -d --force-recreate )

log "3/3 检查容器状态"
sleep 3
if docker ps --format '{{.Names}}\t{{.Status}}' | grep -q "^${CONTAINER_NAME}"; then
  log "完成：$(docker ps --format '{{.Names}}\t{{.Status}}' | grep "^${CONTAINER_NAME}")"
  log "看日志：docker logs -f $CONTAINER_NAME"
else
  err "容器没起来。看日志定位："
  docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
  exit 1
fi
