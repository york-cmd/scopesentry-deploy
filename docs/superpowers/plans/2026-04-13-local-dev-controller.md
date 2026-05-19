# Local Dev Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为本项目增加统一的 `./devctl` 本地开发控制器，收口安装、启动、状态、日志、扫描镜像重建、清理和卸载流程。

**Architecture:** 使用一个仓库根目录 Bash 入口脚本做命令分发和运行态管理，底层复用现有 `scripts/dev-*.sh`。所有本地运行态统一写入 `.local-dev`，并通过 `manifest.json` 暴露关键状态，减少脚本间隐式耦合。

**Tech Stack:** Bash, existing `scripts/*.sh`, Python 3 for JSON emission if needed, Docker Compose, Go build, pnpm

---

### Task 1: Define Runtime Contract

**Files:**
- Create: `docs/superpowers/specs/2026-04-13-local-dev-controller-design.md`
- Create: `docs/superpowers/plans/2026-04-13-local-dev-controller.md`

- [ ] **Step 1: Freeze command semantics**

Document exact meanings for `install/up/down/restart/status/logs/update/scan rebuild/clean/uninstall`.

- [ ] **Step 2: Freeze runtime layout**

Document `.local-dev` layout, password file location, and manifest structure.

- [ ] **Step 3: Verify scope is single-subsystem**

Confirm this work stays within local development orchestration and does not expand into unrelated product features.

### Task 2: Add Failing Script Tests

**Files:**
- Create: `scripts/tests/devctl_test.sh`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Write failing test for install**

Cover: runtime directories created, `.env` generated, manifest written.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/devctl_test.sh`
Expected: FAIL because `devctl` and its helpers do not exist yet.

- [ ] **Step 3: Extend tests for up/status and clean**

Cover: `up` creates the server password file through the server bootstrap path, `status` reads manifest, `clean` removes transient files but preserves password/env.

- [ ] **Step 4: Re-run test suite**

Run: `bash scripts/tests/devctl_test.sh`
Expected: FAIL for missing behavior, not for harness errors.

### Task 3: Implement devctl Core

**Files:**
- Create: `devctl`
- Modify: `scripts/dev-server.sh`
- Modify: `scripts/dev-ui.sh`
- Modify: `scripts/dev-scan-docker.sh`
- Modify: `scripts/dev-scan-docker-build.sh`
- Modify: `scripts/dev-db-up.sh`

- [ ] **Step 1: Add command dispatcher**

Implement subcommand parsing and shared path/default resolution.

- [ ] **Step 2: Add runtime helpers**

Implement helpers for directory creation, pid management, server env generation, manifest writes, and dependency checks.

- [ ] **Step 3: Implement install/up/down/restart/status/logs/update**

Reuse existing scripts where practical and normalize output for users.

- [ ] **Step 4: Implement scan rebuild/clean/uninstall**

Ensure `clean` is non-destructive and `uninstall --purge` is explicit.

### Task 4: Adapt Existing Scripts for Unified Runtime

**Files:**
- Modify: `scripts/dev-server.sh`
- Modify: `scripts/dev-ui.sh`
- Modify: `scripts/dev-scan-docker.sh`
- Modify: `scripts/dev-db-up.sh`

- [ ] **Step 1: Align runtime directories**

Make scripts compatible with the new `.local-dev` layout and shared defaults.

- [ ] **Step 2: Align generated file locations**

Ensure password and state files land in predictable paths used by `devctl`.

- [ ] **Step 3: Keep backward compatibility**

Preserve current direct-script usage where possible.

### Task 5: Verify and Document Usage

**Files:**
- Modify: `LOCAL_DEV_SETUP.md`
- Test: `scripts/tests/devctl_test.sh`

- [ ] **Step 1: Run script tests**

Run: `bash scripts/tests/devctl_test.sh`
Expected: PASS

- [ ] **Step 2: Run shell syntax checks**

Run: `bash -n devctl scripts/dev-server.sh scripts/dev-ui.sh scripts/dev-scan-docker.sh scripts/dev-scan-docker-build.sh scripts/dev-db-up.sh`
Expected: PASS

- [ ] **Step 3: Update local setup docs**

Document the new primary workflow around `./devctl`.

- [ ] **Step 4: Summarize manual follow-up**

List any commands that still require a real Docker/networked environment to validate fully.
