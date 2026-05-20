#!/usr/bin/env bash
# scripts/install-server.sh
#
# ScopeSentry 服务端一键安装 + 管理菜单。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/install-server.sh | bash
#   或 bash <(curl -fsSL .../install-server.sh)
#
# 行为：
#   - /opt/scopesentry/.env 不存在     → 首次安装
#   - /opt/scopesentry/.env 已存在     → 弹出管理菜单（升级 / 卸载 / 重启 / 状态）
#
# 非交互参数（脚本化调用 / 兼容老 raw URL wrapper）：
#   --upgrade     直接执行升级分支
#   --uninstall   进入卸载流程（仍保留二次确认）
#   --restart     执行 docker compose restart
#   --status      打印状态后退出
#
# 设计要点：
#   - 完全自包含：除 docker / docker compose v2 之外不再依赖项目其他文件
#   - 可重入：再次执行不会破坏既有数据库（密码从 /opt/scopesentry/.env 读回复用）
#   - 端口默认 Mongo 37017 / Redis 16379 / API 8082，避开公网爬虫常扫的默认值
#   - 升级分支会先把自身 curl 覆盖到 /opt/scopesentry/install-server.sh，便于离线 ssh 复跑
set -euo pipefail

# ============================================================
# CONFIG: fork 之后改这里，commit 到 main 分支，然后用对应 raw URL 一键安装
# ============================================================
GHCR_OWNER="${GHCR_OWNER:-york-cmd}"
SERVER_REPO_NAME="${SERVER_REPO_NAME:-scopesentry-server}"
DEFAULT_IMAGE_TAG="${DEFAULT_IMAGE_TAG:-latest}"
DEPLOY_REPO_OWNER="${DEPLOY_REPO_OWNER:-york-cmd}"
DEPLOY_REPO_NAME="${DEPLOY_REPO_NAME:-scopesentry-deploy}"
DEPLOY_REPO_BRANCH="${DEPLOY_REPO_BRANCH:-main}"
# ============================================================

INSTALL_DIR="${SCOPESENTRY_INSTALL_DIR:-/opt/scopesentry}"
DATA_DIR="$INSTALL_DIR/data"
IMAGE_TAG="${SCOPESENTRY_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
SERVER_IMAGE="ghcr.io/${GHCR_OWNER}/${SERVER_REPO_NAME}:${IMAGE_TAG}"
MONGO_PORT_EXT="${MONGO_PORT_EXT:-37017}"
REDIS_PORT_EXT="${REDIS_PORT_EXT:-16379}"
API_PORT="${API_PORT:-8082}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

SELF_RAW_URL="https://raw.githubusercontent.com/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/${DEPLOY_REPO_BRANCH}/scripts/install-server.sh"
SELF_LOCAL_PATH="${INSTALL_DIR}/install-server.sh"

ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

err()  { printf '\033[31m[install-server]\033[0m %s\n' "$*" >&2; }
log()  { printf '\033[32m[install-server]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[install-server]\033[0m %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null || { err "缺少依赖：$1"; exit 1; }
}

ensure_docker_stack() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || { err "缺少 docker compose v2（不是老的 docker-compose）"; exit 1; }
  require_cmd curl
}

# ============================================================
# 安装流程
# ============================================================
run_install() {
  log "1/8 检查依赖"
  if [[ "$GHCR_OWNER" == "<your-github-username>" ]]; then
    err "脚本顶部的 GHCR_OWNER 还是占位符。fork 仓库后请把它改成你的 GitHub 用户名再 commit/push。"
    err "如果只是想临时跑通，可以：GHCR_OWNER=<your-name> curl ... | bash"
    exit 1
  fi
  ensure_docker_stack

  log "2/8 准备目录 ${INSTALL_DIR}"
  if ! sudo -n true 2>/dev/null && [[ ! -w "/opt" ]]; then
    err "需要 sudo 权限以在 /opt 下建目录。请用 sudo 跑或修改 SCOPESENTRY_INSTALL_DIR 指向有权限的位置。"
    exit 1
  fi
  sudo mkdir -p "${INSTALL_DIR}" \
                "${DATA_DIR}/mongodb" "${DATA_DIR}/redis" \
                "${DATA_DIR}/files" "${DATA_DIR}/images" "${DATA_DIR}/uploads"
  sudo chown -R "$USER" "${INSTALL_DIR}"

  local MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD REDIS_PASSWORD
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

  log "5/8 写 ${COMPOSE_FILE}"
  write_compose_yml

  log "6/8 docker pull ${SERVER_IMAGE}"
  docker pull "$SERVER_IMAGE"

  log "7/8 docker compose up -d"
  ( cd "${INSTALL_DIR}" && docker compose --env-file .env up -d )

  log "8/8 等待服务端首次初始化（最多 90 秒）"
  local admin_password=""
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

  if docker exec scope-sentry test -f /opt/ScopeSentry/PLUGINKEY 2>/dev/null; then
    docker cp scope-sentry:/opt/ScopeSentry/PLUGINKEY "${INSTALL_DIR}/PLUGINKEY" >/dev/null 2>&1 || true
    sudo chmod 600 "${INSTALL_DIR}/PLUGINKEY" 2>/dev/null || true
  fi

  local host_ip
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

后续运维：
  bash <(curl -fsSL ${SELF_RAW_URL})           # 弹管理菜单

DONE
  fi
}

gen_pw() {
  # 32 字节，去掉斜杠/加号/等号，避免 YAML / shell 引用问题
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '/+=\n' | head -c 32
  else
    head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32
  fi
}

write_compose_yml() {
  cat > "${COMPOSE_FILE}" <<'YML'
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
}

# ============================================================
# 管理子命令
# ============================================================
read_server_image_tag() {
  # 从 .env 里读 SERVER_IMAGE 推断 tag
  local image
  image="$(awk -F= '/^SERVER_IMAGE=/ {print $2}' "$ENV_FILE" 2>/dev/null || true)"
  if [[ -n "$image" ]]; then
    printf '%s' "${image##*:}"
  else
    printf 'unknown'
  fi
}

get_container_state() {
  # echo "running" / "stopped" / "absent"
  local name="$1"
  if docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null | grep -q '^running$'; then
    echo running
  elif docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null >/dev/null; then
    echo stopped
  else
    echo absent
  fi
}

self_update() {
  # 把自己 curl 到 /opt/scopesentry/install-server.sh，便于离线 ssh 复跑
  log "更新本地脚本副本到最新版本 → ${SELF_LOCAL_PATH}"
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL "$SELF_RAW_URL" -o "$tmp"; then
    sudo mkdir -p "$INSTALL_DIR" >/dev/null 2>&1 || true
    sudo mv "$tmp" "$SELF_LOCAL_PATH"
    sudo chmod 755 "$SELF_LOCAL_PATH"
  else
    rm -f "$tmp"
    warn "无法从 $SELF_RAW_URL 拉脚本副本，跳过自更新（不影响升级本身）"
  fi
}

do_upgrade() {
  ensure_docker_stack
  self_update
  log "拉取最新镜像"
  ( cd "${INSTALL_DIR}" && docker compose --env-file .env pull )
  log "重建容器（force-recreate）"
  ( cd "${INSTALL_DIR}" && docker compose --env-file .env up -d --force-recreate )
  log "升级完成。看日志：docker logs -f scope-sentry"
}

do_restart() {
  ensure_docker_stack
  log "docker compose restart"
  ( cd "${INSTALL_DIR}" && docker compose --env-file .env restart )
  log "重启完成"
}

do_status() {
  ensure_docker_stack
  echo
  printf '\033[36m=== 容器状态 ===\033[0m\n'
  ( cd "${INSTALL_DIR}" && docker compose --env-file .env ps ) || true
  echo
  printf '\033[36m=== API 健康检查 ===\033[0m\n'
  local api_port
  api_port="$(awk -F= '/^API_PORT=/ {print $2}' "$ENV_FILE" 2>/dev/null || echo 8082)"
  if curl -fsS "http://127.0.0.1:${api_port}/api/health" 2>/dev/null; then
    echo
  else
    warn "GET /api/health 失败（可能容器还在启动 或 API 路径未实现）"
  fi
  echo
  printf '\033[36m=== 凭据文件 ===\033[0m\n'
  for f in PASSWORD PLUGINKEY .env; do
    if [[ -f "${INSTALL_DIR}/$f" ]]; then
      printf '  %s\n' "${INSTALL_DIR}/$f"
    fi
  done
  echo
}

do_uninstall() {
  ensure_docker_stack
  while true; do
    cat <<MENU

卸载 ScopeSentry 服务端
  [1] 保留数据：停容器、删容器、删镜像；保留 ${INSTALL_DIR}/
  [2] 彻底卸载：连 ${INSTALL_DIR}/ 一起删（不可恢复）
  [0] 返回上级
MENU
    local choice
    read -r -p "请选择: " choice </dev/tty
    case "$choice" in
      1) do_uninstall_keep_data && return 0 ;;
      2) do_uninstall_purge && return 0 ;;
      0) return 0 ;;
      *) warn "非法选项：$choice" ;;
    esac
  done
}

current_server_image() {
  awk -F= '/^SERVER_IMAGE=/ {print $2}' "$ENV_FILE" 2>/dev/null || echo "$SERVER_IMAGE"
}

do_uninstall_keep_data() {
  local image
  image="$(current_server_image)"
  cat <<PLAN

将执行：
  - docker compose down
  - docker rmi ${image}
  - 保留 ${INSTALL_DIR}/{.env, docker-compose.yml, PASSWORD, PLUGINKEY, data/}

PLAN
  local confirm
  read -r -p "继续？(yes/no): " confirm </dev/tty
  if [[ "$confirm" != "yes" ]]; then
    warn "已取消"
    return 1
  fi
  log "docker compose down"
  ( cd "${INSTALL_DIR}" && docker compose --env-file .env down ) || true
  log "docker rmi ${image}"
  docker rmi "$image" 2>/dev/null || true
  log "保留数据卸载完成。重新部署可再次跑本脚本。"
}

do_uninstall_purge() {
  local image
  image="$(current_server_image)"
  printf '\033[31m\n⚠️  将执行（不可恢复）：\033[0m\n'
  cat <<PLAN
  - docker compose down -v
  - docker rmi ${image} mongo:7.0.28 redis:7.0.11
  - sudo rm -rf ${INSTALL_DIR}
所有数据库数据、上传文件、admin 密码都会丢失。

PLAN
  local confirm
  read -r -p '继续？请输入 "DELETE EVERYTHING" 确认: ' confirm </dev/tty
  if [[ "$confirm" != "DELETE EVERYTHING" ]]; then
    warn "未输入正确确认串，已取消"
    return 1
  fi
  log "docker compose down -v"
  ( cd "${INSTALL_DIR}" && docker compose --env-file .env down -v ) || true
  log "docker rmi ${image} mongo:7.0.28 redis:7.0.11"
  docker rmi "$image" mongo:7.0.28 redis:7.0.11 2>/dev/null || true
  log "sudo rm -rf ${INSTALL_DIR}"
  sudo rm -rf "${INSTALL_DIR}"
  log "彻底卸载完成"
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
  ensure_docker_stack
  while true; do
    local tag state
    tag="$(read_server_image_tag)"
    state="$(get_container_state scope-sentry)"
    cat <<MENU

============================================================
ScopeSentry 服务端已安装在 ${INSTALL_DIR}
镜像 tag：${tag}   容器状态：${state}
============================================================
  [1] 升级 (拉最新镜像 + 重启)
  [2] 卸载
  [3] 重启
  [4] 查看状态
  [0] 退出
MENU
    local choice
    read -r -p "请选择: " choice </dev/tty || { echo; return 0; }
    case "$choice" in
      1) do_upgrade ;;
      2) do_uninstall ;;
      3) do_restart ;;
      4) do_status ;;
      0) log "退出"; return 0 ;;
      *) warn "非法选项：$choice" ;;
    esac
  done
}

# ============================================================
# 入口
# ============================================================
ACTION="${SCOPESENTRY_ACTION:-}"
while (( $# > 0 )); do
  case "$1" in
    --upgrade)   ACTION="upgrade"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --restart)   ACTION="restart"; shift ;;
    --status)    ACTION="status"; shift ;;
    --help|-h)
      sed -n '2,20p' "$0" 2>/dev/null || true
      exit 0
      ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

if [[ -n "$ACTION" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    err "${ENV_FILE} 不存在：这台机器还没装过服务端。先裸 curl 跑一次本脚本完成首装。"
    exit 1
  fi
  ensure_docker_stack
  case "$ACTION" in
    upgrade)   do_upgrade ;;
    uninstall) do_uninstall ;;
    restart)   do_restart ;;
    status)    do_status ;;
  esac
  exit 0
fi

if [[ -f "$ENV_FILE" ]]; then
  show_menu
else
  run_install
fi
