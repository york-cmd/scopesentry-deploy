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
  grep -Fq "$needle" "$file" || fail "expected '$needle' in $file"
}

API_FILE="$REPO_ROOT/ScopeSentry-UI/src/api/task/index.ts"
TYPE_FILE="$REPO_ROOT/ScopeSentry-UI/src/api/task/types.ts"
PROGRESS_FILE="$REPO_ROOT/ScopeSentry-UI/src/views/Task/components/ProgressInfo.vue"
COMPONENT_FILE="$REPO_ROOT/ScopeSentry-UI/src/views/Task/components/SubdomainToolComparison.vue"

assert_contains "getSubdomainToolComparisonApi" "$API_FILE"
assert_contains "getSubdomainToolComparisonDetailApi" "$API_FILE"
assert_contains "SubdomainToolComparisonResponse" "$TYPE_FILE"
assert_contains "SubdomainToolComparisonDetailResponse" "$TYPE_FILE"
assert_contains "SubdomainToolComparison" "$PROGRESS_FILE"
assert_contains "subdomainToolComparison" "$PROGRESS_FILE"
assert_contains ":active=\"activeTab === 'subdomainToolComparison'\"" "$PROGRESS_FILE"
assert_contains "setInterval" "$COMPONENT_FILE"
assert_contains "clearInterval" "$COMPONENT_FILE"
assert_contains "active: boolean" "$COMPONENT_FILE"
assert_contains "taskStatus" "$COMPONENT_FILE"
assert_contains "detailDialogVisible" "$COMPONENT_FILE"
assert_contains "openDetail" "$COMPONENT_FILE"
assert_contains "detailSearch" "$COMPONENT_FILE"
assert_contains "copyDetailHosts" "$COMPONENT_FILE"
assert_contains "exportDetailHosts" "$COMPONENT_FILE"
assert_contains "detailPageSize.value = 10" "$COMPONENT_FILE"
assert_contains "DETAIL_TABLE_MAX_HEIGHT" "$COMPONENT_FILE"
assert_contains "detail-dialog-body" "$COMPONENT_FILE"
assert_contains "detail-table-scroll" "$COMPONENT_FILE"
assert_contains "detail-pagination" "$COMPONENT_FILE"
test -f "$COMPONENT_FILE" || fail "expected component file: $COMPONENT_FILE"

printf 'PASS: subdomain tool comparison frontend wiring\n'
