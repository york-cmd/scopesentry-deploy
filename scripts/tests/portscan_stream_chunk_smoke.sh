#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_DEV_DIR="$REPO_ROOT/.local-dev"
SERVER_RUNTIME_DIR="$LOCAL_DEV_DIR/runtime/server"
HOST_SCAN_RUNTIME_DIR="${HOST_SCAN_RUNTIME_DIR:-$LOCAL_DEV_DIR/runtime/scan-host-stream-portscan}"
LOG_DIR="$LOCAL_DEV_DIR/logs"
PID_DIR="$LOCAL_DEV_DIR/pids"
BACKEND_LOG="$LOG_DIR/dev-server-stream-portscan.log"
HOST_SCAN_LOG="$LOG_DIR/dev-scan-stream-portscan.log"
SERVER_PID_FILE="$PID_DIR/dev-server-stream-portscan.pid"
SCAN_PID_FILE="$PID_DIR/dev-scan-stream-portscan.pid"

BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8080}"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-$BACKEND_URL}"
LOGIN_URL="$BACKEND_URL/api/user/login"
NODE_URL="$BACKEND_URL/api/node"
TEMPLATE_LIST_URL="$BACKEND_URL/api/task/template"
TEMPLATE_SAVE_URL="$BACKEND_URL/api/task/template/save"
TASK_ADD_URL="$BACKEND_URL/api/task/add"
TASK_LIST_URL="$BACKEND_URL/api/task/"
TASK_PROGRESS_URL="$BACKEND_URL/api/task/progress/info"
CHUNK_SUMMARY_URL="$BACKEND_URL/api/task/stream/portscan/summary"

USERNAME="${USERNAME:-ScopeSentry}"
REDIS_IP="${REDIS_IP:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-redis_password}"
PASSWORD_FILE="$SERVER_RUNTIME_DIR/PASSWORD"
SCAN_DRIVER="${SCAN_DRIVER:-host}"
SCAN_DOCKER_CONTAINER_NAME="${SCAN_DOCKER_CONTAINER_NAME:-scopesentry-scan-dev}"
STREAM_SMOKE_STAMP="${STREAM_SMOKE_STAMP:-$(date '+%Y%m%d-%H%M%S')}"
NODE_NAME_FROM_ENV="${NODE_NAME:-}"
NODE_NAME="${NODE_NAME:-local-dev-node-stream-portscan-$STREAM_SMOKE_STAMP}"
TEMPLATE_PREFIX="${TEMPLATE_PREFIX:-stream-portscan-smoke-$STREAM_SMOKE_STAMP}"
TASK_PREFIX="${TASK_PREFIX:-stream-portscan-smoke-task-$STREAM_SMOKE_STAMP}"

RUSTSCAN_PLUGIN="${RUSTSCAN_PLUGIN:-66b4ddeb983387df2b7ee7726653874d}"
NAABU_PLUGIN="${NAABU_PLUGIN:-c9b9d0f6f1e74a4f9a3b2c1d5e6f7081}"
PORTSCAN_PLUGINS=("$RUSTSCAN_PLUGIN" "$NAABU_PLUGIN")
NON_FULL_PORT_RANGE="${NON_FULL_PORT_RANGE:-80,443}"
FULL_PORT_RANGE="${FULL_PORT_RANGE:-1-65535}"
CHUNK_TIMEOUT_SECONDS="${CHUNK_TIMEOUT_SECONDS:-180}"
SUCCESS_TIMEOUT_SECONDS="${SUCCESS_TIMEOUT_SECONDS:-600}"
PORTSCAN_SMOKE_FAKE_TOOLS="${PORTSCAN_SMOKE_FAKE_TOOLS:-true}"
PORTSCAN_SMOKE_RESET_STREAM="${PORTSCAN_SMOKE_RESET_STREAM:-true}"
HOST_SCAN_PATH_PREFIX="$HOST_SCAN_RUNTIME_DIR/ext/naabu:$HOST_SCAN_RUNTIME_DIR/ext/gogo"

mkdir -p "$LOG_DIR" "$PID_DIR" "$LOCAL_DEV_DIR"

log() {
  printf '[portscan-stream-smoke] %s\n' "$*"
}

fail() {
  printf '[portscan-stream-smoke] FAIL: %s\n' "$*" >&2
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

make_targets() {
  local count="$1"
  local base="${2:-127.0.0}"
  local targets=()
  local i
  for ((i = 1; i <= count; i++)); do
    targets+=("$base.$i")
  done
  printf '%s\n' "${targets[@]}"
}

expected_chunks() {
  local target_count="$1"
  local plugin_count="$2"
  local port_range="$3"
  if [[ "$port_range" == "1-65535" || "$port_range" == "0-65535" || "$port_range" == "all" ]]; then
    printf '%s\n' $((target_count * plugin_count))
    return
  fi
  printf '%s\n' $((((target_count + 9) / 10) * plugin_count))
}

build_template_payload() {
  local name="$1"
  local port_range="$2"
  python3 - "$name" "$port_range" "${PORTSCAN_PLUGINS[@]}" <<'PY'
import json
import sys

name = sys.argv[1]
port_range = sys.argv[2]
plugins = sys.argv[3:]
modules = [
    "TargetHandler", "SubdomainScan", "SubdomainSecurity", "PortScanPreparation",
    "PortScan", "PortFingerprint", "AssetMapping", "AssetHandle", "URLScan",
    "WebCrawler", "URLSecurity", "DirScan", "VulnerabilityScan", "PassiveScan",
]
params = {module: {} for module in modules}
parameter_lists = {module: {} for module in modules}
for plugin in plugins:
    params["PortScan"][plugin] = f"-port {port_range}"

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
    "SubdomainScan": [],
    "SubdomainSecurity": [],
    "PortScanPreparation": [],
    "PortScan": plugins,
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
  local target_file="$2"
  local template_id="$3"
  python3 - "$name" "$target_file" "$template_id" "$NODE_NAME" <<'PY'
import json
import sys
from pathlib import Path

name, target_file, template_id, node_name = sys.argv[1:]
target = Path(target_file).read_text(encoding="utf-8").strip()
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
    log "backend already reachable; ensure it was started with STREAM_PORTSCAN_ENABLED=true"
    return 0
  fi

  log "starting MongoDB and Redis"
  "$REPO_ROOT/scripts/dev-db-up.sh" >/dev/null

  log "starting backend with stream PortScan enabled"
  STREAM_PORTSCAN_ENABLED=true \
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
    log "starting docker scan node with stream mode"
    NODE_NAME="$NODE_NAME" \
      CONTAINER_NAME="$SCAN_DOCKER_CONTAINER_NAME" \
      TASK_MODE=stream \
      STREAM_PORTSCAN_ENABLED=true \
      ADAPTIVE_PULL_ENABLED="${ADAPTIVE_PULL_ENABLED:-false}" \
      "$REPO_ROOT/scripts/dev-scan-docker.sh" up >/dev/null
  else
    log "starting host scan node with stream mode"
    rm -f "$HOST_SCAN_RUNTIME_DIR/config/config.yaml"
    prepare_fake_portscan_tools
    NODE_NAME="$NODE_NAME" \
      NodeName="$NODE_NAME" \
      TASK_MODE=stream \
      STREAM_PORTSCAN_ENABLED=true \
      ADAPTIVE_PULL_ENABLED="${ADAPTIVE_PULL_ENABLED:-false}" \
      SCAN_RUNTIME_DIR="$HOST_SCAN_RUNTIME_DIR" \
      PATH="$HOST_SCAN_PATH_PREFIX:$PATH" \
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

reset_portscan_streams() {
  if [[ "$PORTSCAN_SMOKE_RESET_STREAM" != "true" ]]; then
    return 0
  fi

  log "resetting local PortScan stream keys"
  local keys=(scan:stream:PortScan scan:stream:PortScan:dlq)
  if command -v redis-cli >/dev/null 2>&1; then
    redis-cli -h "$REDIS_IP" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning DEL "${keys[@]}" >/dev/null && return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx 'scopesentry-redis'; then
    docker exec scopesentry-redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning DEL "${keys[@]}" >/dev/null && return 0
  fi
  fail "failed to reset PortScan stream keys; set PORTSCAN_SMOKE_RESET_STREAM=false to skip"
}

prepare_fake_portscan_tools() {
  if [[ "$PORTSCAN_SMOKE_FAKE_TOOLS" != "true" ]]; then
    return 0
  fi

  log "installing fake PortScan tools for deterministic smoke"
  mkdir -p "$HOST_SCAN_RUNTIME_DIR/ext/rustscan" "$HOST_SCAN_RUNTIME_DIR/ext/naabu"

  cat >"$HOST_SCAN_RUNTIME_DIR/ext/rustscan/rustscan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

target="127.0.0.1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a)
      target="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'Open %s:80\n' "$target"
SH
  chmod +x "$HOST_SCAN_RUNTIME_DIR/ext/rustscan/rustscan"

  cat >"$HOST_SCAN_RUNTIME_DIR/ext/naabu/naabu" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

target="127.0.0.1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -host)
      target="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '{"host":"%s","ip":"%s","port":443}\n' "$target" "$target"
SH
  chmod +x "$HOST_SCAN_RUNTIME_DIR/ext/naabu/naabu"
}

create_template() {
  local token="$1"
  local name="$2"
  local port_range="$3"
  local payload list_response template_id
  payload="$(build_template_payload "$name" "$port_range")"
  api_post "$TEMPLATE_SAVE_URL" "$token" "$payload" >/dev/null
  list_response="$(api_post "$TEMPLATE_LIST_URL" "$token" "{\"pageIndex\":1,\"pageSize\":20,\"query\":\"$name\"}")"
  template_id="$(printf '%s' "$list_response" | json_path "data.list.0.id")"
  [[ -n "$template_id" ]] || fail "failed to resolve template id for $name: $list_response"
  printf '%s' "$template_id"
}

create_task() {
  local token="$1"
  local name="$2"
  local target_file="$3"
  local template_id="$4"
  local payload response code
  payload="$(build_task_payload "$name" "$target_file" "$template_id")"
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
  api_post "$CHUNK_SUMMARY_URL" "$token" "{\"taskId\":\"$task_id\"}"
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

wait_for_chunk_success() {
  local token="$1"
  local task_id="$2"
  local min_success="$3"
  local start_ts response success dlq
  start_ts="$(date +%s)"
  while true; do
    response="$(chunk_summary "$token" "$task_id")"
    success="$(printf '%s' "$response" | json_path "data.success")"
    dlq="$(printf '%s' "$response" | json_path "data.dlq")"
    if [[ -n "$success" && "$success" -ge "$min_success" ]]; then
      printf '%s' "$response"
      return
    fi
    if (( "$(date +%s)" - start_ts >= SUCCESS_TIMEOUT_SECONDS )); then
      fail "expected at least $min_success successful chunk for $task_id, success=${success:-empty}, dlq=${dlq:-empty}: $response"
    fi
    sleep 5
  done
}

assert_progress_has_chunk_summary() {
  local token="$1"
  local task_id="$2"
  local response total
  response="$(api_post "$TASK_PROGRESS_URL" "$token" "{\"id\":\"$task_id\",\"pageIndex\":1,\"pageSize\":10}")"
  total="$(printf '%s' "$response" | json_path "data.portScanChunks.total")"
  [[ -n "$total" && "$total" != "0" ]] || fail "progress response is missing portScanChunks: $response"
}

run_case() {
  local token="$1"
  local label="$2"
  local target_count="$3"
  local port_range="$4"
  local expected_total="$5"
  local target_file="$LOCAL_DEV_DIR/$label-targets.txt"
  local template_name="$TEMPLATE_PREFIX-$label"
  local task_name="$TASK_PREFIX-$label"
  local template_id task_id summary

  make_targets "$target_count" >"$target_file"
  template_id="$(create_template "$token" "$template_name" "$port_range")"
  create_task "$token" "$task_name" "$target_file" "$template_id"
  task_id="$(wait_for_task_id "$token" "$task_name")"
  summary="$(wait_for_chunk_total "$token" "$task_id" "$expected_total")"
  assert_progress_has_chunk_summary "$token" "$task_id"

  printf '%s_task_id=%s\n' "$label" "$task_id"
  printf '%s_expected_chunks=%s\n' "$label" "$expected_total"
  printf '%s_chunk_summary=%s\n' "$label" "$summary"
}

dry_run() {
  local non_full_expected full_expected payload plugin_count
  plugin_count="${#PORTSCAN_PLUGINS[@]}"
  non_full_expected="$(expected_chunks 21 "$plugin_count" "$NON_FULL_PORT_RANGE")"
  full_expected="$(expected_chunks 3 "$plugin_count" "$FULL_PORT_RANGE")"
  [[ "$non_full_expected" == "6" ]] || fail "non-full chunk math expected 6, got $non_full_expected"
  [[ "$full_expected" == "6" ]] || fail "full-port chunk math expected 6, got $full_expected"
  [[ "$HOST_SCAN_RUNTIME_DIR" == *stream-portscan* ]] || fail "host scan runtime must be isolated for stream smoke"
  [[ "${PORTSCAN_SMOKE_FAKE_TOOLS:-}" == "true" ]] || fail "stream smoke should default to fake PortScan tools"
  [[ "${PORTSCAN_SMOKE_RESET_STREAM:-}" == "true" ]] || fail "stream smoke should reset local PortScan stream by default"
  [[ "${HOST_SCAN_PATH_PREFIX:-}" == "$HOST_SCAN_RUNTIME_DIR/ext/naabu:$HOST_SCAN_RUNTIME_DIR/ext/gogo" ]] || fail "fake tool path prefix should win before system PATH"
  if [[ -z "$NODE_NAME_FROM_ENV" ]]; then
    [[ "$NODE_NAME" == *"$STREAM_SMOKE_STAMP"* ]] || fail "default node name should include the smoke stamp"
  fi
  payload="$(build_template_payload "dry-run-template" "$NON_FULL_PORT_RANGE")"
  PAYLOAD="$payload" python3 - "${PORTSCAN_PLUGINS[@]}" "$NON_FULL_PORT_RANGE" <<'PY'
import json
import os
import sys

plugins = sys.argv[1:-1]
port_range = sys.argv[-1]
payload = json.loads(os.environ["PAYLOAD"])
template = payload["result"]
if template["PortScan"] != plugins:
    raise SystemExit(f"unexpected PortScan plugins: {template['PortScan']}")
for plugin in plugins:
    expected = f"-port {port_range}"
    got = template["Parameters"]["PortScan"].get(plugin)
    if got != expected:
        raise SystemExit(f"unexpected port parameter for {plugin}: {got}")
PY
  printf 'portscan stream chunk smoke dry-run passed\n'
}

main() {
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run
    return
  fi

  local plugin_count non_full_expected full_expected token non_full_task_id
  plugin_count="${#PORTSCAN_PLUGINS[@]}"
  non_full_expected="$(expected_chunks 21 "$plugin_count" "$NON_FULL_PORT_RANGE")"
  full_expected="$(expected_chunks 3 "$plugin_count" "$FULL_PORT_RANGE")"

  log "starting stream PortScan smoke"
  log "scan_driver=$SCAN_DRIVER node=$NODE_NAME plugins=$plugin_count non_full_expected=$non_full_expected full_expected=$full_expected"

  start_backend_if_needed
  reset_portscan_streams
  token="$(login_and_get_token)"
  start_scan_if_needed "$token"

  run_case "$token" "nonfull" 21 "$NON_FULL_PORT_RANGE" "$non_full_expected"
  non_full_task_id="$(lookup_task_id "$token" "$TASK_PREFIX-nonfull")"
  wait_for_chunk_success "$token" "$non_full_task_id" 1 >/dev/null

  run_case "$token" "full" 3 "$FULL_PORT_RANGE" "$full_expected"

  printf 'portscan stream chunk smoke passed\n'
}

main "$@"
