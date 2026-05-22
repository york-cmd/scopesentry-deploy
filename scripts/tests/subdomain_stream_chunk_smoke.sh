#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_DEV_DIR="$REPO_ROOT/.local-dev"
SERVER_RUNTIME_DIR="$LOCAL_DEV_DIR/runtime/server"
HOST_SCAN_RUNTIME_DIR="${HOST_SCAN_RUNTIME_DIR:-$LOCAL_DEV_DIR/runtime/scan-host-stream-subdomain}"
LOG_DIR="$LOCAL_DEV_DIR/logs"
PID_DIR="$LOCAL_DEV_DIR/pids"
BACKEND_LOG="$LOG_DIR/dev-server-stream-subdomain.log"
HOST_SCAN_LOG="$LOG_DIR/dev-scan-stream-subdomain.log"
SERVER_PID_FILE="$PID_DIR/dev-server-stream-subdomain.pid"
SCAN_PID_FILE="$PID_DIR/dev-scan-stream-subdomain.pid"

BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8080}"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-$BACKEND_URL}"
LOGIN_URL="$BACKEND_URL/api/user/login"
NODE_URL="$BACKEND_URL/api/node"
TEMPLATE_LIST_URL="$BACKEND_URL/api/task/template"
TEMPLATE_SAVE_URL="$BACKEND_URL/api/task/template/save"
TASK_ADD_URL="$BACKEND_URL/api/task/add"
TASK_LIST_URL="$BACKEND_URL/api/task/"
TASK_PROGRESS_URL="$BACKEND_URL/api/task/progress/info"
CHUNK_SUMMARY_URL="$BACKEND_URL/api/task/stream/chunk/summary"

USERNAME="${USERNAME:-ScopeSentry}"
PASSWORD_FILE="$SERVER_RUNTIME_DIR/PASSWORD"
SCAN_DRIVER="${SCAN_DRIVER:-host}"
SCAN_DOCKER_CONTAINER_NAME="${SCAN_DOCKER_CONTAINER_NAME:-scopesentry-scan-dev}"
STREAM_SMOKE_STAMP="${STREAM_SMOKE_STAMP:-$(date '+%Y%m%d-%H%M%S')}"
NODE_NAME_FROM_ENV="${NODE_NAME:-}"
NODE_NAME="${NODE_NAME:-local-dev-node-stream-subdomain-$STREAM_SMOKE_STAMP}"
TEMPLATE_PREFIX="${TEMPLATE_PREFIX:-stream-subdomain-smoke-$STREAM_SMOKE_STAMP}"
TASK_PREFIX="${TASK_PREFIX:-stream-subdomain-smoke-task-$STREAM_SMOKE_STAMP}"

SUBFINDER_PLUGIN="${SUBFINDER_PLUGIN:-0d4f8b8f79d04c2d97f1d0f0d4f8b8f7}"
PUREDNS_PLUGIN="${PUREDNS_PLUGIN:-52d3d3f0fd6f4e2ca22a2d433299a9e2}"
SUBDOMAIN_PLUGINS=("$SUBFINDER_PLUGIN" "$PUREDNS_PLUGIN")
ROOT_DOMAINS=(${ROOT_DOMAINS:-example.com example.org demo.test})
CHUNK_TIMEOUT_SECONDS="${CHUNK_TIMEOUT_SECONDS:-180}"
SUBDOMAIN_CHUNK_TIMEOUT_SECONDS="${SUBDOMAIN_CHUNK_TIMEOUT_SECONDS:-7200}"

mkdir -p "$LOG_DIR" "$PID_DIR" "$LOCAL_DEV_DIR"

log() {
  printf '[subdomain-stream-smoke] %s\n' "$*"
}

fail() {
  printf '[subdomain-stream-smoke] FAIL: %s\n' "$*" >&2
  exit 1
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

expected_chunks() {
  local root_count="$1"
  local plugin_count="$2"
  printf '%s\n' $((root_count * plugin_count))
}

targets_payload() {
  printf '%s\n' "${ROOT_DOMAINS[@]}"
}

build_template_payload() {
  local name="$1"
  python3 - "$name" "${SUBDOMAIN_PLUGINS[@]}" <<'PY'
import json
import sys

name = sys.argv[1]
plugins = sys.argv[2:]
modules = [
    "TargetHandler", "SubdomainScan", "SubdomainSecurity", "PortScanPreparation",
    "PortScan", "PortFingerprint", "AssetMapping", "AssetHandle", "URLScan",
    "WebCrawler", "URLSecurity", "DirScan", "VulnerabilityScan", "PassiveScan",
]
params = {module: {} for module in modules}
parameter_lists = {module: {} for module in modules}
for plugin in plugins:
    params["SubdomainScan"][plugin] = ""

template = {
    "name": name,
    "ignore": "",
    "target": "",
    "type": "",
    "duplicates": "",
    "isStart": False,
    "TaskName": "",
    "TargetHandler": [],
    "Parameters": params,
    "ParameterLists": parameter_lists,
    "SubdomainScan": plugins,
    "SubdomainSecurity": [],
    "PortScanPreparation": [],
    "PortScan": [],
    "PortFingerprint": [],
    "AssetMapping": [],
    "AssetHandle": [],
    "URLScan": [],
    "WebCrawler": [],
    "URLSecurity": [],
    "DirScan": [],
    "VulnerabilityScan": [],
    "vullist": [],
    "PassiveScan": [],
}
print(json.dumps({"id": "", "result": template}, separators=(",", ":")))
PY
}

build_task_payload() {
  local name="$1"
  local template_id="$2"
  python3 - "$name" "$template_id" "$NODE_NAME" "$(targets_payload)" <<'PY'
import json
import sys

name, template_id, node_name, target = sys.argv[1:]
payload = {
    "name": name,
    "target": target,
    "ignore": "",
    "node": [node_name],
    "allNode": False,
    "duplicates": "",
    "scheduledTasks": False,
    "hour": 0,
    "template": template_id,
    "targetTp": "",
    "search": "",
    "filter": {},
    "targetNumber": 0,
    "targetIds": [],
    "project": [],
    "targetSource": "general",
    "day": 0,
    "minute": 0,
    "week": 0,
    "bindProject": None,
    "cycleType": "",
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

start_backend_if_needed() {
  if wait_for_http "$BACKEND_HEALTH_URL" 2; then
    log "backend already reachable; ensure it was started with STREAM_SUBDOMAIN_ENABLED=true"
    return 0
  fi

  log "starting MongoDB and Redis"
  "$REPO_ROOT/scripts/dev-db-up.sh" >/dev/null

  log "starting backend with stream SubdomainScan enabled"
  STREAM_SUBDOMAIN_ENABLED=true \
    nohup "$REPO_ROOT/scripts/dev-server.sh" >"$BACKEND_LOG" 2>&1 &
  echo "$!" >"$SERVER_PID_FILE"

  wait_for_http "$BACKEND_HEALTH_URL" 120 || fail "backend did not become ready; inspect $BACKEND_LOG"
  wait_for_file "$PASSWORD_FILE" 30 || fail "missing password file: $PASSWORD_FILE"
}

login_and_get_token() {
  wait_for_file "$PASSWORD_FILE" 30 || fail "missing password file: $PASSWORD_FILE"
  local password response token
  password="$(cat "$PASSWORD_FILE")"
  response="$(curl -fsS -X POST "$LOGIN_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$password\"}")"
  token="$(printf '%s' "$response" | json_path "data.access_token")"
  [[ -n "$token" ]] || fail "login failed: $response"
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
    log "scan node already online: $NODE_NAME; ensure it uses TASK_MODE=stream"
    return 0
  fi

  if [[ "$SCAN_DRIVER" == "docker" ]]; then
    log "starting docker scan node with stream SubdomainScan mode"
    NODE_NAME="$NODE_NAME" \
      CONTAINER_NAME="$SCAN_DOCKER_CONTAINER_NAME" \
      TASK_MODE=stream \
      STREAM_SUBDOMAIN_ENABLED=true \
      STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS="$SUBDOMAIN_CHUNK_TIMEOUT_SECONDS" \
      ADAPTIVE_PULL_ENABLED="${ADAPTIVE_PULL_ENABLED:-false}" \
      "$REPO_ROOT/scripts/dev-scan-docker.sh" up >/dev/null
  else
    log "starting host scan node with stream SubdomainScan mode"
    rm -f "$HOST_SCAN_RUNTIME_DIR/config/config.yaml"
    NODE_NAME="$NODE_NAME" \
      NodeName="$NODE_NAME" \
      TASK_MODE=stream \
      STREAM_SUBDOMAIN_ENABLED=true \
      STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS="$SUBDOMAIN_CHUNK_TIMEOUT_SECONDS" \
      ADAPTIVE_PULL_ENABLED="${ADAPTIVE_PULL_ENABLED:-false}" \
      SCAN_RUNTIME_DIR="$HOST_SCAN_RUNTIME_DIR" \
      nohup "$REPO_ROOT/scripts/dev-scan.sh" >"$HOST_SCAN_LOG" 2>&1 &
    echo "$!" >"$SCAN_PID_FILE"
  fi

  local start_ts
  start_ts="$(date +%s)"
  while true; do
    if [[ "$(node_online "$token")" == "1" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start_ts >= 420 )); then
      fail "scan node did not register in time; inspect $HOST_SCAN_LOG or docker logs"
    fi
    sleep 5
  done
}

create_template() {
  local token="$1"
  local name="$2"
  local payload list_response template_id
  payload="$(build_template_payload "$name")"
  api_post "$TEMPLATE_SAVE_URL" "$token" "$payload" >/dev/null
  list_response="$(api_post "$TEMPLATE_LIST_URL" "$token" "{\"pageIndex\":1,\"pageSize\":20,\"query\":\"$name\"}")"
  template_id="$(printf '%s' "$list_response" | json_path "data.list.0.id")"
  [[ -n "$template_id" ]] || fail "failed to resolve template id for $name: $list_response"
  printf '%s' "$template_id"
}

create_task() {
  local token="$1"
  local name="$2"
  local template_id="$3"
  local payload response code
  payload="$(build_task_payload "$name" "$template_id")"
  response="$(api_post "$TASK_ADD_URL" "$token" "$payload")"
  code="$(printf '%s' "$response" | json_path "code")"
  [[ "$code" == "200" ]] || fail "task creation failed for $name: $response"
}

lookup_task_id() {
  local token="$1"
  local task_name="$2"
  local response
  response="$(api_post "$TASK_LIST_URL" "$token" "{\"search\":\"$task_name\",\"pageIndex\":1,\"pageSize\":10}")"
  printf '%s' "$response" | json_path "data.list.0.id"
}

wait_for_task_id() {
  local token="$1"
  local task_name="$2"
  local start_ts task_id
  start_ts="$(date +%s)"
  task_id=""
  while [[ -z "$task_id" ]]; do
    task_id="$(lookup_task_id "$token" "$task_name")"
    if [[ -n "$task_id" ]]; then
      printf '%s' "$task_id"
      return
    fi
    if (( "$(date +%s)" - start_ts >= 60 )); then
      fail "task id did not appear in list for $task_name"
    fi
    sleep 2
  done
}

chunk_summary() {
  local token="$1"
  local task_id="$2"
  api_post "$CHUNK_SUMMARY_URL" "$token" "{\"taskId\":\"$task_id\",\"stage\":\"SubdomainScan\"}"
}

wait_for_chunk_total() {
  local token="$1"
  local task_id="$2"
  local expected_total="$3"
  local start_ts response total
  start_ts="$(date +%s)"
  while true; do
    response="$(chunk_summary "$token" "$task_id")"
    total="$(printf '%s' "$response" | json_path "data.total")"
    if [[ "$total" == "$expected_total" ]]; then
      printf '%s' "$response"
      return
    fi
    if (( "$(date +%s)" - start_ts >= CHUNK_TIMEOUT_SECONDS )); then
      fail "expected $expected_total chunks for $task_id, got ${total:-empty}: $response"
    fi
    sleep 3
  done
}

assert_progress_has_chunk_summary() {
  local token="$1"
  local task_id="$2"
  local response total
  response="$(api_post "$TASK_PROGRESS_URL" "$token" "{\"id\":\"$task_id\",\"pageIndex\":1,\"pageSize\":10}")"
  total="$(printf '%s' "$response" | json_path "data.subdomainScanChunks.total")"
  [[ -n "$total" ]] || fail "progress response missing subdomainScanChunks summary: $response"
}

run_case() {
  local token="$1"
  local root_count="${#ROOT_DOMAINS[@]}"
  local plugin_count="${#SUBDOMAIN_PLUGINS[@]}"
  local expected_total template_id task_id summary
  expected_total="$(expected_chunks "$root_count" "$plugin_count")"
  template_id="$(create_template "$token" "$TEMPLATE_PREFIX")"
  create_task "$token" "$TASK_PREFIX" "$template_id"
  task_id="$(wait_for_task_id "$token" "$TASK_PREFIX")"
  summary="$(wait_for_chunk_total "$token" "$task_id" "$expected_total")"
  assert_progress_has_chunk_summary "$token" "$task_id"

  printf 'task_id=%s\n' "$task_id"
  printf 'expected_chunks=%s\n' "$expected_total"
  printf 'chunk_summary=%s\n' "$summary"
}

dry_run() {
  local expected payload plugin_count root_count
  plugin_count="${#SUBDOMAIN_PLUGINS[@]}"
  root_count="${#ROOT_DOMAINS[@]}"
  expected="$(expected_chunks "$root_count" "$plugin_count")"
  [[ "$expected" == "$((root_count * plugin_count))" ]] || fail "unexpected chunk math: $expected"
  [[ "$HOST_SCAN_RUNTIME_DIR" == *stream-subdomain* ]] || fail "host scan runtime must be isolated for stream smoke"
  [[ "$CHUNK_SUMMARY_URL" == */api/task/stream/chunk/summary ]] || fail "subdomain smoke must use generic chunk summary API"
  if [[ -z "$NODE_NAME_FROM_ENV" ]]; then
    [[ "$NODE_NAME" == *"$STREAM_SMOKE_STAMP"* ]] || fail "default node name should include the smoke stamp"
  fi
  payload="$(build_template_payload "dry-run-template")"
  PAYLOAD="$payload" python3 - "${SUBDOMAIN_PLUGINS[@]}" <<'PY'
import json
import os
import sys

plugins = sys.argv[1:]
payload = json.loads(os.environ["PAYLOAD"])
template = payload["result"]
if template["SubdomainScan"] != plugins:
    raise SystemExit(f"unexpected SubdomainScan plugins: {template['SubdomainScan']}")
if template["PortScan"]:
    raise SystemExit("Subdomain stream smoke template should not enable PortScan")
PY
  printf 'subdomain stream chunk smoke dry-run passed\n'
}

main() {
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run
    return
  fi

  log "starting stream SubdomainScan smoke"
  log "scan_driver=$SCAN_DRIVER node=$NODE_NAME roots=${#ROOT_DOMAINS[@]} plugins=${#SUBDOMAIN_PLUGINS[@]}"

  start_backend_if_needed
  token="$(login_and_get_token)"
  start_scan_if_needed "$token"
  run_case "$token"

  printf 'subdomain stream chunk smoke passed\n'
}

main "$@"
