#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "expected $file to contain: $needle"
}

assert_contains 'STREAM_SUBDOMAIN_ENABLED' "$REPO_ROOT/scripts/dev-scan.sh"
assert_contains 'STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS' "$REPO_ROOT/scripts/dev-scan.sh"
assert_contains 'STREAM_SUBDOMAIN_ENABLED_VALUE="${STREAM_SUBDOMAIN_ENABLED:-false}"' "$REPO_ROOT/scripts/dev-scan-docker.sh"
assert_contains 'STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS_VALUE="${STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS:-7200}"' "$REPO_ROOT/scripts/dev-scan-docker.sh"
assert_contains 'STREAM_SUBDOMAIN_ENABLED=$STREAM_SUBDOMAIN_ENABLED_VALUE' "$REPO_ROOT/scripts/dev-scan-docker.sh"
assert_contains 'STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS=$STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS_VALUE' "$REPO_ROOT/scripts/dev-scan-docker.sh"
assert_contains 'STREAM_SUBDOMAIN_ENABLED: ${STREAM_SUBDOMAIN_ENABLED}' "$REPO_ROOT/scripts/dev-scan-docker-compose.yml"
assert_contains 'STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS: ${STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS}' "$REPO_ROOT/scripts/dev-scan-docker-compose.yml"
assert_contains '--stream-subdomain' "$REPO_ROOT/scripts/dev-smoke.sh"

printf 'stream subdomain env test passed\n'
