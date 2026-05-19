#!/usr/bin/env bash
# scopesentry server 更新脚本 —— 在服务器上跑，从 GHCR 拉最新 server 镜像并重启容器
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-server.sh | bash
# 或带版本：
#   SCOPESENTRY_IMAGE_TAG=v2026.06.01 curl -fsSL .../update-server.sh | bash
# 或直接：
#   bash scripts/update-server.sh
#
# 假设服务器已经通过 install-server.sh 装好，/opt/scopesentry/{.env,docker-compose.yml} 存在。
# 数据库密码不变，admin 账户不变。
set -euo pipefail

INSTALL_DIR="${SCOPESENTRY_INSTALL_DIR:-/opt/scopesentry}"

err() { printf '\033[31m[update-server]\033[0m %s\n' "$*" >&2; }
log() { printf '\033[32m[update-server]\033[0m %s\n' "$*"; }

if [[ ! -f "$INSTALL_DIR/docker-compose.yml" || ! -f "$INSTALL_DIR/.env" ]]; then
  err "$INSTALL_DIR 不存在配置文件。这台机器还没装过服务端，请先跑 install-server.sh。"
  exit 1
fi

# 如果传了 SCOPESENTRY_IMAGE_TAG，覆盖 .env 里的 SERVER_IMAGE 行
if [[ -n "${SCOPESENTRY_IMAGE_TAG:-}" ]]; then
  source "$INSTALL_DIR/.env"
  # 拆出 owner / repo，仅替换 tag
  base="${SERVER_IMAGE%:*}"
  new_image="${base}:${SCOPESENTRY_IMAGE_TAG}"
  log "切换镜像 tag → $new_image"
  if grep -q '^SERVER_IMAGE=' "$INSTALL_DIR/.env"; then
    sed -i.bak "s|^SERVER_IMAGE=.*|SERVER_IMAGE=${new_image}|" "$INSTALL_DIR/.env"
    rm -f "$INSTALL_DIR/.env.bak"
  fi
fi

log "1/3 docker compose pull"
( cd "$INSTALL_DIR" && docker compose --env-file .env pull )

log "2/3 docker compose up -d（拉新镜像后重启）"
( cd "$INSTALL_DIR" && docker compose --env-file .env up -d --force-recreate )

log "3/3 检查容器状态"
sleep 5
docker compose --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/docker-compose.yml" ps || true

cat <<DONE
完成。

如果改了 SERVER_IMAGE，admin 密码、Mongo/Redis 密码都不变（在 .env 里复用）。
看 server 日志：
  docker logs -f scope-sentry
DONE
