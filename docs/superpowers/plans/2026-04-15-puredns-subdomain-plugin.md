# puredns Subdomain Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `ScopeSentry-Scan` 增加一个内置 `SubdomainScan` 插件 `puredns`，复用现有 `subfile` 字典并通过容器内置 `puredns + massdns` 完成子域名字典爆破。

**Architecture:** 采用现有外部工具型插件模式：Go 插件壳负责任务参数、临时文件、命令执行和结果转换，实际爆破交给容器内置的 `puredns`。镜像层同时内置 `massdns` 和默认 resolvers 文件，避免运行时下载依赖。

**Tech Stack:** Go, Bash-compatible Dockerfile changes, existing `SubdomainScan` plugin interface, external binaries `puredns` and `massdns`

---

### Task 1: Lock Plugin Contract

**Files:**
- Create: `docs/superpowers/specs/2026-04-15-puredns-subdomain-plugin-design.md`
- Create: `docs/superpowers/plans/2026-04-15-puredns-subdomain-plugin.md`

- [ ] **Step 1: Freeze first-version scope**

Document that the plugin only supports dictionary bruteforce against a root domain and reuses the existing `subfile` task parameter.

- [ ] **Step 2: Freeze packaging model**

Document that `puredns`, `massdns`, and resolvers are bundled into the scan image rather than downloaded at runtime.

- [ ] **Step 3: Freeze test boundary**

Document that first-version tests focus on registration, command construction, and result parsing rather than full integration against public DNS.

### Task 2: Add Failing Tests

**Files:**
- Create: `ScopeSentry-Scan/modules/subdomainscan/puredns/puredns_test.go`
- Modify: `ScopeSentry-Scan/internal/plugins/plugins_test.go`

- [ ] **Step 1: Write failing registration test**

Assert that `InitializePlugins` registers a `SubdomainScan` plugin named `puredns`.

- [ ] **Step 2: Write failing parameter test**

Assert that `Execute` returns an error or logs a clear failure when `subfile` is missing.

- [ ] **Step 3: Write failing command construction test**

Assert that the plugin constructs a `puredns bruteforce` command containing the domain, dictionary path, `massdns` path, resolvers path, and timeout.

- [ ] **Step 4: Write failing parse test**

Assert that a simulated `puredns` output file is converted into `SubdomainResult` values.

- [ ] **Step 5: Run tests to verify RED**

Run: `go test ./ScopeSentry-Scan/internal/plugins ./ScopeSentry-Scan/modules/subdomainscan/puredns`
Expected: FAIL because the plugin does not exist yet.

### Task 3: Implement the Plugin

**Files:**
- Create: `ScopeSentry-Scan/modules/subdomainscan/puredns/puredns.go`
- Modify: `ScopeSentry-Scan/internal/plugins/plugins.go`

- [ ] **Step 1: Create plugin skeleton**

Mirror the structure used by `ksubdomain` and `subfinder` for `Name`, `Module`, `PluginId`, `Install`, `Check`, `Execute`, `Clone`, and logging.

- [ ] **Step 2: Implement dependency checks**

Ensure the plugin verifies the presence of `puredns`, `massdns`, and the default resolvers file in the expected runtime paths.

- [ ] **Step 3: Implement parameter parsing**

Read `subfile` and optional `et` from existing task parameters and resolve the dictionary path under the current dictionary directory.

- [ ] **Step 4: Implement command execution**

Construct and run `puredns bruteforce` with the expected paths and timeout under the task-scoped context.

- [ ] **Step 5: Implement result parsing**

Read the output file, resolve each subdomain through the existing DNS helpers, and emit `SubdomainResult` records to the plugin result channel.

- [ ] **Step 6: Register the plugin**

Add `puredns` registration to `InitializePlugins()` under `SubdomainScan`.

- [ ] **Step 7: Run targeted tests**

Run: `go test ./ScopeSentry-Scan/internal/plugins ./ScopeSentry-Scan/modules/subdomainscan/puredns`
Expected: PASS

### Task 4: Package Runtime Dependencies

**Files:**
- Modify: `ScopeSentry-Scan/dockerfile`
- Create: `ScopeSentry-Scan/tools/linux/puredns`
- Create: `ScopeSentry-Scan/tools/linux/massdns`
- Create: `ScopeSentry-Scan/tools/config/puredns-resolvers.txt`

- [ ] **Step 1: Define runtime directory**

Create a dedicated `/apps/ext/puredns` runtime path in the scan image.

- [ ] **Step 2: Add binaries and resolvers**

Copy `puredns`, `massdns`, and the default resolvers file into the image and set executable permissions where needed.

- [ ] **Step 3: Keep packaging aligned with plugin expectations**

Ensure the paths used in `puredns.go` match the files copied by the Dockerfile.

### Task 5: Verify and Document

**Files:**
- Modify: `LOCAL_DEV_SETUP.md` if needed
- Test: `go test ./ScopeSentry-Scan/internal/plugins ./ScopeSentry-Scan/modules/subdomainscan/puredns`
- Test: `bash -n devctl`

- [ ] **Step 1: Run plugin tests**

Run: `go test ./ScopeSentry-Scan/internal/plugins ./ScopeSentry-Scan/modules/subdomainscan/puredns`
Expected: PASS

- [ ] **Step 2: Run broader scan package tests if safe**

Run: `go test ./ScopeSentry-Scan/modules/subdomainscan/...`
Expected: PASS or documented unrelated failures

- [ ] **Step 3: Note packaging follow-up**

Document that a real scan image rebuild is required before the plugin works inside the dev scan container.
