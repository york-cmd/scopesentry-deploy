#!/usr/bin/env bash
# scripts/manage-node.sh
#
# ScopeSentry 扫描节点本地管理菜单。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/manage-node.sh | bash
#   或 bash <(curl -fsSL .../manage-node.sh)
#
# 行为：
#   - /etc/scopesentry-node/node.env 不存在 → 提示去服务端 UI 添加节点
#   - 已存在 → 弹出管理菜单（升级 / 卸载 / 重启 / 状态）
#
# 非交互参数（脚本化调用 / 兼容老 raw URL wrapper）：
#   --upgrade     直接执行升级分支
#   --uninstall   进入卸载流程（仍保留二次确认）
#   --restart     执行 docker compose restart
#   --status      打印状态后退出
set -euo pipefail

# ============================================================
# CONFIG
# ============================================================
DEPLOY_REPO_OWNER="${DEPLOY_REPO_OWNER:-york-cmd}"
DEPLOY_REPO_NAME="${DEPLOY_REPO_NAME:-scopesentry-deploy}"
DEPLOY_REPO_BRANCH="${DEPLOY_REPO_BRANCH:-main}"
# ============================================================

ETC_DIR="${SCOPESENTRY_NODE_ETC_DIR:-/etc/scopesentry-node}"
DATA_DIR="${SCOPESENTRY_NODE_DATA_DIR:-/opt/scopesentry-scan}"
CONTAINER_NAME="${SCOPESENTRY_NODE_CONTAINER_NAME:-scopesentry-scan}"
NODE_ENV_FILE="${ETC_DIR}/node.env"
COMPOSE_FILE="${ETC_DIR}/docker-compose.yml"

SELF_RAW_URL="https://raw.githubusercontent.com/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/${DEPLOY_REPO_BRANCH}/scripts/manage-node.sh"
SELF_LOCAL_PATH="${ETC_DIR}/manage-node.sh"

err()  { printf '\033[31m[manage-node]\033[0m %s\n' "$*" >&2; }
log()  { printf '\033[32m[manage-node]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[manage-node]\033[0m %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null || { err "缺少依赖：$1"; exit 1; }
}

ensure_docker_stack() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || { err "缺少 docker compose v2（不是老的 docker-compose）"; exit 1; }
  require_cmd curl
}

# ============================================================
# 读取节点信息
# ============================================================
read_env_value() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$NODE_ENV_FILE" 2>/dev/null
}

read_node_name() { read_env_value NodeName; }
read_scan_image() { read_env_value SCAN_IMAGE; }

read_scan_image_tag() {
  local image
  image="$(read_scan_image)"
  if [[ -n "$image" ]]; then
    printf '%s' "${image##*:}"
  else
    printf 'unknown'
  fi
}

get_container_state() {
  if docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null | grep -q '^running$'; then
    echo running
  elif docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null >/dev/null; then
    echo stopped
  else
    echo absent
  fi
}

last_heartbeat_hint() {
  # 节点本地拿不到服务端记录的心跳时间，只能从 docker logs 推断最近一次活动。
  local last
  last="$(docker logs --tail 1 --timestamps "$CONTAINER_NAME" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "$last" ]]; then
    printf '%s' "$last"
  else
    printf '(无日志)'
  fi
}

# ============================================================
# 自更新
# ============================================================
self_update() {
  log "更新本地脚本副本到最新版本 → ${SELF_LOCAL_PATH}"
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL "$SELF_RAW_URL" -o "$tmp"; then
    sudo mkdir -p "$ETC_DIR" >/dev/null 2>&1 || true
    sudo mv "$tmp" "$SELF_LOCAL_PATH"
    sudo chmod 755 "$SELF_LOCAL_PATH"
  else
    rm -f "$tmp"
    warn "无法从 $SELF_RAW_URL 拉脚本副本，跳过自更新（不影响升级本身）"
  fi
}

# ============================================================
# 子命令
# ============================================================
do_upgrade() {
  ensure_docker_stack
  self_update
  log "拉取最新 scan 镜像"
  ( cd "$ETC_DIR" && docker compose --env-file node.env pull )
  log "重建容器（force-recreate）"
  ( cd "$ETC_DIR" && docker compose --env-file node.env up -d --force-recreate )
  log "升级完成。看日志：docker logs -f $CONTAINER_NAME"
}

do_restart() {
  ensure_docker_stack
  log "docker compose restart"
  ( cd "$ETC_DIR" && docker compose --env-file node.env restart )
  log "重启完成"
}

do_status() {
  ensure_docker_stack
  echo
  printf '\033[36m=== 节点信息 ===\033[0m\n'
  printf '  节点名     : %s\n' "$(read_node_name)"
  printf '  镜像 tag   : %s\n' "$(read_scan_image_tag)"
  printf '  容器状态   : %s\n' "$(get_container_state)"
  printf '  最近日志   : %s\n' "$(last_heartbeat_hint)"
  echo
  printf '\033[36m=== 容器 ===\033[0m\n'
  docker ps --filter "name=^${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
  echo
  printf '\033[36m=== 最近 20 行日志 ===\033[0m\n'
  docker logs --tail 20 "$CONTAINER_NAME" 2>&1 || true
  echo
}

do_uninstall() {
  ensure_docker_stack
  while true; do
    cat <<MENU

卸载 ScopeSentry 扫描节点
  [1] 保留配置：停容器、删容器、删镜像；保留 ${ETC_DIR}/ 和 ${DATA_DIR}/{logs,cache}
  [2] 彻底卸载：连 ${ETC_DIR}/ 和 ${DATA_DIR}/ 一起删（不可恢复）
  [0] 返回上级
MENU
    local choice
    read -r -p "请选择: " choice </dev/tty
    case "$choice" in
      1) do_uninstall_keep && return 0 ;;
      2) do_uninstall_purge && return 0 ;;
      0) return 0 ;;
      *) warn "非法选项：$choice" ;;
    esac
  done
}

do_uninstall_keep() {
  local image
  image="$(read_scan_image)"
  cat <<PLAN

将执行：
  - docker compose down
  - docker rmi ${image:-<scan-image>}
  - 保留 ${ETC_DIR}/ 和 ${DATA_DIR}/{logs,cache}

PLAN
  local confirm
  read -r -p "继续？(yes/no): " confirm </dev/tty
  if [[ "$confirm" != "yes" ]]; then
    warn "已取消"
    return 1
  fi
  log "docker compose down"
  ( cd "$ETC_DIR" && docker compose --env-file node.env down ) || true
  if [[ -n "$image" ]]; then
    log "docker rmi $image"
    docker rmi "$image" 2>/dev/null || true
  fi
  log "保留配置卸载完成。重新装节点请去服务端 UI 重新生成 install 命令。"
}

do_uninstall_purge() {
  local image
  image="$(read_scan_image)"
  printf '\033[31m\n⚠️  将执行（不可恢复）：\033[0m\n'
  cat <<PLAN
  - docker compose down -v
  - docker rmi ${image:-<scan-image>}
  - sudo rm -rf ${ETC_DIR} ${DATA_DIR}
  - docker network rm scopesentry-network（如果存在）
所有节点配置（含 PluginKey）、本地缓存和日志都会丢失。

PLAN
  local confirm
  read -r -p '继续？请输入 "DELETE EVERYTHING" 确认: ' confirm </dev/tty
  if [[ "$confirm" != "DELETE EVERYTHING" ]]; then
    warn "未输入正确确认串，已取消"
    return 1
  fi
  log "docker compose down -v"
  ( cd "$ETC_DIR" && docker compose --env-file node.env down -v ) || true
  if [[ -n "$image" ]]; then
    log "docker rmi $image"
    docker rmi "$image" 2>/dev/null || true
  fi
  log "sudo rm -rf ${ETC_DIR} ${DATA_DIR}"
  sudo rm -rf "$ETC_DIR" "$DATA_DIR"
  log "docker network rm scopesentry-network"
  docker network rm scopesentry-network 2>/dev/null || true
  log "彻底卸载完成"
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
  ensure_docker_stack
  while true; do
    local node tag state hb
    node="$(read_node_name)"
    tag="$(read_scan_image_tag)"
    state="$(get_container_state)"
    hb="$(last_heartbeat_hint)"
    cat <<MENU

============================================================
ScopeSentry 扫描节点已安装在 ${ETC_DIR}
节点名：${node:-(未知)}   状态：${state}   最近活动：${hb}
镜像 tag：${tag}
============================================================
  [1] 升级 (拉最新 scan 镜像 + 重启)
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

print_install_hint() {
  cat <<HINT
这台机器还没装过扫描节点（${NODE_ENV_FILE} 不存在）。

请到服务端 UI → 节点管理 → 添加节点，
复制生成的 curl 命令在这台机器上跑（带一次性 token 的那条）。
HINT
}

# ============================================================
# 入口
# ============================================================
ACTION="${SCOPESENTRY_NODE_ACTION:-}"
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

if [[ ! -f "$NODE_ENV_FILE" ]]; then
  print_install_hint
  exit 1
fi

if [[ -n "$ACTION" ]]; then
  ensure_docker_stack
  case "$ACTION" in
    upgrade)   do_upgrade ;;
    uninstall) do_uninstall ;;
    restart)   do_restart ;;
    status)    do_status ;;
  esac
  exit 0
fi

show_menu
