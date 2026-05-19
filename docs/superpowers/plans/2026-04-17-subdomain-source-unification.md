# Subdomain Source Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a unified numeric source tracking pipeline for subdomain discoveries across built-in plugins, hot plugins, and system emitters.

**Architecture:** The server owns the canonical source registry and summary schema. The scan side propagates `sourceRef` with each `SubdomainResult` and writes both task-level discovery events and asset-level source summaries. Task comparison reads events by `sourceRef` and resolves labels from `discovery_sources`.

**Tech Stack:** Go, MongoDB, Gin, existing ScopeSentry / ScopeSentry-Scan task and plugin pipelines

---

### Task 1: Define Server Models And Indexes

**Files:**
- Modify: `ScopeSentry/internal/models/plugin.go`
- Modify: `ScopeSentry/internal/models/task.go`
- Modify: `ScopeSentry/internal/database/mongodb/initdb.go`
- Modify: `ScopeSentry/internal/database/mongodb/initdb_test.go`

- [ ] Step 1: Write failing tests for the new index specs and model-dependent expectations.
- [ ] Step 2: Run `go test ./internal/database/mongodb ./internal/services/task/task` in `ScopeSentry` and verify the new assertions fail for missing `sourceRef` support.
- [ ] Step 3: Add `DiscoverySource` and `SubdomainSourceSummary` models plus `sourceRef` fields on plugin and event models.
- [ ] Step 4: Add indexes for `discovery_sources`, `subdomain_discovery_events`, and `subdomain_source_summary`.
- [ ] Step 5: Re-run the same tests until green.

### Task 2: Move Comparison Aggregation To sourceRef

**Files:**
- Modify: `ScopeSentry/internal/services/task/task/task.go`
- Modify: `ScopeSentry/internal/services/task/task/subdomain_comparison_test.go`
- Modify: `ScopeSentry/internal/api/handlers/task/task_test.go`

- [ ] Step 1: Write failing tests covering aggregation and detail reads by `sourceRef` with display names resolved from source metadata.
- [ ] Step 2: Run `go test ./internal/services/task/task ./internal/api/handlers/task` in `ScopeSentry` and verify failure.
- [ ] Step 3: Refactor comparison aggregation and detail response models to use source identity instead of legacy `pluginHash`.
- [ ] Step 4: Remove the temporary legacy fallback path from task comparison loading.
- [ ] Step 5: Re-run the targeted tests until green.

### Task 3: Assign Stable sourceRef To Discovery Sources

**Files:**
- Modify: `ScopeSentry/internal/repositories/plugin/plugin.go`
- Modify: `ScopeSentry/internal/services/plugin/plugin.go`
- Modify: `ScopeSentry/internal/models/plugin.go`

- [ ] Step 1: Write a failing test or focused helper test for plugin save/upsert assigning a `sourceRef` when absent.
- [ ] Step 2: Run the targeted plugin service test command and verify failure.
- [ ] Step 3: Implement source registry lookup/creation and ensure plugin rows persist `sourceRef`.
- [ ] Step 4: Keep existing plugin hash behavior intact for plugin installation and node sync.
- [ ] Step 5: Re-run targeted tests until green.

### Task 4: Propagate sourceRef On The Scan Side

**Files:**
- Modify: `ScopeSentry-Scan/internal/types/types.go`
- Modify: `ScopeSentry-Scan/internal/options/plugin.go`
- Modify: `ScopeSentry-Scan/modules/customplugin/customplugin.go`
- Modify: `ScopeSentry-Scan/modules/subdomainscan/module.go`
- Modify: `ScopeSentry-Scan/modules/subdomainscan/module_test.go`

- [ ] Step 1: Write failing tests for hot-plugin results inheriting `sourceRef` and direct/system discoveries getting the reserved system source.
- [ ] Step 2: Run `go test ./modules/subdomainscan` in `ScopeSentry-Scan` and verify failure.
- [ ] Step 3: Add `SourceRef` to result and plugin option types.
- [ ] Step 4: Inject `SourceRef` in the hot-plugin bridge and direct/system discovery path.
- [ ] Step 5: Re-run the module tests until green.

### Task 5: Write Events And Asset Summaries

**Files:**
- Modify: `ScopeSentry-Scan/internal/results/discovery.go`
- Add or Modify tests near that package

- [ ] Step 1: Write failing tests for `subdomain_discovery_events` and `subdomain_source_summary` writes keyed by `sourceRef`.
- [ ] Step 2: Run the targeted results package tests and verify failure.
- [ ] Step 3: Update scan-side discovery persistence to write both collections and use duplicate-safe upserts.
- [ ] Step 4: Re-run the targeted tests until green.

### Task 6: Runtime Verification

**Files:**
- No code changes required unless issues surface

- [ ] Step 1: Run `go test ./...` selectively in changed packages for both `ScopeSentry` and `ScopeSentry-Scan`.
- [ ] Step 2: Rebuild scan image with `./devctl scan rebuild`.
- [ ] Step 3: Restart local stack with `./devctl restart`.
- [ ] Step 4: Execute a subdomain task using built-in and hot plugins.
- [ ] Step 5: Verify MongoDB contains `discovery_sources`, `subdomain_discovery_events`, and `subdomain_source_summary` rows with numeric `sourceRef`.
