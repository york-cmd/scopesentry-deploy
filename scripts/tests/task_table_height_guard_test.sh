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

TASK_FILE="$REPO_ROOT/ScopeSentry-UI/src/views/Task/Task.vue"
SCAN_TEMPLATE_FILE="$REPO_ROOT/ScopeSentry-UI/src/views/Task/ScanTemplate.vue"
SCHEDULED_TASK_FILE="$REPO_ROOT/ScopeSentry-UI/src/views/Task/ScheduledTask.vue"
PAGE_MONIT_FILE="$REPO_ROOT/ScopeSentry-UI/src/views/Task/components/PageMonit.vue"

assert_contains "const DEFAULT_TABLE_MAX_HEIGHT = 480" "$TASK_FILE"
assert_contains "onActivated(() => {" "$TASK_FILE"

for file in "$SCAN_TEMPLATE_FILE" "$SCHEDULED_TASK_FILE" "$PAGE_MONIT_FILE"; do
  assert_contains "const DEFAULT_TABLE_MAX_HEIGHT = 480" "$file"
  assert_contains "const maxHeight = ref(DEFAULT_TABLE_MAX_HEIGHT)" "$file"
  assert_contains "onActivated(() => {" "$file"
  assert_contains "Math.max(DEFAULT_TABLE_MAX_HEIGHT" "$file"
done

printf 'PASS: task table height guard\n'
