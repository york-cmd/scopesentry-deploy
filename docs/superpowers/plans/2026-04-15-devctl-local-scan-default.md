# devctl Local Scan Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `devctl` 默认启动本地二开扫描镜像，并在该镜像不存在时自动先构建一次。

**Architecture:** 通过修改 `devctl` 的默认 `SCAN_IMAGE` 和新增“本地扫描镜像存在性检查”来实现惰性构建。保留现有显式 `scan rebuild` 工作流，不做源码变更自动检测。

**Tech Stack:** Bash, existing `devctl`, existing `scripts/dev-scan-docker-build.sh`, shell test harness in `scripts/tests/devctl_test.sh`

---

### Task 1: Record The Approved Design

**Files:**
- Create: `docs/superpowers/specs/2026-04-15-devctl-local-scan-default-design.md`
- Create: `docs/superpowers/plans/2026-04-15-devctl-local-scan-default.md`

- [ ] **Step 1: Freeze the default scan image**

Document that the default scan image becomes `scopesentry-scan-dev:local`.

- [ ] **Step 2: Freeze the lazy-build rule**

Document that `up` auto-builds only when the local scan image is missing.

- [ ] **Step 3: Keep scope bounded**

Document that source freshness detection remains manual via `./devctl scan rebuild`.

### Task 2: Add Failing Tests

**Files:**
- Modify: `scripts/tests/devctl_test.sh`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Write a failing default-image test**

Assert that `install` and `status` default to `scopesentry-scan-dev:local`.

- [ ] **Step 2: Write a failing lazy-build test**

Simulate a missing local scan image and assert that `up` triggers a local image build before scan container startup.

- [ ] **Step 3: Verify the new tests fail**

Run: `bash scripts/tests/devctl_test.sh`
Expected: FAIL because the current default still points to the official image and no missing-image build hook exists.

### Task 3: Implement Local Scan Default

**Files:**
- Modify: `devctl`
- Modify: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Change the default scan image**

Set the default runtime scan image to the local image while preserving explicit overrides from env or persisted config.

- [ ] **Step 2: Add a local-image existence check**

Implement a helper that detects whether the target local scan image is already present in Docker.

- [ ] **Step 3: Add lazy build on missing image**

Before `start_scan`, trigger the local scan build path only when the local image is selected and missing.

- [ ] **Step 4: Re-run tests**

Run: `bash scripts/tests/devctl_test.sh`
Expected: PASS

### Task 4: Update Docs And Verify

**Files:**
- Modify: `LOCAL_DEV_SETUP.md`
- Test: `scripts/tests/devctl_test.sh`
- Test: `bash -n devctl scripts/tests/devctl_test.sh`

- [ ] **Step 1: Document the new default**

Explain that `./devctl up` now prefers the local scan image.

- [ ] **Step 2: Document when builds happen automatically**

Explain that auto-build only happens when the local image is absent, while source refresh still uses `./devctl scan rebuild`.

- [ ] **Step 3: Run verification commands**

Run: `bash scripts/tests/devctl_test.sh`
Expected: PASS

- [ ] **Step 4: Run shell syntax checks**

Run: `bash -n devctl scripts/tests/devctl_test.sh`
Expected: PASS
