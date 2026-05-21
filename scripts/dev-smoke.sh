#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == "--stream-portscan" ]]; then
  shift
  exec "$ROOT_DIR/scripts/tests/portscan_stream_chunk_smoke.sh" "$@"
fi

LOCAL_DEV_DIR="$ROOT_DIR/.local-dev"
SERVER_RUNTIME_DIR="$LOCAL_DEV_DIR/runtime/server"
SCAN_RUNTIME_DIR="$LOCAL_DEV_DIR/runtime/scan-host"
LOG_DIR="$LOCAL_DEV_DIR/logs"
PID_DIR="$LOCAL_DEV_DIR/pids"
BACKEND_LOG="$LOG_DIR/dev-server.log"
HOST_SCAN_LOG="$LOG_DIR/dev-scan.log"
NODE_LOG_SNAPSHOT="$LOG_DIR/dev-smoke-node.log"
SERVER_PID_FILE="$PID_DIR/dev-server.pid"
SCAN_PID_FILE="$PID_DIR/dev-scan.pid"

BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8080}"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-$BACKEND_URL}"
LOGIN_URL="$BACKEND_URL/api/user/login"
NODE_URL="$BACKEND_URL/api/node"
NODE_PLUGIN_URL="$BACKEND_URL/api/node/plugin"
NODE_LOG_URL="$BACKEND_URL/api/node/log"
TEMPLATE_LIST_URL="$BACKEND_URL/api/task/template"
TEMPLATE_DETAIL_URL="$BACKEND_URL/api/task/template/detail"
TEMPLATE_SAVE_URL="$BACKEND_URL/api/task/template/save"
TASK_ADD_URL="$BACKEND_URL/api/task/add"
TASK_LIST_URL="$BACKEND_URL/api/task/"
TASK_PROGRESS_URL="$BACKEND_URL/api/task/progress/info"

USERNAME="${USERNAME:-ScopeSentry}"
DEFAULT_SCAN_DRIVER="docker"
SCAN_DRIVER="${SCAN_DRIVER:-$DEFAULT_SCAN_DRIVER}"
SCAN_DOCKER_CONTAINER_NAME="${SCAN_DOCKER_CONTAINER_NAME:-scopesentry-scan-dev}"
if [[ "$SCAN_DRIVER" == "docker" ]]; then
  NODE_NAME="${NODE_NAME:-local-dev-node-docker}"
  SCAN_RUNTIME_DIR="$LOCAL_DEV_DIR/runtime/scan-docker"
  SCAN_LOG="docker logs -f $SCAN_DOCKER_CONTAINER_NAME"
else
  NODE_NAME="${NODE_NAME:-local-dev-node}"
  SCAN_RUNTIME_DIR="$LOCAL_DEV_DIR/scope-scan"
  SCAN_LOG="$HOST_SCAN_LOG"
fi
TARGET_URL="${1:-http://example.com}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
TEMPLATE_NAME="local-dev-smoke-httpx-$STAMP"
TASK_NAME="local-dev-smoke-task-$STAMP"
PASSWORD_FILE="$SERVER_RUNTIME_DIR/PASSWORD"

mkdir -p "$LOG_DIR" "$PID_DIR" "$LOCAL_DEV_DIR"

log() {
  printf '[dev-smoke] %s\n' "$*"
}

json_path() {
  local path="$1"
  python3 -c '
import json
import sys

path = [p for p in sys.argv[1].split(".") if p]
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print("")
    sys.exit(0)

cur = data
for part in path:
    if isinstance(cur, list):
        try:
            cur = cur[int(part)]
        except (ValueError, IndexError):
            print("")
            sys.exit(0)
    elif isinstance(cur, dict):
        cur = cur.get(part)
        if cur is None:
            print("")
            sys.exit(0)
    else:
        print("")
        sys.exit(0)

if cur is None:
    print("")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
' "$path"
}

wait_for_http() {
  local url="$1"
  local timeout_seconds="$2"
  local start_ts
  start_ts="$(date +%s)"
  while true; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start_ts >= timeout_seconds )); then
      return 1
    fi
    sleep 1
  done
}

wait_for_file() {
  local file_path="$1"
  local timeout_seconds="$2"
  local start_ts
  start_ts="$(date +%s)"
  while true; do
    if [[ -s "$file_path" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start_ts >= timeout_seconds )); then
      return 1
    fi
    sleep 1
  done
}

api_get() {
  local url="$1"
  local token="$2"
  curl -fsS "$url" -H "Authorization: Bearer $token"
}

api_post() {
  local url="$1"
  local token="$2"
  local payload="$3"
  curl -fsS -X POST "$url" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "$payload"
}

start_backend_if_needed() {
  if wait_for_http "$BACKEND_HEALTH_URL" 2; then
    log "backend already reachable: $BACKEND_URL"
    return 0
  fi

  log "starting MongoDB and Redis"
  "$ROOT_DIR/scripts/dev-db-up.sh" >/dev/null

  log "starting backend in background"
  nohup "$ROOT_DIR/scripts/dev-server.sh" >"$BACKEND_LOG" 2>&1 &
  echo "$!" >"$SERVER_PID_FILE"

  if ! wait_for_http "$BACKEND_HEALTH_URL" 120; then
    log "backend did not become ready in time; inspect $BACKEND_LOG"
    return 1
  fi

  if ! wait_for_file "$PASSWORD_FILE" 30; then
    log "backend started but password file is still missing: $PASSWORD_FILE"
    return 1
  fi
}

login_and_get_token() {
  if ! wait_for_file "$PASSWORD_FILE" 30; then
    log "missing password file: $PASSWORD_FILE"
    return 1
  fi

  local password
  password="$(cat "$PASSWORD_FILE")"
  local response
  response="$(curl -fsS -X POST "$LOGIN_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$password\"}")"
  local token
  token="$(printf '%s' "$response" | json_path "data.access_token")"
  if [[ -z "$token" ]]; then
    log "login failed: $response"
    return 1
  fi
  printf '%s' "$token"
}

node_online() {
  local token="$1"
  local response
  response="$(api_get "$NODE_URL" "$token")"
  printf '%s' "$response" | python3 -c '
import json
import sys

node_name = sys.argv[1]
data = json.load(sys.stdin)
items = data.get("data", {}).get("list") or []
for item in items:
    if item.get("name") == node_name:
        print("1")
        sys.exit(0)
print("0")
' "$NODE_NAME"
}

start_scan_if_needed() {
  local token="$1"
  if [[ "$(node_online "$token")" == "1" ]]; then
    log "scan node already online: $NODE_NAME"
    return 0
  fi

  if [[ "$SCAN_DRIVER" == "docker" ]]; then
    log "starting scan node in docker"
    NODE_NAME="$NODE_NAME" CONTAINER_NAME="$SCAN_DOCKER_CONTAINER_NAME" \
      "$ROOT_DIR/scripts/dev-scan-docker.sh" up >/dev/null
  else
    log "starting scan node in background"
    nohup "$ROOT_DIR/scripts/dev-scan.sh" >"$HOST_SCAN_LOG" 2>&1 &
    echo "$!" >"$SCAN_PID_FILE"
  fi

  local start_ts
  start_ts="$(date +%s)"
  while true; do
    if [[ "$(node_online "$token")" == "1" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start_ts >= 420 )); then
      log "scan node did not register in time; inspect $SCAN_LOG"
      return 1
    fi
    sleep 5
  done
}

create_smoke_template() {
  local token="$1"
  local payload
  payload="$(cat <<EOF
{"id":"","result":{"name":"$TEMPLATE_NAME","ignore":"","target":"","type":"","duplicates":"","isStart":false,"TaskName":"","TargetHandler":[],"Parameters":{"TargetHandler":{},"SubdomainScan":{},"SubdomainSecurity":{},"PortScanPreparation":{},"PortScan":{},"PortFingerprint":{},"AssetMapping":{},"AssetHandle":{},"URLScan":{},"WebCrawler":{},"URLSecurity":{},"DirScan":{},"VulnerabilityScan":{},"PassiveScan":{}},"ParameterLists":{"TargetHandler":{},"SubdomainScan":{},"SubdomainSecurity":{},"PortScanPreparation":{},"PortScan":{},"PortFingerprint":{},"AssetMapping":{},"AssetHandle":{},"URLScan":{},"WebCrawler":{},"URLSecurity":{},"DirScan":{},"VulnerabilityScan":{},"PassiveScan":{}},"SubdomainScan":[],"SubdomainSecurity":[],"PortScanPreparation":[],"PortScan":[],"PortFingerprint":[],"AssetMapping":["3a0d994a12305cb15a5cb7104d819623"],"AssetHandle":["80718cc3fcb4827d942e6300184707e2"],"URLScan":[],"WebCrawler":[],"URLSecurity":[],"DirScan":[],"VulnerabilityScan":[],"vullist":[],"PassiveScan":[]}}
EOF
)"

  api_post "$TEMPLATE_SAVE_URL" "$token" "$payload" >/dev/null

  local list_response
  list_response="$(api_post "$TEMPLATE_LIST_URL" "$token" "{\"pageIndex\":1,\"pageSize\":20,\"query\":\"$TEMPLATE_NAME\"}")"
  local template_id
  template_id="$(printf '%s' "$list_response" | json_path "data.list.0.id")"
  if [[ -z "$template_id" ]]; then
    log "failed to resolve smoke template id"
    return 1
  fi

  local detail_response
  detail_response="$(api_post "$TEMPLATE_DETAIL_URL" "$token" "{\"id\":\"$template_id\"}")"
  local mapping_plugin
  local handle_plugin
  mapping_plugin="$(printf '%s' "$detail_response" | json_path "data.AssetMapping.0")"
  handle_plugin="$(printf '%s' "$detail_response" | json_path "data.AssetHandle.0")"
  if [[ "$mapping_plugin" != "3a0d994a12305cb15a5cb7104d819623" || "$handle_plugin" != "80718cc3fcb4827d942e6300184707e2" ]]; then
    log "smoke template verification failed: $detail_response"
    return 1
  fi

  printf '%s' "$template_id"
}

create_smoke_task() {
  local token="$1"
  local template_id="$2"
  local payload
  payload="$(cat <<EOF
{"name":"$TASK_NAME","target":"$TARGET_URL","ignore":"","node":["$NODE_NAME"],"allNode":false,"duplicates":"","scheduledTasks":false,"hour":0,"template":"$template_id","targetTp":"","search":"","filter":{},"targetNumber":0,"targetIds":[],"project":[],"targetSource":"general","day":0,"minute":0,"week":0,"bindProject":null,"cycleType":""}
EOF
)"
  local response
  response="$(api_post "$TASK_ADD_URL" "$token" "$payload")"
  local code
  code="$(printf '%s' "$response" | json_path "code")"
  if [[ "$code" != "200" ]]; then
    log "task creation failed: $response"
    return 1
  fi
}

lookup_task_id() {
  local token="$1"
  local response
  response="$(api_post "$TASK_LIST_URL" "$token" "{\"search\":\"$TASK_NAME\",\"pageIndex\":1,\"pageSize\":10}")"
  printf '%s' "$response" | json_path "data.list.0.id"
}

wait_for_task_completion() {
  local token="$1"
  local task_id="$2"
  local start_ts
  start_ts="$(date +%s)"
  while true; do
    local response
    response="$(api_post "$TASK_PROGRESS_URL" "$token" "{\"id\":\"$task_id\",\"pageIndex\":1,\"pageSize\":10}")"
    local end_time
    end_time="$(printf '%s' "$response" | json_path "data.list.0.All.1")"
    if [[ -n "$end_time" ]]; then
      printf '%s' "$response"
      return 0
    fi
    if (( "$(date +%s)" - start_ts >= 240 )); then
      log "task did not finish in time: $response"
      return 1
    fi
    sleep 3
  done
}

snapshot_node_log() {
  local token="$1"
  api_post "$NODE_LOG_URL" "$token" "{\"name\":\"$NODE_NAME\"}" >"$NODE_LOG_SNAPSHOT"
}

main() {
  log "target url: $TARGET_URL"

  start_backend_if_needed

  local token
  token="$(login_and_get_token)"

  start_scan_if_needed "$token"

  local node_response
  node_response="$(api_get "$NODE_URL" "$token")"
  local node_plugins
  node_plugins="$(api_post "$NODE_PLUGIN_URL" "$token" "{\"name\":\"$NODE_NAME\"}")"
  local template_id
  template_id="$(create_smoke_template "$token")"
  create_smoke_task "$token" "$template_id"

  local task_id
  local start_ts
  start_ts="$(date +%s)"
  task_id=""
  while [[ -z "$task_id" ]]; do
    task_id="$(lookup_task_id "$token")"
    if [[ -n "$task_id" ]]; then
      break
    fi
    if (( "$(date +%s)" - start_ts >= 60 )); then
      log "task id did not appear in list in time"
      return 1
    fi
    sleep 2
  done

  local progress_response
  progress_response="$(wait_for_task_completion "$token" "$task_id")"
  snapshot_node_log "$token"

  local password
  password="$(cat "$PASSWORD_FILE")"
  local plugin_count
  plugin_count="$(printf '%s' "$node_plugins" | json_path "data.list" | python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
    print(0)
else:
    print(len(json.loads(raw)))
')"
  local node_finished
  node_finished="$(printf '%s' "$node_response" | python3 -c '
import json
import sys

name = sys.argv[1]
data = json.load(sys.stdin)
items = data.get("data", {}).get("list") or []
for item in items:
    if item.get("name") == name:
        print(item.get("finished", ""))
        break
else:
    print("")
' "$NODE_NAME")"

  printf '\n'
  log "smoke passed"
  printf 'backend_url=%s\n' "$BACKEND_URL"
  printf 'username=%s\n' "$USERNAME"
  printf 'password=%s\n' "$password"
  printf 'scan_driver=%s\n' "$SCAN_DRIVER"
  printf 'node_name=%s\n' "$NODE_NAME"
  printf 'node_finished_before_snapshot=%s\n' "$node_finished"
  printf 'plugin_entries=%s\n' "$plugin_count"
  printf 'template_name=%s\n' "$TEMPLATE_NAME"
  printf 'task_name=%s\n' "$TASK_NAME"
  printf 'task_id=%s\n' "$task_id"
  printf 'server_runtime=%s\n' "$SERVER_RUNTIME_DIR"
  printf 'scan_runtime=%s\n' "$SCAN_RUNTIME_DIR"
  printf 'server_log=%s\n' "$BACKEND_LOG"
  printf 'scan_log=%s\n' "$SCAN_LOG"
  printf 'node_log_snapshot=%s\n' "$NODE_LOG_SNAPSHOT"
  printf 'task_progress=%s\n' "$progress_response"
}

main "$@"
