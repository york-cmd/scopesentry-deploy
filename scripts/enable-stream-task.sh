#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${SCOPESENTRY_INSTALL_DIR:-/opt/scopesentry}"
SERVER_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
SERVER_ENV_FILE="${INSTALL_DIR}/.env"
SERVER_CONTAINER_NAME="${SCOPESENTRY_SERVER_CONTAINER_NAME:-scope-sentry}"
SERVER_SERVICE_NAME="${SCOPESENTRY_SERVER_SERVICE_NAME:-scope-sentry}"
REDIS_CONTAINER_NAME="${SCOPESENTRY_REDIS_CONTAINER_NAME:-scopesentry-redis}"
MONGO_CONTAINER_NAME="${SCOPESENTRY_MONGO_CONTAINER_NAME:-scopesentry-mongodb}"

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
DOCTOR_FAILURES=0
DOCTOR_WARNINGS=0

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
  enable-stream-task.sh doctor

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
      enable|status|doctor)
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

read_env_file_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null
}

container_env() {
  local container="$1"
  "$DOCKER_BIN" inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true
}

container_env_value() {
  local container="$1"
  local key="$2"
  container_env "$container" | awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}'
}

has_server_install() {
  [[ -f "$SERVER_COMPOSE_FILE" ]]
}

has_node_install() {
  [[ -f "$NODE_ENV_FILE" && -f "$NODE_COMPOSE_FILE" ]]
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
  if ! has_server_install; then
    printf 'not installed: %s\n' "$SERVER_COMPOSE_FILE"
    return
  fi

  printf 'compose: %s\n' "$SERVER_COMPOSE_FILE"
  grep -nE 'STREAM_(PORTSCAN|SUBDOMAIN)_ENABLED:' "$SERVER_COMPOSE_FILE" || true
  printf '\ncontainer env:\n'
  container_env "$SERVER_CONTAINER_NAME" | grep -E '^STREAM_(PORTSCAN|SUBDOMAIN)_ENABLED=' || true
}

show_node_status() {
  printf '\n=== Scan Node ===\n'
  if [[ ! -f "$NODE_ENV_FILE" ]]; then
    printf 'not installed: %s\n' "$NODE_ENV_FILE"
    return
  fi

  printf 'env: %s\n' "$NODE_ENV_FILE"
  grep -nE '^(TASK_MODE|STREAM_PORTSCAN_ENABLED|STREAM_SUBDOMAIN_ENABLED|STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS|ADAPTIVE_PULL_ENABLED)=' "$NODE_ENV_FILE" || true
  printf '\ncontainer env:\n'
  container_env "$NODE_CONTAINER_NAME" | grep -E '^(TASK_MODE|STREAM_PORTSCAN_ENABLED|STREAM_SUBDOMAIN_ENABLED|STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS|ADAPTIVE_PULL_ENABLED)=' || true
  printf '\ncontainer config:\n'
  "$DOCKER_BIN" exec "$NODE_CONTAINER_NAME" sh -lc '
    if [ -f /apps/config/config.yaml ]; then
      grep -nE "taskMode|streamPortScanEnabled|streamSubdomainScanEnabled|adaptivePullEnabled|subdomainChunkTimeoutSeconds" /apps/config/config.yaml
    else
      echo "runtime config: not found; container env will be used before first generated config exists"
    fi
  ' 2>/dev/null || true
}

show_status() {
  show_server_status
  show_node_status
}

doctor_pass() {
  printf '  [OK] %s\n' "$*"
}

doctor_warn() {
  DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
  printf '  [WARN] %s\n' "$*"
}

doctor_fail() {
  DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
  printf '  [FAIL] %s\n' "$*"
}

expect_value() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    doctor_pass "${label}: ${actual}"
  elif [[ -z "$actual" ]]; then
    doctor_fail "${label}: missing, expected ${expected}"
  else
    doctor_fail "${label}: ${actual}, expected ${expected}"
  fi
}

doctor_server_flags() {
  printf '\n=== Server Stream Flags ===\n'
  if ! has_server_install; then
    doctor_warn "server compose not found on this host: ${SERVER_COMPOSE_FILE}"
    return
  fi

  local portscan subdomain container_portscan container_subdomain
  portscan="$(grep -E '^[[:space:]]*STREAM_PORTSCAN_ENABLED:' "$SERVER_COMPOSE_FILE" | tail -1 | sed -E 's/.*STREAM_PORTSCAN_ENABLED:[[:space:]]*"?([^"# ]+)"?.*/\1/' || true)"
  subdomain="$(grep -E '^[[:space:]]*STREAM_SUBDOMAIN_ENABLED:' "$SERVER_COMPOSE_FILE" | tail -1 | sed -E 's/.*STREAM_SUBDOMAIN_ENABLED:[[:space:]]*"?([^"# ]+)"?.*/\1/' || true)"
  container_portscan="$(container_env_value "$SERVER_CONTAINER_NAME" STREAM_PORTSCAN_ENABLED)"
  container_subdomain="$(container_env_value "$SERVER_CONTAINER_NAME" STREAM_SUBDOMAIN_ENABLED)"

  expect_value "compose STREAM_PORTSCAN_ENABLED" "$portscan" "true"
  expect_value "compose STREAM_SUBDOMAIN_ENABLED" "$subdomain" "true"
  expect_value "container STREAM_PORTSCAN_ENABLED" "$container_portscan" "true"
  expect_value "container STREAM_SUBDOMAIN_ENABLED" "$container_subdomain" "true"
}

doctor_node_flags() {
  printf '\n=== Scan Node Stream Flags ===\n'
  if ! has_node_install; then
    doctor_warn "scan node env/compose not found on this host: ${NODE_ENV_FILE}, ${NODE_COMPOSE_FILE}"
    return
  fi

  expect_value "node.env TASK_MODE" "$(read_env_file_value "$NODE_ENV_FILE" TASK_MODE)" "stream"
  expect_value "node.env STREAM_PORTSCAN_ENABLED" "$(read_env_file_value "$NODE_ENV_FILE" STREAM_PORTSCAN_ENABLED)" "true"
  expect_value "node.env STREAM_SUBDOMAIN_ENABLED" "$(read_env_file_value "$NODE_ENV_FILE" STREAM_SUBDOMAIN_ENABLED)" "true"
  expect_value "container TASK_MODE" "$(container_env_value "$NODE_CONTAINER_NAME" TASK_MODE)" "stream"
  expect_value "container STREAM_PORTSCAN_ENABLED" "$(container_env_value "$NODE_CONTAINER_NAME" STREAM_PORTSCAN_ENABLED)" "true"
  expect_value "container STREAM_SUBDOMAIN_ENABLED" "$(container_env_value "$NODE_CONTAINER_NAME" STREAM_SUBDOMAIN_ENABLED)" "true"

  local timeout adaptive
  timeout="$(read_env_file_value "$NODE_ENV_FILE" STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS)"
  adaptive="$(read_env_file_value "$NODE_ENV_FILE" ADAPTIVE_PULL_ENABLED)"
  if [[ "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    doctor_pass "node.env STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS: ${timeout}"
  else
    doctor_fail "node.env STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS: ${timeout:-missing}"
  fi
  if [[ "$adaptive" == "true" || "$adaptive" == "false" ]]; then
    doctor_pass "node.env ADAPTIVE_PULL_ENABLED: ${adaptive}"
  else
    doctor_fail "node.env ADAPTIVE_PULL_ENABLED: ${adaptive:-missing}"
  fi

  printf '\nnode runtime config:\n'
  "$DOCKER_BIN" exec "$NODE_CONTAINER_NAME" sh -lc '
    if [ -f /apps/config/config.yaml ]; then
      grep -nE "taskMode|streamPortScanEnabled|streamSubdomainScanEnabled|adaptivePullEnabled|subdomainChunkTimeoutSeconds" /apps/config/config.yaml
    else
      echo "runtime config: not found; container env will be used before first generated config exists"
    fi
  ' 2>/dev/null || doctor_warn "unable to inspect scan node runtime config"
}

doctor_ui_bundle() {
  printf '\n=== Server UI Bundle ===\n'
  if ! has_server_install; then
    doctor_warn "skip UI bundle check because server is not installed on this host"
    return
  fi

  local output
  output="$("$DOCKER_BIN" exec "$SERVER_CONTAINER_NAME" sh -lc 'grep -a -o "subdomainScanChunks\|subdomainChunkProgress\|子域名分片进度" /opt/ScopeSentry/ScopeSentry | head -1' 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    doctor_pass "UI bundle: present"
  else
    doctor_fail "UI bundle: missing Subdomain stream progress assets; run update-server.sh and hard refresh browser"
  fi
}

doctor_redis_streams() {
  printf '\n=== Redis Streams ===\n'
  if ! has_server_install; then
    doctor_warn "skip Redis stream check because server is not installed on this host"
    return
  fi

  local output
  output="$("$DOCKER_BIN" exec "$REDIS_CONTAINER_NAME" sh -lc '
    pass="$(printenv REDIS_PASSWORD)"
    auth=""
    if [ -n "$pass" ]; then auth="-a $pass"; fi
    for key in scan:stream:PortScan scan:stream:SubdomainScan scan:stream:PortScan:dlq scan:stream:SubdomainScan:dlq; do
      len="$(redis-cli $auth XLEN "$key" 2>/dev/null || echo 0)"
      groups="$(redis-cli $auth XINFO GROUPS "$key" 2>/dev/null | grep -c "^name" || true)"
      printf "%s length=%s groups=%s\n" "$key" "$len" "$groups"
    done
  ' 2>/dev/null || true)"

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
    doctor_pass "Redis Streams: reachable"
  else
    doctor_fail "Redis Streams: unable to inspect ${REDIS_CONTAINER_NAME}"
  fi
}

doctor_mongo_chunks() {
  printf '\n=== Mongo Stream Chunks ===\n'
  if ! has_server_install; then
    doctor_warn "skip Mongo chunk check because server is not installed on this host"
    return
  fi

  local output
  output="$("$DOCKER_BIN" exec "$MONGO_CONTAINER_NAME" sh -lc '
    user="$(printenv MONGO_INITDB_ROOT_USERNAME)"
    pass="$(printenv MONGO_INITDB_ROOT_PASSWORD)"
    auth=""
    if [ -n "$user" ] && [ -n "$pass" ]; then auth="-u $user -p $pass --authenticationDatabase admin"; fi
    mongosh --quiet $auth ScopeSentry --eval '"'"'
      const total = db.stream_task_chunks.countDocuments({});
      const dlq = db.stream_task_chunks.countDocuments({status:"dlq", ignored: {$ne: true}});
      const running = db.stream_task_chunks.countDocuments({status:"running"});
      print("stream_task_chunks total=" + total + " running=" + running + " dlq=" + dlq);
    '"'"'
  ' 2>/dev/null || true)"

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
    doctor_pass "Mongo Stream Chunks: reachable"
  else
    doctor_fail "Mongo Stream Chunks: unable to inspect ${MONGO_CONTAINER_NAME}"
  fi
}

doctor() {
  DOCTOR_FAILURES=0
  DOCTOR_WARNINGS=0
  show_status
  doctor_server_flags
  doctor_node_flags
  doctor_ui_bundle
  doctor_redis_streams
  doctor_mongo_chunks

  printf '\n=== Doctor Result ===\n'
  if [[ "$DOCTOR_FAILURES" -eq 0 ]]; then
    printf 'doctor result: pass'
    if [[ "$DOCTOR_WARNINGS" -gt 0 ]]; then
      printf ' (%s warning(s))' "$DOCTOR_WARNINGS"
    fi
    printf '\n'
    return 0
  fi
  printf 'doctor result: fail (%s failure(s), %s warning(s))\n' "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
  return 1
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
    doctor)
      doctor
      ;;
    *)
      err "unsupported action: $ACTION"
      usage
      exit 1
      ;;
  esac
}

main "$@"
