#!/usr/bin/env bash
# scripts/install-server.sh
#
# 全新 Linux 服务器一键部署 ScopeSentry 服务端：
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/install-server.sh | bash
#
# 由 dev 机的 ./devctl server publish 推到 GHCR 的 scopesentry-server 镜像 + mongo + redis 起一套。
# Mongo / Redis 密码本地随机生成（32 字节），不再依赖 .env 模板写死的弱口令。
#
# 设计要点：
#   - 完全自包含：除 docker / docker compose v2 之外不再依赖项目其他文件
#   - 可重入：再次执行不会破坏既有数据库（密码从 /opt/scopesentry/.env 读回复用）
#   - 端口默认 Mongo 37017 / Redis 16379 / API 8082，避开公网爬虫常扫的默认值

set -euo pipefail

# ============================================================
# CONFIG: fork 之后改这里，commit 到 main 分支，然后用对应 raw URL 一键安装
# ============================================================
GHCR_OWNER="${GHCR_OWNER:-york-cmd}"
SERVER_REPO_NAME="${SERVER_REPO_NAME:-scopesentry-server}"
DEFAULT_IMAGE_TAG="${DEFAULT_IMAGE_TAG:-latest}"
# ============================================================

INSTALL_DIR="${SCOPESENTRY_INSTALL_DIR:-/opt/scopesentry}"
DATA_DIR="$INSTALL_DIR/data"
IMAGE_TAG="${SCOPESENTRY_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
SERVER_IMAGE="ghcr.io/${GHCR_OWNER}/${SERVER_REPO_NAME}:${IMAGE_TAG}"
MONGO_PORT_EXT="${MONGO_PORT_EXT:-37017}"
REDIS_PORT_EXT="${REDIS_PORT_EXT:-16379}"
API_PORT="${API_PORT:-8082}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

err() { printf '\033[31m[install-server]\033[0m %s\n' "$*" >&2; }
log() { printf '\033[32m[install-server]\033[0m %s\n' "$*"; }

# step 1: 依赖检查
log "1/8 检查依赖"
if [[ "$GHCR_OWNER" == "<your-github-username>" ]]; then
  err "脚本顶部的 GHCR_OWNER 还是占位符。fork 仓库后请把它改成你的 GitHub 用户名再 commit/push。"
  err "如果只是想临时跑通，可以：GHCR_OWNER=<your-name> curl ... | bash"
  exit 1
fi
command -v docker >/dev/null || { err "缺少 docker"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "缺少 docker compose v2（不是老的 docker-compose）"; exit 1; }
command -v curl >/dev/null || { err "缺少 curl"; exit 1; }

# step 2: 目录
log "2/8 准备目录 ${INSTALL_DIR}"
if ! sudo -n true 2>/dev/null && [[ ! -w "/opt" ]]; then
  err "需要 sudo 权限以在 /opt 下建目录。请用 sudo 跑或修改 SCOPESENTRY_INSTALL_DIR 指向有权限的位置。"
  exit 1
fi
sudo mkdir -p "${INSTALL_DIR}" \
              "${DATA_DIR}/mongodb" "${DATA_DIR}/redis" \
              "${DATA_DIR}/files" "${DATA_DIR}/images" "${DATA_DIR}/uploads"
sudo chown -R "$USER" "${INSTALL_DIR}"

# step 3: 密码（复用 or 新生成）
ENV_FILE="${INSTALL_DIR}/.env"
gen_pw() {
  # 32 字节，去掉斜杠/加号/等号，避免 YAML / shell 引用问题
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '/+=\n' | head -c 32
  else
    head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32
  fi
}

if [[ -f "$ENV_FILE" ]]; then
  log "3/8 检测到既有 ${ENV_FILE}，复用其中的密码（不会破坏既有数据库）"
  # shellcheck disable=SC1090
  set +u; source "$ENV_FILE"; set -u
fi
MONGO_INITDB_ROOT_USERNAME="${MONGO_INITDB_ROOT_USERNAME:-scopesentry}"
MONGO_INITDB_ROOT_PASSWORD="${MONGO_INITDB_ROOT_PASSWORD:-$(gen_pw)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(gen_pw)}"
if [[ ! -f "$ENV_FILE" ]]; then
  log "3/8 生成新的 Mongo / Redis 32 字节随机密码"
fi

# step 4: 写 .env
log "4/8 写 ${ENV_FILE}"
umask 077
cat > "$ENV_FILE" <<EOF
MONGO_INITDB_ROOT_USERNAME=${MONGO_INITDB_ROOT_USERNAME}
MONGO_INITDB_ROOT_PASSWORD=${MONGO_INITDB_ROOT_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
SERVER_IMAGE=${SERVER_IMAGE}
MONGO_PORT_EXT=${MONGO_PORT_EXT}
REDIS_PORT_EXT=${REDIS_PORT_EXT}
API_PORT=${API_PORT}
TIMEZONE=${TIMEZONE}
EOF
umask 022

# step 5: 写 compose
log "5/8 写 ${INSTALL_DIR}/docker-compose.yml"
cat > "${INSTALL_DIR}/docker-compose.yml" <<'YML'
networks:
  scopesentry-network:
    name: scopesentry-network
    driver: bridge

services:
  mongodb:
    image: mongo:7.0.28
    container_name: scopesentry-mongodb
    restart: always
    ports:
      - "${MONGO_PORT_EXT}:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_INITDB_ROOT_USERNAME}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_INITDB_ROOT_PASSWORD}
    volumes:
      - ./data/mongodb:/data/db
    healthcheck:
      test: ["CMD-SHELL", "mongosh --quiet -u \"$${MONGO_INITDB_ROOT_USERNAME}\" -p \"$${MONGO_INITDB_ROOT_PASSWORD}\" --authenticationDatabase admin --eval \"db.adminCommand({ ping: 1 })\" || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - scopesentry-network

  redis:
    image: redis:7.0.11
    container_name: scopesentry-redis
    restart: always
    ports:
      - "${REDIS_PORT_EXT}:6379"
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$${REDIS_PASSWORD}\" ping || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - scopesentry-network

  scope-sentry:
    image: ${SERVER_IMAGE}
    container_name: scope-sentry
    restart: always
    ports:
      - "${API_PORT}:8082"
    environment:
      TIMEZONE: ${TIMEZONE}
      MONGODB_IP: scopesentry-mongodb
      MONGODB_PORT: 27017
      MONGODB_DATABASE: ScopeSentry
      MONGODB_USER: ${MONGO_INITDB_ROOT_USERNAME}
      MONGODB_PASSWORD: ${MONGO_INITDB_ROOT_PASSWORD}
      REDIS_IP: scopesentry-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://127.0.0.1:8082 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
    depends_on:
      redis:
        condition: service_healthy
      mongodb:
        condition: service_healthy
    volumes:
      - ./data/files:/opt/ScopeSentry/files
      - ./data/images:/opt/ScopeSentry/images
      - ./data/uploads:/opt/ScopeSentry/uploads
    networks:
      - scopesentry-network
YML

# step 6: pull
log "6/8 docker pull ${SERVER_IMAGE}"
docker pull "$SERVER_IMAGE"

# step 7: up
log "7/8 docker compose up -d"
( cd "${INSTALL_DIR}" && docker compose --env-file .env up -d )

# step 8: 等首次 PASSWORD
log "8/8 等待服务端首次初始化（最多 90 秒）"
admin_password=""
for _ in $(seq 1 18); do
  sleep 5
  if docker exec scope-sentry test -f /opt/ScopeSentry/PASSWORD 2>/dev/null; then
    admin_password="$(docker exec scope-sentry cat /opt/ScopeSentry/PASSWORD 2>/dev/null || true)"
    if [[ -n "$admin_password" ]]; then
      docker cp scope-sentry:/opt/ScopeSentry/PASSWORD "${INSTALL_DIR}/PASSWORD" >/dev/null 2>&1 || true
      sudo chmod 600 "${INSTALL_DIR}/PASSWORD" 2>/dev/null || true
      break
    fi
  fi
done

# 同样捞 PLUGINKEY 出来便于后续节点 enrollment 使用
if docker exec scope-sentry test -f /opt/ScopeSentry/PLUGINKEY 2>/dev/null; then
  docker cp scope-sentry:/opt/ScopeSentry/PLUGINKEY "${INSTALL_DIR}/PLUGINKEY" >/dev/null 2>&1 || true
  sudo chmod 600 "${INSTALL_DIR}/PLUGINKEY" 2>/dev/null || true
fi

host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$host_ip" ]] || host_ip="<server-public-ip>"

if [[ -z "$admin_password" ]]; then
  cat <<TIP

⚠ 90 秒内没有读到 PASSWORD 文件。两种可能：
  1. 这台机器之前装过 ScopeSentry，admin 用户已存在，不会再生成首次密码
  2. 服务起得慢，看 docker logs scope-sentry 是不是还在初始化

如果是 #1 但忘了密码：在 dev 机跑
  ./devctl deploy reset-password <new-password>

如果是 #2，过一会再：
  docker exec scope-sentry cat /opt/ScopeSentry/PASSWORD

TIP
else
  cat <<DONE

============================================================
✓ 部署完成
============================================================

访问地址：http://${host_ip}:${API_PORT}
登录用户：ScopeSentry
登录密码：${admin_password}

凭据已持久化到（mode 600）：
  ${INSTALL_DIR}/PASSWORD            # 首次 admin 密码
  ${INSTALL_DIR}/PLUGINKEY           # 插件 key
  ${INSTALL_DIR}/.env                # Mongo / Redis / 镜像 tag

数据目录：${DATA_DIR}/{mongodb,redis,files,images,uploads}

下一步：
  1. 进 UI 改首次密码（系统设置 → 修改密码）
  2. 把 .env 里的 Mongo/Redis 密码补到服务端 config.yaml 的 node_bootstrap section
     （用于扫描节点 enrollment，详见 DEPLOY_NODE.md）
  3. UI 节点页 → "添加节点" 即可拉起远端扫描节点

防火墙记得只对扫描节点 IP 放行：
  - Mongo 端口：${MONGO_PORT_EXT}
  - Redis 端口：${REDIS_PORT_EXT}

DONE
fi
