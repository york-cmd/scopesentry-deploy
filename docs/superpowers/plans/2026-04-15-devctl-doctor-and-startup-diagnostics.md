# devctl Doctor And Startup Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `devctl` 增加只读 `doctor` 诊断命令，并让 `up` 在失败时输出明确阶段、日志片段和修复建议。

**Architecture:** 在现有 Bash 入口脚本里补充一套共享诊断辅助函数，避免 `doctor` 和 `up` 各自复制判断逻辑。`doctor` 负责完整收集并汇总诊断结果，`up` 继续 fail-fast，但失败输出改为结构化、可行动的信息。

**Tech Stack:** Bash, existing `devctl` runtime helpers, stubbed shell tests in `scripts/tests/devctl_test.sh`, Python 3 for manifest emission

---

### Task 1: Record The Approved Design

**Files:**
- Create: `docs/superpowers/specs/2026-04-15-devctl-doctor-and-startup-diagnostics-design.md`
- Create: `docs/superpowers/plans/2026-04-15-devctl-doctor-and-startup-diagnostics.md`

- [ ] **Step 1: Write the approved scope**

Document that `doctor` is read-only and `up` prints inline diagnostics on failure.

- [ ] **Step 2: Freeze check list and output contract**

List required checks, `PASS/WARN/FAIL` format, and stage-specific `up` failure output.

- [ ] **Step 3: Keep the work bounded**

Confirm no auto-fix mode, no menu rewrite, and no deployment-mode changes are included.

### Task 2: Add Failing Script Tests

**Files:**
- Modify: `scripts/tests/devctl_test.sh`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Write the failing doctor test**

Add a test that expects `./devctl doctor` to print healthy `PASS` lines when the stubbed environment is available.

- [ ] **Step 2: Run the doctor test to verify it fails**

Run: `bash scripts/tests/devctl_test.sh`
Expected: FAIL because `doctor` does not exist yet.

- [ ] **Step 3: Write the failing Docker daemon diagnostic test**

Extend the stubbed `docker` command so a test can simulate daemon failure and assert that `doctor` prints `FAIL` plus a hint.

- [ ] **Step 4: Write the failing startup diagnostics test**

Add a test that forces `db` startup failure and expects `./devctl up` to print the failed stage, a log excerpt marker, and a remediation hint.

- [ ] **Step 5: Re-run the full script test suite**

Run: `bash scripts/tests/devctl_test.sh`
Expected: FAIL for missing behavior, not harness errors.

### Task 3: Implement Shared Diagnostic Helpers

**Files:**
- Modify: `devctl`

- [ ] **Step 1: Add output helper primitives**

Implement small helpers for standardized `PASS/WARN/FAIL` lines and `hint:` lines.

- [ ] **Step 2: Add Docker and toolchain checks**

Implement shared helpers for command presence, Docker daemon reachability, and Compose availability.

- [ ] **Step 3: Add runtime and port checks**

Implement helpers for stale pid detection, expected process ownership, and port occupancy summaries.

### Task 4: Implement doctor Command

**Files:**
- Modify: `devctl`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Add `doctor` to usage and command dispatch**

Wire `./devctl doctor` into the existing subcommand table without changing existing commands.

- [ ] **Step 2: Implement read-only diagnostic flow**

Collect all checks, print all results, and return non-zero only when at least one `FAIL` occurred.

- [ ] **Step 3: Keep output actionable**

Ensure failed checks include concise remediation steps relevant to local development.

- [ ] **Step 4: Run tests and verify green**

Run: `bash scripts/tests/devctl_test.sh`
Expected: new doctor tests pass, existing tests remain green.

### Task 5: Improve up Failure Diagnostics

**Files:**
- Modify: `devctl`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Add a shared startup failure reporter**

Implement one helper that prints stage name, reason, log excerpt, and `./devctl doctor` suggestion.

- [ ] **Step 2: Replace current inline failure blocks**

Use the helper for `db/server/ui/scan` startup failures while keeping existing wait logic.

- [ ] **Step 3: Preserve non-zero exits**

Ensure `up` still exits with failure status after printing diagnostics.

- [ ] **Step 4: Run tests and verify green**

Run: `bash scripts/tests/devctl_test.sh`
Expected: startup diagnostic tests pass and previous behavior stays intact.

### Task 6: Update Docs And Verify

**Files:**
- Modify: `LOCAL_DEV_SETUP.md`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Document the new doctor command**

Add `doctor` to the primary command list and describe when to use it before or after `up`.

- [ ] **Step 2: Document improved failure behavior**

Explain that `up` now prints the failed stage and the relevant log excerpt automatically.

- [ ] **Step 3: Run script tests**

Run: `bash scripts/tests/devctl_test.sh`
Expected: PASS

- [ ] **Step 4: Run shell syntax verification**

Run: `bash -n devctl scripts/tests/devctl_test.sh`
Expected: PASS
