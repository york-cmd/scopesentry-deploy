#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${SCOPESENTRY_INSTALL_DIR:-/opt/scopesentry}"
SERVER_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
SERVER_ENV_FILE="${INSTALL_DIR}/.env"
SERVER_CONTAINER_NAME="${SCOPESENTRY_SERVER_CONTAINER_NAME:-scope-sentry}"
SERVER_SERVICE_NAME="${SCOPESENTRY_SERVER_SERVICE_NAME:-scope-sentry}"

NODE_ETC_DIR="${SCOPESENTRY_NODE_ETC_DIR:-/etc/scopesentry-node}"
NODE_DATA_DIR="${SCOPESENTRY_NODE_DATA_DIR:-/opt/scopesentry-scan}"
NODE_ENV_FILE="${NODE_ETC_DIR}/node.env"
NODE_COMPOSE_FILE="${NODE_ETC_DIR}/docker-compose.yml"
NODE_CONTAINER_NAME="${SCOPESENTRY_NODE_CONTAINER_NAME:-scopesentry-scan}"

DOCKER_BIN="${DOCKER_BIN:-docker}"
ACTION="enable"
PORTSCAN_ENABLED="true"
SUBDOMAIN_ENABLED="true"
SUBDOMAIN_TIMEOUT_SECONDS="7200"
ADAPTIVE_PULL_ENABLED="false"
RESTART="true"

log() {
  printf '\033[32m[stream-task]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[33m[stream-task]\033[0m %s\n' "$*" >&2
}

err() {
  printf '\033[31m[stream-task]\033[0m %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  enable-stream-task.sh enable [options]
  enable-stream-task.sh status

Options:
  --portscan-only       只开启 PortScan chunk，关闭 SubdomainScan chunk
  --subdomain-only      只开启 SubdomainScan chunk，关闭 PortScan chunk
  --timeout <seconds>   SubdomainScan chunk 超时时间，默认 7200
  --adaptive            开启扫描节点自适应拉取
  --no-adaptive         关闭扫描节点自适应拉取，默认
  --no-restart          只写配置，不重建容器
  -h, --help            显示帮助

默认会自动识别：
  - 服务端: /opt/scopesentry/docker-compose.yml
  - 扫描端: /etc/scopesentry-node/node.env

服务端和扫描端分开部署时，在两台机器分别执行同一条命令即可。
EOF
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      enable|status)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --portscan-only)
        PORTSCAN_ENABLED="true"
        SUBDOMAIN_ENABLED="false"
        shift
        ;;
      --subdomain-only)
        PORTSCAN_ENABLED="false"
        SUBDOMAIN_ENABLED="true"
        shift
        ;;
      --timeout)
        [[ $# -ge 2 ]] || { err "--timeout requires a value"; exit 1; }
        SUBDOMAIN_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --adaptive)
        ADAPTIVE_PULL_ENABLED="true"
        shift
        ;;
      --no-adaptive)
        ADAPTIVE_PULL_ENABLED="false"
        shift
        ;;
      --no-restart)
        RESTART="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if ! [[ "$SUBDOMAIN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    err "--timeout must be a positive integer"
    exit 1
  fi
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
}

upsert_env_file() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      done = 1
      next
    }
    { print }
    END {
      if (done == 0) {
        print key "=" value
      }
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

set_compose_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  if grep -qE "^[[:space:]]*${key}:" "$file"; then
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
      $0 ~ "^[[:space:]]*" key ":" {
        sub(key ":.*", key ": \"" value "\"")
        print
        next
      }
      { print }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
    return 0
  fi

  if ! grep -qE '^[[:space:]]*REDIS_PASSWORD:' "$file"; then
    err "cannot find REDIS_PASSWORD anchor in $file; please add ${key}: \"${value}\" under scope-sentry.environment manually"
    exit 1
  fi

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    {
      print
      if (inserted == 0 && $0 ~ "^[[:space:]]*REDIS_PASSWORD:") {
        indent = $0
        sub(/REDIS_PASSWORD:.*/, "", indent)
        print indent key ": \"" value "\""
        inserted = 1
      }
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

compose_up_server() {
  if [[ "$RESTART" != "true" ]]; then
    log "server config updated; restart skipped by --no-restart"
    return
  fi

  log "recreate server container: ${SERVER_SERVICE_NAME}"
  if [[ -f "$SERVER_ENV_FILE" ]]; then
    (cd "$INSTALL_DIR" && "$DOCKER_BIN" compose --env-file .env up -d --force-recreate "$SERVER_SERVICE_NAME")
  else
    (cd "$INSTALL_DIR" && "$DOCKER_BIN" compose up -d --force-recreate "$SERVER_SERVICE_NAME")
  fi
}

compose_up_node() {
  if [[ "$RESTART" != "true" ]]; then
    log "node config updated; restart skipped by --no-restart"
    return
  fi

  log "recreate scan node container"
  if [[ -f "$NODE_ENV_FILE" ]]; then
    (cd "$NODE_ETC_DIR" && "$DOCKER_BIN" compose --env-file node.env up -d --force-recreate)
  else
    (cd "$NODE_ETC_DIR" && "$DOCKER_BIN" compose up -d --force-recreate)
  fi
}

reset_node_runtime_config() {
  local config_mount

  config_mount="$("$DOCKER_BIN" inspect "$NODE_CONTAINER_NAME" -f '{{range .Mounts}}{{if eq .Destination "/apps/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
  if [[ -n "$config_mount" && -f "$config_mount/config.yaml" ]]; then
    log "remove persisted scan config: ${config_mount}/config.yaml"
    rm -f "$config_mount/config.yaml"
  fi

  if [[ -f "${NODE_DATA_DIR}/config/config.yaml" ]]; then
    log "remove node data config: ${NODE_DATA_DIR}/config/config.yaml"
    rm -f "${NODE_DATA_DIR}/config/config.yaml"
  fi
}

enable_server() {
  if [[ ! -f "$SERVER_COMPOSE_FILE" ]]; then
    warn "skip server: $SERVER_COMPOSE_FILE not found"
    return 0
  fi

  log "enable server stream flags in $SERVER_COMPOSE_FILE"
  backup_file "$SERVER_COMPOSE_FILE"
  set_compose_env_value "$SERVER_COMPOSE_FILE" "STREAM_PORTSCAN_ENABLED" "$PORTSCAN_ENABLED"
  set_compose_env_value "$SERVER_COMPOSE_FILE" "STREAM_SUBDOMAIN_ENABLED" "$SUBDOMAIN_ENABLED"
  compose_up_server
}

enable_node() {
  if [[ ! -f "$NODE_ENV_FILE" || ! -f "$NODE_COMPOSE_FILE" ]]; then
    warn "skip scan node: $NODE_ENV_FILE or $NODE_COMPOSE_FILE not found"
    return 0
  fi

  log "enable scan node stream flags in $NODE_ENV_FILE"
  backup_file "$NODE_ENV_FILE"
  upsert_env_file "$NODE_ENV_FILE" "TASK_MODE" "stream"
  upsert_env_file "$NODE_ENV_FILE" "STREAM_PORTSCAN_ENABLED" "$PORTSCAN_ENABLED"
  upsert_env_file "$NODE_ENV_FILE" "STREAM_SUBDOMAIN_ENABLED" "$SUBDOMAIN_ENABLED"
  upsert_env_file "$NODE_ENV_FILE" "STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS" "$SUBDOMAIN_TIMEOUT_SECONDS"
  upsert_env_file "$NODE_ENV_FILE" "ADAPTIVE_PULL_ENABLED" "$ADAPTIVE_PULL_ENABLED"
  reset_node_runtime_config
  compose_up_node
}

show_server_status() {
  printf '\n=== Server ===\n'
  if [[ ! -f "$SERVER_COMPOSE_FILE" ]]; then
    printf 'not installed: %s\n' "$SERVER_COMPOSE_FILE"
    return
  fi

  printf 'compose: %s\n' "$SERVER_COMPOSE_FILE"
  grep -nE 'STREAM_(PORTSCAN|SUBDOMAIN)_ENABLED:' "$SERVER_COMPOSE_FILE" || true
  printf '\ncontainer env:\n'
  "$DOCKER_BIN" inspect "$SERVER_CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E '^STREAM_(PORTSCAN|SUBDOMAIN)_ENABLED=' || true
}

show_node_status() {
  printf '\n=== Scan Node ===\n'
  if [[ ! -f "$NODE_ENV_FILE" ]]; then
    printf 'not installed: %s\n' "$NODE_ENV_FILE"
    return
  fi

  printf 'env: %s\n' "$NODE_ENV_FILE"
  grep -nE '^(TASK_MODE|STREAM_PORTSCAN_ENABLED|STREAM_SUBDOMAIN_ENABLED|STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS|ADAPTIVE_PULL_ENABLED)=' "$NODE_ENV_FILE" || true
  printf '\ncontainer config:\n'
  "$DOCKER_BIN" exec "$NODE_CONTAINER_NAME" sh -lc '
    if [ -f /apps/config/config.yaml ]; then
      grep -nE "taskMode|streamPortScanEnabled|streamSubdomainScanEnabled|adaptivePullEnabled|subdomainChunkTimeoutSeconds" /apps/config/config.yaml
    else
      echo "/apps/config/config.yaml not found"
    fi
  ' 2>/dev/null || true
}

show_status() {
  show_server_status
  show_node_status
}

main() {
  parse_args "$@"

  case "$ACTION" in
    enable)
      enable_server
      enable_node
      show_status
      ;;
    status)
      show_status
      ;;
    *)
      err "unsupported action: $ACTION"
      usage
      exit 1
      ;;
  esac
}

main "$@"
