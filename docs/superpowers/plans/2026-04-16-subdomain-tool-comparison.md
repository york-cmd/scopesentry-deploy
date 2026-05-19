# Subdomain Tool Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 支持按任务比较不同子域名插件的发现效果，并提供后端统计接口返回数量、并集、独有和两两交集。

**Architecture:** 新增 `subdomain_discovery_events` 事件表记录“任务 + 插件 + 子域名”的发现事实；现有主 `subdomain` 表继续维持去重后的最终资产结果。统计接口完全基于事件表聚合，不依赖主表回推来源。

**Tech Stack:** Go, MongoDB, existing task API/service layers, existing scan result flow

---

### Task 1: Lock Data Model And API Contract

**Files:**
- Create: `docs/superpowers/specs/2026-04-16-subdomain-tool-comparison-design.md`
- Create: `docs/superpowers/plans/2026-04-16-subdomain-tool-comparison.md`

- [ ] **Step 1: Freeze event collection schema**

Document required fields for `subdomain_discovery_events` and define the uniqueness rule as `taskId + pluginHash + host`.

- [ ] **Step 2: Freeze API response shape**

Document the first-version response fields: plugin counts, union count, exclusive counts, and pairwise intersections.

- [ ] **Step 3: Keep scope bounded**

Document that first version is task-scoped, backend-only, and summary-only.

### Task 2: Add Failing Tests For Scan-Side Event Recording

**Files:**
- Modify: `ScopeSentry-Scan/internal/types/types.go`
- Create: `ScopeSentry-Scan/modules/subdomainscan/module_test.go`

- [ ] **Step 1: Write a failing test for source metadata**

Assert that plugin-produced subdomain results can carry `SourcePlugin` and `SourcePluginHash`.

- [ ] **Step 2: Write a failing test for discovery event recording**

Assert that when two plugins emit the same `host`, two discovery events are recorded before main-result deduplication collapses the asset path.

- [ ] **Step 3: Run scan-side tests to verify RED**

Run: `go test ./ScopeSentry-Scan/modules/subdomainscan`
Expected: FAIL because event recording does not exist yet.

### Task 3: Implement Scan-Side Event Recording

**Files:**
- Modify: `ScopeSentry-Scan/internal/types/types.go`
- Modify: `ScopeSentry-Scan/modules/subdomainscan/module.go`
- Add any minimal helper file under `ScopeSentry-Scan/internal/results/` if needed

- [ ] **Step 1: Add source fields to subdomain result**

Introduce `SourcePlugin` and `SourcePluginHash` for in-flight result propagation.

- [ ] **Step 2: Tag plugin outputs with source metadata**

Ensure each subdomain plugin sets its plugin name/hash on emitted `SubdomainResult`.

- [ ] **Step 3: Record discovery events before deduplication**

Persist one event per `(taskId, pluginHash, host)` before the existing task-level dedup decides whether the main result continues.

- [ ] **Step 4: Keep existing asset flow intact**

Do not change current `subdomain` main-table dedup or downstream module behavior.

### Task 4: Add Failing Tests For Backend Aggregation

**Files:**
- Create or modify tests under `ScopeSentry/internal/services/task/task/`
- Create or modify tests under `ScopeSentry/internal/api/handlers/task/`

- [ ] **Step 1: Write failing aggregation test**

Seed discovery events for a task and assert per-plugin counts, union count, exclusive counts, and pairwise intersections.

- [ ] **Step 2: Write failing handler test**

Assert that the new task comparison endpoint accepts `taskId` and returns the aggregation payload.

- [ ] **Step 3: Run backend tests to verify RED**

Run the targeted `go test` commands for the task service and handler packages.
Expected: FAIL because the aggregation endpoint does not exist yet.

### Task 5: Implement Backend Comparison API

**Files:**
- Modify: `ScopeSentry/internal/models/task.go`
- Modify: `ScopeSentry/internal/services/task/task/task.go`
- Modify: `ScopeSentry/internal/api/handlers/task/task.go`
- Modify: `ScopeSentry/internal/api/routes/task/task.go`

- [ ] **Step 1: Add request/response models**

Add typed request/response structs for task-scoped subdomain tool comparison.

- [ ] **Step 2: Implement aggregation service**

Query `subdomain_discovery_events` by task, compute per-plugin counts, union, exclusives, and pairwise intersections.

- [ ] **Step 3: Add authenticated API route and handler**

Expose the comparison data under the task API.

- [ ] **Step 4: Run targeted tests**

Run the specific `go test` commands for modified backend packages.
Expected: PASS

### Task 6: Indexes And Final Verification

**Files:**
- Modify index/bootstrap path in scan-side or server-side code as needed
- Test: all targeted `go test` commands

- [ ] **Step 1: Add or ensure indexes**

Create the unique index for `taskId + pluginHash + host` and any supporting query index for `taskId`.

- [ ] **Step 2: Re-run scan-side tests**

Run: `go test ./ScopeSentry-Scan/modules/subdomainscan`
Expected: PASS

- [ ] **Step 3: Re-run backend tests**

Run the task service and handler test commands again.
Expected: PASS

- [ ] **Step 4: Summarize follow-up**

Document that the next stage would be adding a UI panel or export endpoint for comparison results.
