#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "expected $file to contain: $needle"
}

SERVER_DIR="$TMP_DIR/server"
NODE_ETC_DIR="$TMP_DIR/node-etc"
NODE_DATA_DIR="$TMP_DIR/node-data"
BIN_DIR="$TMP_DIR/bin"
CALLS_FILE="$TMP_DIR/docker.calls"

mkdir -p "$SERVER_DIR" "$NODE_ETC_DIR" "$NODE_DATA_DIR/config" "$BIN_DIR"
touch "$SERVER_DIR/.env"

cat >"$SERVER_DIR/docker-compose.yml" <<'YML'
services:
  scope-sentry:
    image: ${SERVER_IMAGE}
    container_name: scope-sentry
    environment:
      TIMEZONE: ${TIMEZONE}
      REDIS_PASSWORD: ${REDIS_PASSWORD}
YML

cat >"$NODE_ETC_DIR/node.env" <<'ENV'
NodeName=test-node
SCAN_IMAGE=ghcr.io/example/scopesentry-scan:latest
ENV

cat >"$NODE_ETC_DIR/docker-compose.yml" <<'YML'
services:
  scopesentry-scan:
    image: ${SCAN_IMAGE}
    container_name: scopesentry-scan
YML

cat >"$BIN_DIR/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CALLS_FILE:?}"
if [[ "${1:-}" == "inspect" ]]; then
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then
  printf 'taskMode: stream\n'
  printf '  streamPortScanEnabled: true\n'
  printf '  streamSubdomainScanEnabled: true\n'
  exit 0
fi
if [[ "${1:-}" == "compose" ]]; then
  exit 0
fi
SH
chmod +x "$BIN_DIR/docker"

CALLS_FILE="$CALLS_FILE" \
PATH="$BIN_DIR:$PATH" \
SCOPESENTRY_INSTALL_DIR="$SERVER_DIR" \
SCOPESENTRY_NODE_ETC_DIR="$NODE_ETC_DIR" \
SCOPESENTRY_NODE_DATA_DIR="$NODE_DATA_DIR" \
  "$REPO_ROOT/scripts/enable-stream-task.sh" enable

assert_contains 'STREAM_PORTSCAN_ENABLED: "true"' "$SERVER_DIR/docker-compose.yml"
assert_contains 'STREAM_SUBDOMAIN_ENABLED: "true"' "$SERVER_DIR/docker-compose.yml"
assert_contains 'TASK_MODE=stream' "$NODE_ETC_DIR/node.env"
assert_contains 'STREAM_PORTSCAN_ENABLED=true' "$NODE_ETC_DIR/node.env"
assert_contains 'STREAM_SUBDOMAIN_ENABLED=true' "$NODE_ETC_DIR/node.env"
assert_contains 'STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS=7200' "$NODE_ETC_DIR/node.env"
assert_contains 'ADAPTIVE_PULL_ENABLED=false' "$NODE_ETC_DIR/node.env"
assert_contains 'compose --env-file .env up -d --force-recreate scope-sentry' "$CALLS_FILE"
assert_contains 'compose --env-file node.env up -d --force-recreate' "$CALLS_FILE"

CALLS_FILE="$CALLS_FILE" \
PATH="$BIN_DIR:$PATH" \
SCOPESENTRY_INSTALL_DIR="$SERVER_DIR" \
SCOPESENTRY_NODE_ETC_DIR="$NODE_ETC_DIR" \
SCOPESENTRY_NODE_DATA_DIR="$NODE_DATA_DIR" \
  "$REPO_ROOT/scripts/enable-stream-task.sh" enable --portscan-only --adaptive --timeout 99 --no-restart

assert_contains 'STREAM_PORTSCAN_ENABLED: "true"' "$SERVER_DIR/docker-compose.yml"
assert_contains 'STREAM_SUBDOMAIN_ENABLED: "false"' "$SERVER_DIR/docker-compose.yml"
assert_contains 'STREAM_SUBDOMAIN_ENABLED=false' "$NODE_ETC_DIR/node.env"
assert_contains 'STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS=99' "$NODE_ETC_DIR/node.env"
assert_contains 'ADAPTIVE_PULL_ENABLED=true' "$NODE_ETC_DIR/node.env"

status_output="$(
  CALLS_FILE="$CALLS_FILE" \
  PATH="$BIN_DIR:$PATH" \
  SCOPESENTRY_INSTALL_DIR="$SERVER_DIR" \
  SCOPESENTRY_NODE_ETC_DIR="$NODE_ETC_DIR" \
  SCOPESENTRY_NODE_DATA_DIR="$NODE_DATA_DIR" \
    "$REPO_ROOT/scripts/enable-stream-task.sh" status
)"

grep -Fq 'Server' <<<"$status_output" || fail "expected status to include Server section"
grep -Fq 'Scan Node' <<<"$status_output" || fail "expected status to include Scan Node section"

printf 'enable stream task script test passed\n'
