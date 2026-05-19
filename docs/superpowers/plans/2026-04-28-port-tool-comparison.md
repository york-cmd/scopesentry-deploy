# Port Tool Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sequential multi-plugin port comparison mode that records plugin-level discovery/runtime events, exposes comparison APIs, and renders a port comparison view in the task UI.

**Architecture:** Keep the existing single-plugin port scan flow intact. When more than one port-scan plugin is selected, switch `PortScan` into comparison mode: collect prepared targets, run each plugin over the same target set sequentially, record per-plugin discovery/runtime events, deduplicate the union for downstream fingerprinting, and aggregate comparison results in the API layer for the UI.

**Tech Stack:** Go, Gin, MongoDB, Vue 3, Element Plus, existing ScopeSentry plugin/runtime event patterns.

---

### Task 1: Add failing backend aggregation tests

**Files:**
- Modify: `ScopeSentry/internal/services/task/task/subdomain_comparison_test.go`
- Create: `ScopeSentry/internal/services/task/task/port_comparison_test.go`

- [ ] Add tests for port comparison aggregation counts, runtime totals, and detail views.
- [ ] Run targeted Go tests and confirm the new tests fail for missing port comparison implementation.

### Task 2: Add port discovery/runtime event persistence

**Files:**
- Modify: `ScopeSentry-Scan/internal/types/types.go`
- Modify: `ScopeSentry-Scan/internal/results/discovery.go`
- Modify: `ScopeSentry-Scan/internal/results/discovery_test.go`

- [ ] Extend `types.PortAlive` with source metadata fields needed for comparison.
- [ ] Add record helpers for `port_discovery_events` and `port_plugin_runtime_events`.
- [ ] Add tests covering runtime duration and discovery event writes.

### Task 3: Implement sequential comparison mode in PortScan

**Files:**
- Modify: `ScopeSentry-Scan/modules/portscan/module.go`
- Modify: `ScopeSentry-Scan/modules/portscan/rustscan/rustscan.go`
- Modify: `ScopeSentry-Scan/modules/portscan/module_test.go`

- [ ] Add tests for multi-plugin sequential execution and union deduplication.
- [ ] Preserve current flow for single-plugin tasks.
- [ ] For comparison mode, buffer prepared targets, run plugins one-by-one across the full target set, record runtime events, record discovery events, and emit only the deduplicated union to downstream modules.

### Task 4: Add Naabu builtin plugin

**Files:**
- Create: `ScopeSentry-Scan/modules/portscan/naabu/plugin.go`
- Modify: `ScopeSentry-Scan/internal/plugins/plugins.go`
- Modify: `ScopeSentry/internal/constants/defaults.go`
- Create: `ScopeSentry-Scan/modules/portscan/naabu/plugin_test.go`

- [ ] Add the Naabu plugin implementation with current project parameter conventions.
- [ ] Register Naabu as a builtin `PortScan` plugin.
- [ ] Add default plugin metadata and help text.
- [ ] Verify plugin parsing and emitted `PortAlive` metadata in tests.

### Task 5: Expose port comparison API

**Files:**
- Modify: `ScopeSentry/internal/models/task.go`
- Modify: `ScopeSentry/internal/services/task/task/task.go`
- Modify: `ScopeSentry/internal/api/handlers/task/task.go`
- Modify: `ScopeSentry/internal/api/routes/task/task.go`
- Modify: `ScopeSentry/internal/api/handlers/task/task_test.go`

- [ ] Add request/response models for port comparison summary and details.
- [ ] Add aggregation and detail loaders mirroring subdomain comparison patterns.
- [ ] Add API handlers and routes for summary/detail endpoints.
- [ ] Add handler and service tests.

### Task 6: Add task UI for port comparison

**Files:**
- Modify: `ScopeSentry-UI/src/api/task/types.ts`
- Modify: `ScopeSentry-UI/src/api/task/index.ts`
- Create: `ScopeSentry-UI/src/views/Task/components/PortToolComparison.vue`
- Modify: `ScopeSentry-UI/src/views/Task/components/ProgressInfo.vue`
- Modify: `ScopeSentry-UI/src/locales/zh-CN.ts`
- Modify: `ScopeSentry-UI/src/locales/en.ts`

- [ ] Add task API typings and requests.
- [ ] Build a port comparison component based on the existing subdomain comparison UX.
- [ ] Add the port comparison tab to task progress details.
- [ ] Add i18n labels for summary, plugin metrics, timing, and detail views.

### Task 7: Verify end-to-end behavior

**Files:**
- Modify: `docs/superpowers/plans/2026-04-28-port-tool-comparison.md`

- [ ] Run targeted Go tests for scan-side and API-side changes.
- [ ] Run targeted UI type/build validation if available.
- [ ] Update this plan with completed boxes only after fresh verification succeeds.
