# devctl Up Progress Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `./devctl up` 在每个启动阶段和等待循环中持续输出详细状态，用户能知道当前卡在哪一步、已经等了多久、还在等什么。

**Architecture:** 在 `devctl` 中增加轻量级阶段日志和共享等待心跳辅助函数，复用到 Mongo、TCP、HTTP 和扫描容器等待逻辑里。现有失败路径保留不变，只增强成功前的可见状态输出。

**Tech Stack:** Bash, existing `devctl`, shell test harness in `scripts/tests/devctl_test.sh`

---

### Task 1: Record The Approved Design

**Files:**
- Create: `docs/superpowers/specs/2026-04-15-devctl-up-progress-design.md`
- Create: `docs/superpowers/plans/2026-04-15-devctl-up-progress.md`

- [ ] **Step 1: Freeze the chosen output model**

Document stage start lines, waiting heartbeats, and ready lines.

- [ ] **Step 2: Freeze the configuration surface**

Document `DEVCTL_PROGRESS_INTERVAL=5` as the only new knob.

- [ ] **Step 3: Keep scope bounded**

Confirm there is no spinner, no menu, and no change to existing failure semantics.

### Task 2: Add Failing Tests

**Files:**
- Modify: `scripts/tests/devctl_test.sh`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Write a failing progress output test**

Add a test that runs `./devctl up` with `DEVCTL_PROGRESS_INTERVAL=1` and expects stage start lines plus at least one `waiting db` heartbeat.

- [ ] **Step 2: Verify the new test fails**

Run: `bash scripts/tests/devctl_test.sh`
Expected: FAIL because `up` does not yet print detailed waiting status.

- [ ] **Step 3: Add assertions for stage completion lines**

Check that successful runs print `stage db: ready in` and similar ready messages for later stages.

- [ ] **Step 4: Re-run the full script suite**

Run: `bash scripts/tests/devctl_test.sh`
Expected: FAIL for missing progress behavior, not for harness errors.

### Task 3: Implement Progress Logging

**Files:**
- Modify: `devctl`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Add shared progress helpers**

Implement helpers for stage start, waiting heartbeat throttling, and stage completion timing.

- [ ] **Step 2: Instrument Mongo/TCP/HTTP/scan waits**

Update `wait_for_mongo_ready`, `wait_for_tcp_port`, `wait_for_http`, and `wait_for_scan_container` to emit detailed status while waiting.

- [ ] **Step 3: Instrument `run_up` stage transitions**

Print explicit stage start lines before each startup phase and stage ready lines after each wait succeeds.

- [ ] **Step 4: Keep existing failure handling intact**

Ensure detailed progress output complements, rather than replaces, the current stage failure reporter.

### Task 4: Update Docs And Verify

**Files:**
- Modify: `LOCAL_DEV_SETUP.md`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Document detailed `up` progress**

Explain that `./devctl up` now shows stage, elapsed time, and last known wait status.

- [ ] **Step 2: Mention the interval override**

Document `DEVCTL_PROGRESS_INTERVAL` as an optional tuning knob.

- [ ] **Step 3: Run script tests**

Run: `bash scripts/tests/devctl_test.sh`
Expected: PASS

- [ ] **Step 4: Run shell syntax checks**

Run: `bash -n devctl scripts/tests/devctl_test.sh`
Expected: PASS
