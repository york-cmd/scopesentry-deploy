#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="/usr/local/opt/python@3.11/bin/python3.11"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

output="$("$PYTHON_BIN" - <<'PY'
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 1365, 'height': 768})
    page.goto('http://127.0.0.1:4000', wait_until='networkidle')
    page.locator('input[type="text"]').fill('ScopeSentry')
    page.locator('input[type="password"]').fill('LocalDev123!')
    page.get_by_role('button', name='登录').nth(0).click()
    page.wait_for_load_state('networkidle')
    page.goto('http://127.0.0.1:4000/#/task-management/ScanTask', wait_until='networkidle')
    page.wait_for_selector('.el-table', state='attached', timeout=10000)
    page.wait_for_timeout(1500)
    payload = page.evaluate("""() => ({
      tableHeight: getComputedStyle(document.querySelector('.el-table')).height,
      rowCount: document.querySelectorAll('.el-table__body-wrapper tbody tr').length,
      totalText: document.body.innerText.includes('共 4 条')
    })""")
    print(payload)
    browser.close()
PY
)"

[[ "$output" == *"'rowCount': 4"* ]] || fail "expected 4 task rows, got: $output"
[[ "$output" != *"'tableHeight': '0px'"* ]] || fail "expected table height to be non-zero, got: $output"
[[ "$output" == *"'totalText': True"* ]] || fail "expected task total text, got: $output"

printf 'PASS: task page visibility\n'
