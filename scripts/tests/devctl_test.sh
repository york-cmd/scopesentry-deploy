#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVCTL="$REPO_ROOT/devctl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file: $path"
}

assert_dir() {
  local path="$1"
  [[ -d "$path" ]] || fail "expected directory: $path"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "expected '$needle' in $file"
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "did not expect '$needle' in $file"
  fi
}

assert_not_exists() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "expected missing path: $path"
}

make_stub_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat >"$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${DEVCTL_TEST_STATE_DIR:?missing DEVCTL_TEST_STATE_DIR}"
cmd="${1:-}"
shift || true

mark_running() {
  local name="$1"
  touch "$state_dir/${name}.running"
}

clear_running() {
  local name="$1"
  rm -f "$state_dir/${name}.running"
  if [[ "$name" == "scopesentry-redis" ]]; then
    rm -f "$state_dir/tcp-127.0.0.1-${SCAN_REDIS_PORT:-46379}.ready"
  fi
}

is_running() {
  local name="$1"
  [[ -f "$state_dir/${name}.running" ]]
}

image_marker_path() {
  local image="$1"
  local safe="${image//\//_}"
  safe="${safe//:/_}"
  printf '%s/image.%s\n' "$state_dir" "$safe"
}

image_exists() {
  local image="$1"
  if [[ "$image" == "autumn27/scopesentry-scan:latest" ]]; then
    return 0
  fi
  [[ -f "$(image_marker_path "$image")" ]]
}

mark_image() {
  local image="$1"
  touch "$(image_marker_path "$image")"
}

mongo_health() {
  local count_file="$state_dir/mongo.inspect.count"
  local count=0
  if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
  fi
  count=$((count + 1))
  printf '%s' "$count" >"$count_file"
  if (( count >= 3 )); then
    touch "$state_dir/mongo.ready"
    printf 'healthy\n'
  else
    printf 'starting\n'
  fi
}

case "$cmd" in
  compose)
    if [[ "${1:-}" == "version" ]]; then
      if [[ -f "$state_dir/docker.compose.version.fail" ]]; then
        printf 'docker compose unavailable\n' >&2
        exit 1
      fi
      printf 'Docker Compose version v2.0.0\n'
      exit 0
    fi

    compose_files=()
    env_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --env-file)
          env_file="$2"
          shift 2
          ;;
        -f)
          compose_files+=("$2")
          shift 2
          ;;
        *)
          break
          ;;
      esac
    done

    action="${1:-}"
    shift || true
    compose_name=""
    for file in "${compose_files[@]}"; do
      case "$(basename "$file")" in
        single-host-deployment.yml)
          compose_name="single-host-deployment.yml"
          ;;
        dev-scan-docker-compose.yml)
          compose_name="dev-scan-docker-compose.yml"
          ;;
      esac
    done

    case "$compose_name:$action" in
      single-host-deployment.yml:up)
        if [[ -f "$state_dir/db.compose.port_conflict" ]]; then
          port="$(cat "$state_dir/db.compose.port_conflict")"
          printf 'Error response from daemon: driver failed programming external connectivity on endpoint scopesentry-mongodb (test): Bind for 0.0.0.0:%s failed: port is already allocated\n' "$port" >&2
          exit 1
        fi
        if [[ -f "$state_dir/db.compose.fail" ]]; then
          printf 'db compose failed\n' >&2
          exit 1
        fi
        mark_running "scopesentry-mongodb"
        mark_running "scopesentry-redis"
        touch "$state_dir/tcp-127.0.0.1-${SCAN_REDIS_PORT:-46379}.ready"
        ;;
      single-host-deployment.yml:stop)
        if [[ ! -f "$state_dir/db.stop.sticky" ]]; then
          clear_running "scopesentry-mongodb"
          clear_running "scopesentry-redis"
        fi
        ;;
      single-host-deployment.yml:logs|single-host-deployment.yml:ps)
        ;;
      dev-scan-docker-compose.yml:up)
        scan_image=""
        if [[ -n "$env_file" && -f "$env_file" ]]; then
          scan_image="$(grep '^SCAN_IMAGE=' "$env_file" | head -n1 | cut -d= -f2-)"
        fi
        if [[ -n "$scan_image" ]] && ! image_exists "$scan_image"; then
          printf 'scan image missing: %s\n' "$scan_image" >&2
          exit 1
        fi
        mark_running "scopesentry-scan-dev"
        ;;
      dev-scan-docker-compose.yml:down)
        if [[ ! -f "$state_dir/scan.stop.sticky" ]]; then
          clear_running "scopesentry-scan-dev"
        fi
        ;;
      dev-scan-docker-compose.yml:logs|dev-scan-docker-compose.yml:ps)
        ;;
      *)
        ;;
    esac
    ;;
  ps)
    if [[ -f "$state_dir/docker.daemon.down" ]]; then
      printf 'cannot connect to docker daemon\n' >&2
      exit 1
    fi
    filter_publish=""
    if [[ "${1:-}" == "-a" ]]; then
      shift
    fi
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --filter)
          if [[ "${2:-}" == publish=* ]]; then
            filter_publish="${2#publish=}"
          fi
          shift 2
          ;;
        --format)
          break
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ "${1:-}" == "--format" ]]; then
      if [[ -n "$filter_publish" ]]; then
        owner_file="$state_dir/docker.publish.${filter_publish}.owner"
        if [[ -f "$owner_file" ]]; then
          cat "$owner_file"
        fi
        exit 0
      fi
      for name in scopesentry-mongodb scopesentry-redis scopesentry-scan-dev; do
        if is_running "$name"; then
          printf '%s\n' "$name"
        fi
      done
    fi
    ;;
  inspect)
    if [[ -f "$state_dir/docker.daemon.down" ]]; then
      printf 'cannot inspect docker state\n' >&2
      exit 1
    fi
    if [[ "${1:-}" != "--format" ]]; then
      exit 1
    fi
    format="$2"
    name="$3"
    case "$format" in
      *Health.Status*)
        case "$name" in
          scopesentry-mongodb)
            mongo_health
            ;;
          scopesentry-redis)
            if is_running "$name"; then
              printf 'healthy\n'
            else
              printf 'unhealthy\n'
            fi
            ;;
          *)
            if is_running "$name"; then
              printf 'healthy\n'
            else
              printf 'unhealthy\n'
            fi
            ;;
        esac
        ;;
      *State.Running*)
        if is_running "$name"; then
          printf 'true\n'
        else
          printf 'false\n'
        fi
        ;;
      *State.Status*)
        if is_running "$name"; then
          printf 'running\n'
        else
          printf 'exited\n'
        fi
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  rm)
    if [[ "${1:-}" == "-f" ]]; then
      shift
      : > /dev/null
      for name in "$@"; do
        clear_running "$name"
        printf '%s\n' "$name" >>"$state_dir/docker.rm.calls"
      done
    fi
    ;;
  logs)
    exit 0
    ;;
  build)
    printf '%s\n' "$*" >>"$state_dir/docker.build.raw.calls"
    attempt_file="$state_dir/docker.build.attempts"
    attempt_count=0
    if [[ -f "$attempt_file" ]]; then
      attempt_count="$(cat "$attempt_file")"
    fi
    attempt_count=$((attempt_count + 1))
    printf '%s' "$attempt_count" >"$attempt_file"
    image_tag=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t)
          image_tag="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ -f "$state_dir/docker.build.fail_once" && "$attempt_count" -eq 1 ]]; then
      printf 'failed to solve: golang:1.24-bookworm: failed to authorize: failed to fetch anonymous token: Get "https://auth.docker.io/token": dial tcp 98.159.108.71:443: i/o timeout\n' >&2
      exit 1
    fi
    if [[ -n "$image_tag" ]]; then
      mark_image "$image_tag"
      printf '%s\n' "$image_tag" >>"$state_dir/docker.build.calls"
    fi
    exit 0
    ;;
  image)
    subcmd="${1:-}"
    shift || true
    case "$subcmd" in
      inspect)
        image="${1:-}"
        if image_exists "$image"; then
          printf '[{"Id":"sha256:test"}]\n'
          exit 0
        fi
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  exec)
    if [[ "${1:-}" == "scopesentry-mongodb" && "$*" == *"mongosh --quiet"* && "$*" == *"updateOne("* ]]; then
      printf '%s\n' "$*" >"$state_dir/local.mongosh.last"
      exit 0
    fi
    exit 0
    ;;
  images)
    if [[ "${1:-}" == "--format" ]]; then
      if image_exists "autumn27/scopesentry-scan:latest"; then
        printf 'autumn27/scopesentry-scan:latest test-image 1 day ago\n'
      fi
      if image_exists "scopesentry-scan-dev:local"; then
        printf 'scopesentry-scan-dev:local test-local-image just now\n'
      fi
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  cat >"$bin_dir/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${DEVCTL_TEST_STATE_DIR:?missing DEVCTL_TEST_STATE_DIR}"
project_root="${DEVCTL_ROOT_DIR:?missing DEVCTL_ROOT_DIR}"
printf '%s\n' "$*" >>"$state_dir/go.build.calls"

output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$output" ]] || exit 1
mkdir -p "$(dirname "$output")"

entry_asset="$(grep -Eo '/assets/[^"]+\.js' "$project_root/ScopeSentry/cmd/main/static/index.html" | head -n 1)"
[[ -n "$entry_asset" ]] || { printf 'missing entry asset in static index.html\n' >&2; exit 1; }

cat >"$output" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${DEVCTL_TEST_STATE_DIR:?missing DEVCTL_TEST_STATE_DIR}"
ready_file="$state_dir/http-8082.ready"
runtime_dir="$(cd "$(dirname "$0")" && pwd)"
entry_asset="__ENTRY_ASSET__"

cleanup() {
  rm -f "$ready_file"
  rm -f "$state_dir/server.root.asset"
  exit 0
}

trap cleanup EXIT INT TERM

if [[ ! -f "$state_dir/mongo.ready" ]]; then
  printf 'early-start\n' >>"$state_dir/server.start.events"
  exit 42
fi

if [[ -f "$state_dir/server.exit_immediately" ]]; then
  printf 'simulated backend crash\n' >&2
  exit 72
fi

printf 'server-generated-password' >"$runtime_dir/PASSWORD"
printf '%s' "$entry_asset" >"$state_dir/server.root.asset"
touch "$ready_file"
while true; do
  sleep 1
done
INNER

  python3 - "$output" "$entry_asset" <<'PY'
import sys

path, entry_asset = sys.argv[1:3]
content = open(path, "r", encoding="utf-8").read()
content = content.replace("__ENTRY_ASSET__", entry_asset)
open(path, "w", encoding="utf-8").write(content)
PY

chmod +x "$output"
EOF

  cat >"$bin_dir/pnpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${DEVCTL_TEST_STATE_DIR:?missing DEVCTL_TEST_STATE_DIR}"
cmd="${1:-}"
printf '%s\n' "$*" >>"$state_dir/pnpm.calls"

case "$cmd" in
  install)
    mkdir -p node_modules/.pnpm
    ;;
  dev|vite)
    port="4000"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --port)
          port="${2:-4000}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    ready_file="$state_dir/http-${port}.ready"
    cleanup() {
      rm -f "$ready_file"
      exit 0
    }
    trap cleanup EXIT INT TERM
    touch "$ready_file"
    while true; do
      sleep 1
    done
    ;;
  *)
    ;;
esac
EOF

  cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${DEVCTL_TEST_STATE_DIR:?missing DEVCTL_TEST_STATE_DIR}"
output_file=""
fsS=0
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -fsS)
      fsS=1
      shift
      ;;
    -o)
      output_file="${2:-}"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  printf 'fake-oneforall-archive' >"$output_file"
  exit 0
fi

if [[ "$fsS" == "1" ]]; then
  case "$url" in
    *127.0.0.1:8082/)
      if [[ -f "$state_dir/deploy.remote.root.fail" ]]; then
        exit 22
      fi
      root_asset="/assets/index-test.js"
      if [[ -f "$state_dir/server.root.asset.override" ]]; then
        root_asset="$(cat "$state_dir/server.root.asset.override")"
      elif [[ -f "$state_dir/server.root.asset" ]]; then
        root_asset="$(cat "$state_dir/server.root.asset")"
      fi
      cat <<INNER
<!doctype html>
<html lang="en">
  <head>
    <script type="module" crossorigin src="${root_asset}"></script>
  </head>
</html>
INNER
      exit 0
      ;;
    *127.0.0.1:8082/assets/*)
      [[ -f "$state_dir/deploy.remote.asset.fail" ]] && exit 22
      printf 'console.log("ok");\n'
      exit 0
      ;;
  esac
fi

case "$url" in
  *127.0.0.1:8082*)
    [[ -f "$state_dir/http-8082.ready" ]] && exit 0
    exit 22
    ;;
  *127.0.0.1:*)
    port="$(printf '%s' "$url" | sed -n 's#.*127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p')"
    [[ -n "$port" && -f "$state_dir/http-${port}.ready" ]] && exit 0
    exit 22
    ;;
  *)
    exit 0
    ;;
esac
EOF

  cat >"$bin_dir/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${DEVCTL_TEST_STATE_DIR:?missing DEVCTL_TEST_STATE_DIR}"
cmd="${*: -1}"
printf '%s\n' "$cmd" >>"$state_dir/ssh.calls"

consume_fail_count() {
  local counter_file="$1"
  local remaining="0"
  [[ -f "$counter_file" ]] || return 1
  remaining="$(cat "$counter_file")"
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining="0"
  if (( remaining <= 0 )); then
    return 1
  fi
  remaining=$((remaining - 1))
  printf '%s' "$remaining" >"$counter_file"
  return 0
}

if [[ "$cmd" == "docker restart scope-sentry scopesentry-scan" ]]; then
  printf 'restarted\n'
  exit 0
fi

if [[ "$cmd" == *"docker cp scope-sentry:/opt/ScopeSentry/PASSWORD"* || "$cmd" == *"docker cp scope-sentry:/opt/ScopeSentry/PLUGINKEY"* ]]; then
  if [[ "$cmd" == *"docker cp scope-sentry:/opt/ScopeSentry/PASSWORD"* && -f "$state_dir/deploy.container.password" ]]; then
    cp "$state_dir/deploy.container.password" "$state_dir/deploy.remote.password"
  fi
  if [[ "$cmd" == *"docker cp scope-sentry:/opt/ScopeSentry/PLUGINKEY"* && -f "$state_dir/deploy.container.pluginkey" ]]; then
    cp "$state_dir/deploy.container.pluginkey" "$state_dir/deploy.remote.pluginkey"
  fi
  exit 0
fi

if [[ "$cmd" == *"cat "*"/ScopeSentry/dist/ScopeSentry_linux_amd64_v1/PASSWORD"* ]]; then
  if [[ -f "$state_dir/deploy.remote.password" ]]; then
    cat "$state_dir/deploy.remote.password"
    exit 0
  fi
  exit 1
fi

if [[ "$cmd" == *"cat "*"/ScopeSentry/dist/ScopeSentry_linux_amd64_v1/PLUGINKEY"* ]]; then
  if [[ -f "$state_dir/deploy.remote.pluginkey" ]]; then
    cat "$state_dir/deploy.remote.pluginkey"
    exit 0
  fi
  exit 1
fi

if [[ "$cmd" == *"docker exec scopesentry-mongodb mongosh --quiet"* && "$cmd" == *"updateOne("* ]]; then
  printf '%s\n' "$cmd" >"$state_dir/deploy.mongosh.last"
  exit 0
fi

if [[ "$cmd" == *"printf '%s' "* && "$cmd" == *"/ScopeSentry/dist/ScopeSentry_linux_amd64_v1/PASSWORD"* ]]; then
  password="$(printf '%s' "$cmd" | sed -n "s/.*printf '%s' '\\([^']*\\)'.*/\\1/p")"
  if [[ -n "$password" ]]; then
    printf '%s' "$password" >"$state_dir/deploy.remote.password"
    exit 0
  fi
fi

if [[ "$cmd" == *"curl -fsS http://127.0.0.1:8082/"* ]]; then
  if consume_fail_count "$state_dir/deploy.remote.root.fail.count"; then
    exit 56
  fi
  if [[ -f "$state_dir/deploy.remote.root.fail" ]]; then
    exit 22
  fi
  exit 0
fi

exit 0
EOF

  cat >"$bin_dir/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${DEVCTL_TEST_STATE_DIR:?missing DEVCTL_TEST_STATE_DIR}"
printf '%s\n' "$*" >>"$state_dir/rsync.calls"
exit 0
EOF

  cat >"$bin_dir/lsof-stub" <<'EOF'
#!/usr/bin/env bash
# Deterministic stub: always report "no listener" so the test doesn't
# depend on whatever the host machine happens to have bound.
exit 1
EOF

  cat >"$bin_dir/pgrep-stub" <<'EOF'
#!/usr/bin/env bash
# Stub: never match any running process.
exit 1
EOF

  chmod +x "$bin_dir/docker" "$bin_dir/go" "$bin_dir/pnpm" "$bin_dir/curl" \
    "$bin_dir/ssh" "$bin_dir/rsync" "$bin_dir/lsof-stub" "$bin_dir/pgrep-stub"
}

make_fake_project() {
  local root="$1"
  mkdir -p \
    "$root/ScopeSentry/cmd/main/static/assets" \
    "$root/ScopeSentry-UI" \
    "$root/ScopeSentry-Scan" \
    "$root/scripts"

  cat >"$root/ScopeSentry/single-host-deployment.yml" <<'EOF'
services:
  mongodb: {}
  redis: {}
EOF

  cat >"$root/scripts/dev-scan-docker-compose.yml" <<'EOF'
services:
  scan: {}
EOF

  cat >"$root/ScopeSentry/cmd/main/static/index.html" <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <script type="module" crossorigin src="/assets/index-test.js"></script>
  </head>
</html>
EOF

  cat >"$root/ScopeSentry/cmd/main/static/assets/index-test.js" <<'EOF'
console.log('index-test');
EOF
}

run_devctl() {
  local root="$1"
  local bin_dir="$2"
  local state_dir="$3"
  shift 3

  PATH="$bin_dir:$PATH" \
  DEVCTL_ROOT_DIR="$root" \
  DEVCTL_TEST_STATE_DIR="$state_dir" \
  SCAN_REDIS_PORT=46379 \
  LSOF_BIN="$bin_dir/lsof-stub" \
  PGREP_BIN="$bin_dir/pgrep-stub" \
  "$DEVCTL" "$@"
}

test_install_generates_env_and_manifest() {
  local tmp_root stub_bin state_dir manifest_file env_file devctl_env_file db_override_file
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/tmp/devctl-install.out 2>/tmp/devctl-install.err

  env_file="$tmp_root/ScopeSentry/.env"
  manifest_file="$tmp_root/.local-dev/state/manifest.json"
  devctl_env_file="$tmp_root/.local-dev/env/devctl.env"
  db_override_file="$tmp_root/.local-dev/runtime/db-docker-compose.override.yml"

  assert_file "$env_file"
  assert_file "$manifest_file"
  assert_file "$devctl_env_file"
  assert_file "$db_override_file"
  assert_contains "MONGO_INITDB_ROOT_USERNAME=admin" "$env_file"
  assert_contains "SCAN_IMAGE=scopesentry-scan-dev:local" "$devctl_env_file"
  assert_contains "\"api_url\": \"http://127.0.0.1:8082\"" "$manifest_file"
  assert_contains "\"ui_url\": \"http://127.0.0.1:4000\"" "$manifest_file"
  assert_contains "shutdown-on-sigterm" "$db_override_file"
  assert_contains "nosave" "$db_override_file"
  assert_contains "disable: true" "$db_override_file"
}

test_install_migrates_official_scan_default_to_local() {
  local tmp_root stub_bin state_dir devctl_env_dir devctl_env_file
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  devctl_env_dir="$tmp_root/.local-dev/env"
  devctl_env_file="$devctl_env_dir/devctl.env"
  mkdir -p "$devctl_env_dir"
  cat >"$devctl_env_file" <<'EOF'
API_URL=http://127.0.0.1:8082
UI_URL=http://127.0.0.1:4000
NODE_NAME=local-dev-node-docker
SCAN_IMAGE=autumn27/scopesentry-scan:latest
LOCAL_SCAN_IMAGE=scopesentry-scan-dev:local
SCAN_CONTAINER_NAME=scopesentry-scan-dev
TIMEZONE=Asia/Shanghai
PROFILE_NAME=local-hybrid
EOF

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null

  assert_contains "SCAN_IMAGE=scopesentry-scan-dev:local" "$devctl_env_file"
  assert_not_contains "SCAN_IMAGE=autumn27/scopesentry-scan:latest" "$devctl_env_file"
}

test_doctor_reports_healthy_environment() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" doctor 2>&1)" || true

  [[ "$output" == *"PASS repo_layout:"* ]] || fail "expected repo layout pass in doctor output"
  [[ "$output" == *"PASS docker_cli:"* ]] || fail "expected docker cli pass in doctor output"
  [[ "$output" == *"PASS docker_daemon:"* ]] || fail "expected docker daemon pass in doctor output"
}

test_doctor_warns_about_bridge_scan_network_for_masscan() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" doctor 2>&1)" || true

  [[ "$output" == *"WARN scan_network_mode:"* ]] || fail "expected scan network mode warning in doctor output"
  [[ "$output" == *"masscan"* ]] || fail "expected masscan explanation in doctor output"
}

test_doctor_reports_docker_daemon_failure_with_hint() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  touch "$state_dir/docker.daemon.down"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" doctor 2>&1)" || true

  [[ "$output" == *"FAIL docker_daemon:"* ]] || fail "expected docker daemon failure in doctor output"
  [[ "$output" == *"提示: 启动 Docker"* ]] || fail "expected docker hint in doctor output"
}

test_up_waits_for_mongo_before_starting_server() {
  local tmp_root stub_bin state_dir status_output password_file
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  run_devctl "$tmp_root" "$stub_bin" "$state_dir" up >/tmp/devctl-up.out

  password_file="$tmp_root/.local-dev/runtime/server/PASSWORD"
  status_output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" status)"

  assert_file "$password_file"
  [[ ! -f "$state_dir/server.start.events" ]] || fail "server started before mongo was ready"
  [[ "$status_output" == *"DB: 运行中"* ]] || fail "expected db running in status"
  [[ "$status_output" == *"后端: 运行中"* ]] || fail "expected server running in status"
  [[ "$status_output" == *"UI 服务: 运行中"* ]] || fail "expected ui running in status"
  [[ "$status_output" == *"扫描端: 运行中"* ]] || fail "expected scan running in status"
}

test_up_keeps_server_running_after_parent_process_group_exits() {
  local tmp_root stub_bin state_dir status_output wrapper_script
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null

  wrapper_script="$tmp_root/run-up-with-group-cleanup.sh"
  cat >"$wrapper_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
PATH="$stub_bin:\$PATH" \
DEVCTL_ROOT_DIR="$tmp_root" \
DEVCTL_TEST_STATE_DIR="$state_dir" \
  SCAN_REDIS_PORT=46379 \
"$DEVCTL" up >/dev/null
EOF
  chmod +x "$wrapper_script"

  python3 - "$wrapper_script" <<'PY'
import os
import signal
import subprocess
import sys

wrapper = sys.argv[1]
proc = subprocess.Popen([wrapper], start_new_session=True)
exit_code = proc.wait()
try:
    os.killpg(proc.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
raise SystemExit(exit_code)
PY
  sleep 1

  status_output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" status)"

  [[ "$status_output" == *"后端: 运行中"* ]] || fail "expected detached server to survive wrapper process-group cleanup"
}

test_up_builds_local_scan_image_when_missing() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" up 2>&1)"

  assert_file "$state_dir/docker.build.calls"
  assert_contains "scopesentry-scan-dev:local" "$state_dir/docker.build.calls"
  [[ "$output" == *"未找到 scan 镜像 scopesentry-scan-dev:local，开始构建本地镜像"* ]] || fail "expected lazy local scan image build output"
}

test_up_skips_scan_build_when_local_image_exists() {
  local tmp_root stub_bin state_dir
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  touch "$state_dir/image.scopesentry-scan-dev_local"
  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  run_devctl "$tmp_root" "$stub_bin" "$state_dir" up >/dev/null

  assert_not_exists "$state_dir/docker.build.calls"
}

test_up_prints_detailed_progress_messages() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  output="$(DEVCTL_PROGRESS_INTERVAL=1 run_devctl "$tmp_root" "$stub_bin" "$state_dir" up 2>&1)"

  [[ "$output" == *"[1/4] 阶段 db: 启动数据库"* ]] || fail "expected db stage start output"
  [[ "$output" == *"等待 db:"* ]] || fail "expected db waiting heartbeat output"
  [[ "$output" == *"[1/4] 阶段 db: 就绪"* ]] || fail "expected db ready output"
  [[ "$output" == *"[2/4] 阶段 server: 编译并启动后端"* ]] || fail "expected server stage start output"
  [[ "$output" == *"[3/4] 阶段 ui: 启动 pnpm dev"* ]] || fail "expected ui stage start output"
  [[ "$output" == *"[4/4] 阶段 scan: 启动扫描容器"* ]] || fail "expected scan stage start output"
}

test_up_starts_ui_with_strict_configured_port() {
  local tmp_root stub_bin state_dir
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  UI_URL=http://127.0.0.1:4100 run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  UI_URL=http://127.0.0.1:4100 run_devctl "$tmp_root" "$stub_bin" "$state_dir" up >/dev/null

  assert_file "$state_dir/pnpm.calls"
  assert_contains "vite --mode base --port 4100 --strictPort" "$state_dir/pnpm.calls"
}

test_up_fails_fast_when_backend_process_exits_before_readiness() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  touch "$state_dir/server.exit_immediately"

  output="$(DEVCTL_PROGRESS_INTERVAL=1 run_devctl "$tmp_root" "$stub_bin" "$state_dir" up 2>&1)" || true

  [[ "$output" == *"启动失败于阶段: server"* ]] || fail "expected server startup failure output"
  [[ "$output" == *"原因: 后端进程在就绪检查完成前退出"* ]] || fail "expected early backend exit reason"
  [[ "$output" == *"simulated backend crash"* ]] || fail "expected backend log excerpt in failure output"
}

test_up_restarts_server_when_embedded_ui_changes() {
  local tmp_root stub_bin state_dir output first_pid second_pid root_html
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  run_devctl "$tmp_root" "$stub_bin" "$state_dir" up >/dev/null
  first_pid="$(cat "$tmp_root/.local-dev/pids/dev-server.pid")"

  cat >"$tmp_root/ScopeSentry/cmd/main/static/index.html" <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <script type="module" crossorigin src="/assets/index-v2.js"></script>
  </head>
</html>
EOF
  cat >"$tmp_root/ScopeSentry/cmd/main/static/assets/index-v2.js" <<'EOF'
console.log('index-v2');
EOF

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" up 2>&1)"
  second_pid="$(cat "$tmp_root/.local-dev/pids/dev-server.pid")"
  root_html="$(DEVCTL_TEST_STATE_DIR="$state_dir" "$stub_bin/curl" -fsS http://127.0.0.1:8082/)"

  [[ "$first_pid" != "$second_pid" ]] || fail "expected server pid to change after embedded ui update"
  [[ "$(grep -c 'scope-sentry-dev .*./cmd/main$' "$state_dir/go.build.calls")" == "2" ]] || fail "expected backend server binary to be rebuilt twice"
  [[ "$output" == *"检测到嵌入前端静态资源变更"* ]] || fail "expected rebuild reason in output"
  [[ "$output" == *"强制净重编后端"* ]] || fail "expected forced clean rebuild output"
  [[ "$root_html" == *"/assets/index-v2.js"* ]] || fail "expected restarted backend to serve updated embedded entry asset"
}

test_up_fails_when_embedded_ui_root_asset_mismatches_disk() {
  local tmp_root stub_bin state_dir output status_output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  printf '%s' '/assets/index-stale.js' >"$state_dir/server.root.asset.override"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" up 2>&1)" || true
  status_output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" status)"

  [[ "$output" == *"启动失败于阶段: server"* ]] || fail "expected server stage failure on embedded ui mismatch"
  [[ "$output" == *"后端返回的嵌入前端入口与磁盘静态资源不一致"* ]] || fail "expected explicit embedded ui mismatch reason"
  [[ "$output" == *"expected=/assets/index-test.js actual=/assets/index-stale.js"* ]] || fail "expected mismatch details in output"
  [[ "$status_output" == *"后端: 已停止"* ]] || fail "expected mismatched backend process to be stopped"
}

test_status_ignores_stale_pid_files() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  mkdir -p "$tmp_root/.local-dev/pids"
  printf '%s' "$$" >"$tmp_root/.local-dev/pids/dev-server.pid"
  printf '%s' "$$" >"$tmp_root/.local-dev/pids/dev-ui.pid"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" status)"

  [[ "$output" == *"后端: 已停止"* ]] || fail "expected stale server pid to be ignored"
  [[ "$output" == *"UI 服务: 已停止"* ]] || fail "expected stale ui pid to be ignored"
}

test_down_force_removes_sticky_containers() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  run_devctl "$tmp_root" "$stub_bin" "$state_dir" up >/dev/null
  touch "$state_dir/db.stop.sticky" "$state_dir/scan.stop.sticky"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" down >/dev/null
  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" status)"

  [[ "$output" == *"DB: 已停止"* ]] || fail "expected db stopped after forced down"
  [[ "$output" == *"扫描端: 已停止"* ]] || fail "expected scan stopped after forced down"
  assert_file "$state_dir/docker.rm.calls"
  assert_contains "scopesentry-mongodb" "$state_dir/docker.rm.calls"
  assert_contains "scopesentry-redis" "$state_dir/docker.rm.calls"
  assert_contains "scopesentry-scan-dev" "$state_dir/docker.rm.calls"
}

test_clean_removes_transient_files_but_preserves_config() {
  local tmp_root stub_bin state_dir env_file password_file
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  mkdir -p "$tmp_root/.local-dev/runtime/server"
  printf 'server-generated-password' >"$tmp_root/.local-dev/runtime/server/PASSWORD"

  mkdir -p "$tmp_root/.local-dev/logs" "$tmp_root/.local-dev/pids" "$tmp_root/.local-dev/cache" "$tmp_root/.local-dev/runtime/tmp"
  touch "$tmp_root/.local-dev/logs/app.log" "$tmp_root/.local-dev/pids/app.pid" "$tmp_root/.local-dev/cache/cache.dat" "$tmp_root/.local-dev/runtime/tmp/file.tmp"

  env_file="$tmp_root/ScopeSentry/.env"
  password_file="$tmp_root/.local-dev/runtime/server/PASSWORD"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" clean >/dev/null

  assert_file "$env_file"
  assert_file "$password_file"
  assert_not_exists "$tmp_root/.local-dev/logs/app.log"
  assert_not_exists "$tmp_root/.local-dev/pids/app.pid"
  assert_not_exists "$tmp_root/.local-dev/cache/cache.dat"
  assert_not_exists "$tmp_root/.local-dev/runtime/tmp/file.tmp"
}

test_up_reports_db_stage_failure_with_logs_and_hint() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  touch "$state_dir/db.compose.fail"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" up 2>&1)" || true

  [[ "$output" == *"启动失败于阶段: db"* ]] || fail "expected startup stage in up failure output"
  [[ "$output" == *"最近日志 db"* ]] || fail "expected db log excerpt in up failure output"
  [[ "$output" == *"提示: 运行 ./devctl doctor"* ]] || fail "expected doctor hint in up failure output"
}

test_up_reports_explicit_port_conflict_details() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  printf '27017' >"$state_dir/db.compose.port_conflict"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" up 2>&1)" || true

  [[ "$output" == *"启动失败于阶段: db"* ]] || fail "expected startup stage in port conflict output"
  [[ "$output" == *"端口冲突: Docker 无法绑定主机端口 27017"* ]] || fail "expected explicit conflicting port in output"
  [[ "$output" == *"未在主机或发布的容器上找到占用端口 27017"* ]] || fail "expected stale docker reservation hint in output"
  [[ "$output" == *"重启 Docker Desktop 清除端口 27017 的陈旧预留"* ]] || fail "expected actionable stale reservation hint"
}

test_scan_rebuild_retries_transient_docker_build_timeout() {
  local tmp_root stub_bin state_dir output
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  # base 镜像已经存在（真实场景里 base 很少重建），重试场景仅作用于 app 层
  touch "$state_dir/image.scopesentry-scan-base_local"
  touch "$state_dir/docker.build.fail_once"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" scan rebuild 2>&1)"

  assert_file "$state_dir/docker.build.attempts"
  [[ "$(cat "$state_dir/docker.build.attempts")" == "2" ]] || fail "expected docker build to run twice"
  assert_file "$state_dir/docker.build.calls"
  assert_contains "scopesentry-scan-dev:local" "$state_dir/docker.build.calls"
  [[ "$output" == *"scan 镜像构建尝试 1/3"* ]] || fail "expected attempt log for first build"
  [[ "$output" == *"scan 镜像构建失败（1/3），"* ]] || fail "expected retry log after transient failure"
  [[ "$output" == *"scan 镜像构建尝试 2/3"* ]] || fail "expected second attempt log"
}

test_scan_rebuild_base_passes_configured_build_mirrors() {
  local tmp_root stub_bin state_dir
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  SCAN_APT_MIRROR=https://mirror.example/debian \
    SCAN_APT_SECURITY_MIRROR=https://mirror.example/debian-security \
    SCAN_PIP_INDEX_URL=https://mirror.example/pypi/simple \
    run_devctl "$tmp_root" "$stub_bin" "$state_dir" scan rebuild-base >/dev/null

  assert_file "$state_dir/docker.build.raw.calls"
  assert_contains "--build-arg APT_MIRROR=https://mirror.example/debian" "$state_dir/docker.build.raw.calls"
  assert_contains "--build-arg APT_SECURITY_MIRROR=https://mirror.example/debian-security" "$state_dir/docker.build.raw.calls"
  assert_contains "--build-arg PIP_INDEX_URL=https://mirror.example/pypi/simple" "$state_dir/docker.build.raw.calls"
}

test_scan_rebuild_passes_oneforall_build_sources() {
  local tmp_root stub_bin state_dir
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  touch "$state_dir/image.scopesentry-scan-base_local"
  SCAN_PIP_INDEX_URL=https://mirror.example/pypi/simple \
    ONEFORALL_ARCHIVE_URL=https://mirror.example/oneforall.tar.gz \
    run_devctl "$tmp_root" "$stub_bin" "$state_dir" scan rebuild >/dev/null

  assert_file "$state_dir/docker.build.raw.calls"
  assert_contains "--build-arg SCAN_BASE_IMAGE=scopesentry-scan-base:local" "$state_dir/docker.build.raw.calls"
  assert_contains "--build-arg ONEFORALL_ARCHIVE=third_party/oneforall.tar.gz" "$state_dir/docker.build.raw.calls"
  assert_contains "--build-arg PIP_INDEX_URL=https://mirror.example/pypi/simple" "$state_dir/docker.build.raw.calls"
}

test_scan_rebuild_reuses_existing_app_image_when_base_missing() {
  local tmp_root stub_bin state_dir
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  touch "$state_dir/image.scopesentry-scan-dev_local"
  run_devctl "$tmp_root" "$stub_bin" "$state_dir" scan rebuild >/dev/null

  assert_file "$state_dir/docker.build.raw.calls"
  assert_contains "--build-arg SCAN_BASE_IMAGE=scopesentry-scan-dev:local" "$state_dir/docker.build.raw.calls"
  assert_not_exists "$state_dir/image.scopesentry-scan-base_local"
}

test_deploy_reload_runs_remote_http_smoke_check() {
  local tmp_root stub_bin state_dir output deploy_conf
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  deploy_conf="$tmp_root/.local-dev/deploy.conf"
  mkdir -p "$(dirname "$deploy_conf")"
  cat >"$deploy_conf" <<'EOF'
DEPLOY_HOST=root@example.com
DEPLOY_PORT=22
DEPLOY_REMOTE_DIR=/opt/scopesentry-prod
EOF

  output="$(DEPLOY_HTTP_SMOKE_RETRY_DELAY=0 run_devctl "$tmp_root" "$stub_bin" "$state_dir" deploy reload 2>&1)"

  [[ "$output" == *"验证远端 HTTP"* ]] || fail "expected remote HTTP verify stage output"
  assert_file "$state_dir/ssh.calls"
  assert_contains "curl -fsS http://127.0.0.1:8082/" "$state_dir/ssh.calls"
}

test_deploy_reload_builds_server_package_instead_of_single_file() {
  local tmp_root stub_bin state_dir deploy_conf
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  deploy_conf="$tmp_root/.local-dev/deploy.conf"
  mkdir -p "$(dirname "$deploy_conf")"
  cat >"$deploy_conf" <<'EOF'
DEPLOY_HOST=root@example.com
DEPLOY_PORT=22
DEPLOY_REMOTE_DIR=/opt/scopesentry-prod
EOF

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" deploy reload >/dev/null

  assert_file "$state_dir/go.build.calls"
  assert_contains "./cmd/main" "$state_dir/go.build.calls"
  assert_not_contains "./cmd/main/main.go" "$state_dir/go.build.calls"
}

test_deploy_reload_retries_remote_http_smoke_until_ready() {
  local tmp_root stub_bin state_dir output deploy_conf
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  deploy_conf="$tmp_root/.local-dev/deploy.conf"
  mkdir -p "$(dirname "$deploy_conf")"
  cat >"$deploy_conf" <<'EOF'
DEPLOY_HOST=root@example.com
DEPLOY_PORT=22
DEPLOY_REMOTE_DIR=/opt/scopesentry-prod
EOF
  printf '2' >"$state_dir/deploy.remote.root.fail.count"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" deploy reload 2>&1)"

  [[ "$output" == *"远端 HTTP 自检未就绪（1/10）"* ]] || fail "expected first retry log"
  [[ "$output" == *"远端 HTTP 自检未就绪（2/10）"* ]] || fail "expected second retry log"
  [[ "$output" == *"[4/4] 阶段 verify: 就绪"* ]] || fail "expected verify stage to eventually succeed"
}

test_deploy_reload_outputs_remote_runtime_credentials() {
  local tmp_root stub_bin state_dir output deploy_conf
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  deploy_conf="$tmp_root/.local-dev/deploy.conf"
  mkdir -p "$(dirname "$deploy_conf")"
  cat >"$deploy_conf" <<'EOF'
DEPLOY_HOST=root@example.com
DEPLOY_PORT=22
DEPLOY_REMOTE_DIR=/opt/scopesentry-prod
EOF
  printf 'remote-web-password' >"$state_dir/deploy.container.password"
  printf 'remote-plugin-key' >"$state_dir/deploy.container.pluginkey"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" deploy reload 2>&1)"

  [[ "$output" == *"Web 用户: ScopeSentry"* ]] || fail "expected deploy reload to print web user"
  [[ "$output" == *"Web 密码: remote-web-password"* ]] || fail "expected deploy reload to print migrated web password"
  [[ "$output" == *"插件 Key: remote-plugin-key"* ]] || fail "expected deploy reload to print migrated plugin key"
  assert_file "$state_dir/deploy.remote.password"
  assert_file "$state_dir/deploy.remote.pluginkey"
  assert_contains "docker cp scope-sentry:/opt/ScopeSentry/PASSWORD" "$state_dir/ssh.calls"
  assert_contains "docker cp scope-sentry:/opt/ScopeSentry/PLUGINKEY" "$state_dir/ssh.calls"
}

test_deploy_show_creds_reads_remote_runtime_credentials() {
  local tmp_root stub_bin state_dir output deploy_conf
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  deploy_conf="$tmp_root/.local-dev/deploy.conf"
  mkdir -p "$(dirname "$deploy_conf")"
  cat >"$deploy_conf" <<'EOF'
DEPLOY_HOST=root@example.com
DEPLOY_PORT=22
DEPLOY_REMOTE_DIR=/opt/scopesentry-prod
EOF
  printf 'show-web-password' >"$state_dir/deploy.remote.password"
  printf 'show-plugin-key' >"$state_dir/deploy.remote.pluginkey"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" deploy show-creds 2>&1)"

  [[ "$output" == *"当前远端访问凭据："* ]] || fail "expected deploy show-creds to print header"
  [[ "$output" == *"Web 用户: ScopeSentry"* ]] || fail "expected deploy show-creds to print web user"
  [[ "$output" == *"Web 密码: show-web-password"* ]] || fail "expected deploy show-creds to print web password"
  [[ "$output" == *"插件 Key: show-plugin-key"* ]] || fail "expected deploy show-creds to print plugin key"
  assert_not_exists "$state_dir/go.build.calls"
  assert_not_exists "$state_dir/rsync.calls"
}

test_deploy_reset_password_updates_remote_password_and_prints_credentials() {
  local tmp_root stub_bin state_dir output deploy_conf expected_hash
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  deploy_conf="$tmp_root/.local-dev/deploy.conf"
  mkdir -p "$(dirname "$deploy_conf")"
  cat >"$deploy_conf" <<'EOF'
DEPLOY_HOST=root@example.com
DEPLOY_PORT=22
DEPLOY_REMOTE_DIR=/opt/scopesentry-prod
EOF
  printf 'existing-plugin-key' >"$state_dir/deploy.remote.pluginkey"
  expected_hash="$(python3 - <<'PY'
import hashlib
print(hashlib.sha256(b"NewPass_2026!").hexdigest(), end="")
PY
)"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" deploy reset-password 'NewPass_2026!' 2>&1)"

  assert_file "$state_dir/deploy.mongosh.last"
  assert_contains "username:\"ScopeSentry\"" "$state_dir/deploy.mongosh.last"
  assert_contains "password:\"$expected_hash\"" "$state_dir/deploy.mongosh.last"
  assert_file "$state_dir/deploy.remote.password"
  [[ "$(cat "$state_dir/deploy.remote.password")" == "NewPass_2026!" ]] || fail "expected remote password file to be updated"
  [[ "$output" == *"Web 用户: ScopeSentry"* ]] || fail "expected deploy reset-password to print web user"
  [[ "$output" == *"Web 密码: NewPass_2026!"* ]] || fail "expected deploy reset-password to print updated web password"
  [[ "$output" == *"插件 Key: existing-plugin-key"* ]] || fail "expected deploy reset-password to preserve plugin key output"
}

test_reset_password_updates_local_password_and_file() {
  local tmp_root stub_bin state_dir output expected_hash password_file
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  touch "$state_dir/scopesentry-mongodb.running"
  expected_hash="$(python3 - <<'PY'
import hashlib
print(hashlib.sha256(b"LocalDev123!").hexdigest(), end="")
PY
)"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" reset-password 'LocalDev123!' 2>&1)"
  password_file="$tmp_root/.local-dev/runtime/server/PASSWORD"

  assert_file "$state_dir/local.mongosh.last"
  assert_contains "username:\"ScopeSentry\"" "$state_dir/local.mongosh.last"
  assert_contains "password:\"$expected_hash\"" "$state_dir/local.mongosh.last"
  assert_file "$password_file"
  [[ "$(cat "$password_file")" == "LocalDev123!" ]] || fail "expected local password file to be updated"
  [[ "$output" == *"Web 用户: ScopeSentry"* ]] || fail "expected reset-password to print web user"
  [[ "$output" == *"Web 密码: LocalDev123!"* ]] || fail "expected reset-password to print updated web password"
}

test_deploy_push_uses_persistent_server_runtime_directory() {
  local tmp_root stub_bin state_dir output deploy_conf override_file
  tmp_root="$(mktemp -d)"
  stub_bin="$tmp_root/bin"
  state_dir="$tmp_root/test-state"
  mkdir -p "$state_dir"
  make_stub_bin "$stub_bin"
  make_fake_project "$tmp_root"

  run_devctl "$tmp_root" "$stub_bin" "$state_dir" install >/dev/null
  deploy_conf="$tmp_root/.local-dev/deploy.conf"
  mkdir -p "$(dirname "$deploy_conf")"
  cat >"$deploy_conf" <<'EOF'
DEPLOY_HOST=root@example.com
DEPLOY_PORT=22
DEPLOY_REMOTE_DIR=/opt/scopesentry-prod
EOF
  printf 'push-web-password' >"$state_dir/deploy.container.password"
  printf 'push-plugin-key' >"$state_dir/deploy.container.pluginkey"

  output="$(run_devctl "$tmp_root" "$stub_bin" "$state_dir" deploy push 2>&1)"
  override_file="$tmp_root/.local-dev/runtime/tmp/docker-compose.prod.override.yml"

  assert_file "$override_file"
  assert_contains "./dist/ScopeSentry_linux_amd64_v1:/opt/ScopeSentry" "$override_file"
  assert_not_contains "./dist/ScopeSentry_linux_amd64_v1/ScopeSentry:/opt/ScopeSentry/ScopeSentry:ro" "$override_file"
  assert_contains "dist/ScopeSentry_linux_amd64_v1/PASSWORD" "$state_dir/rsync.calls"
  assert_contains "dist/ScopeSentry_linux_amd64_v1/PLUGINKEY" "$state_dir/rsync.calls"
  [[ "$output" == *"Web 用户: ScopeSentry"* ]] || fail "expected deploy push to print web user"
  [[ "$output" == *"Web 密码: push-web-password"* ]] || fail "expected deploy push to print web password"
  [[ "$output" == *"插件 Key: push-plugin-key"* ]] || fail "expected deploy push to print plugin key"
}

test_install_generates_env_and_manifest
test_install_migrates_official_scan_default_to_local
test_doctor_reports_healthy_environment
test_doctor_warns_about_bridge_scan_network_for_masscan
test_doctor_reports_docker_daemon_failure_with_hint
test_up_waits_for_mongo_before_starting_server
test_up_keeps_server_running_after_parent_process_group_exits
test_up_builds_local_scan_image_when_missing
test_up_skips_scan_build_when_local_image_exists
test_up_prints_detailed_progress_messages
test_up_starts_ui_with_strict_configured_port
test_up_fails_fast_when_backend_process_exits_before_readiness
test_up_restarts_server_when_embedded_ui_changes
test_up_fails_when_embedded_ui_root_asset_mismatches_disk
test_status_ignores_stale_pid_files
test_down_force_removes_sticky_containers
test_clean_removes_transient_files_but_preserves_config
test_up_reports_db_stage_failure_with_logs_and_hint
test_up_reports_explicit_port_conflict_details
test_scan_rebuild_retries_transient_docker_build_timeout
test_scan_rebuild_base_passes_configured_build_mirrors
test_scan_rebuild_passes_oneforall_build_sources
test_scan_rebuild_reuses_existing_app_image_when_base_missing
test_deploy_reload_runs_remote_http_smoke_check
test_deploy_reload_builds_server_package_instead_of_single_file
test_deploy_reload_retries_remote_http_smoke_until_ready
test_deploy_reload_outputs_remote_runtime_credentials
test_deploy_show_creds_reads_remote_runtime_credentials
test_deploy_reset_password_updates_remote_password_and_prints_credentials
test_reset_password_updates_local_password_and_file
test_deploy_push_uses_persistent_server_runtime_directory

printf 'PASS: devctl tests\n'
