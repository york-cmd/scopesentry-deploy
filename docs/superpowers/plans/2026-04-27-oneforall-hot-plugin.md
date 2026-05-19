# OneForAll Hot Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a ScopeSentry `SubdomainScan` hot plugin that runs OneForAll in passive candidate mode from a preinstalled image environment.

**Architecture:** The scan image preinstalls OneForAll into `/apps/ext/oneforall` with an isolated Python venv. The hot plugin remains plain interpreted Go loaded by the existing Yaegi custom plugin path, invokes OneForAll with passive-only flags, parses JSON output, resolves candidates through ScopeSentry DNS utilities, and forwards `types.SubdomainResult`.

**Tech Stack:** Go hot plugin via Yaegi, Python 3.8+ venv, OneForAll, Dockerfile base image, existing `options.PluginOption`, `utils.DNS`, `types.SubdomainResult`.

---

## File Structure

- Modify: `ScopeSentry-Scan/dockerfile.base`
  - Install Python/venv/build dependencies.
  - Clone or copy pinned OneForAll.
  - Create `/apps/ext/oneforall/venv`.
  - Install OneForAll requirements.
  - Patch/override OneForAll settings to disable network/version checks.
- Create: `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go`
  - Scan-node hot plugin source using package `plugin`.
  - Exports `GetName`, `Install`, `Check`, `Uninstall`, `Execute`.
  - Uses `options.PluginOption` and `op.ResultFunc`.
- Create: `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall_testdata/result.json`
  - Small JSON fixture documenting expected OneForAll output shape.
- Create: `docs/oneforall-hot-plugin.md`
  - Operator instructions: rebuild base image, upload hot plugin, plugin parameters.
- Modify: `docs/superpowers/specs/2026-04-27-oneforall-hot-plugin-design.md`
  - Only if implementation discoveries require clarifying the approved design.

## Task 1: Prepare Image Runtime

**Files:**
- Modify: `ScopeSentry-Scan/dockerfile.base`

- [ ] **Step 1: Add Python runtime packages**

Modify the final image `apt-get install` block in `ScopeSentry-Scan/dockerfile.base` to include:

```dockerfile
python3
python3-venv
python3-pip
git
build-essential
libffi-dev
libxml2-dev
libxslt-dev
libssl-dev
```

- [ ] **Step 2: Add pinned OneForAll install args**

Add args near the final image stage:

```dockerfile
ARG ONEFORALL_REF=master
ENV ONEFORALL_HOME=/apps/ext/oneforall/OneForAll
ENV ONEFORALL_PYTHON=/apps/ext/oneforall/venv/bin/python
```

- [ ] **Step 3: Install OneForAll into fixed layout**

Add a build step after `/apps/ext/...` directory creation:

```dockerfile
RUN mkdir -p /apps/ext/oneforall && \
    git clone --depth 1 https://github.com/shmilylty/OneForAll.git /apps/ext/oneforall/OneForAll && \
    cd /apps/ext/oneforall/OneForAll && \
    if [ "$ONEFORALL_REF" != "master" ]; then git fetch --depth 1 origin "$ONEFORALL_REF" && git checkout FETCH_HEAD; fi && \
    python3 -m venv /apps/ext/oneforall/venv && \
    /apps/ext/oneforall/venv/bin/pip install --upgrade pip setuptools wheel && \
    /apps/ext/oneforall/venv/bin/pip install -r requirements.txt && \
    mkdir -p /apps/ext/oneforall/OneForAll/results
```

- [ ] **Step 4: Patch noisy OneForAll checks**

Add a conservative settings patch:

```dockerfile
RUN python3 - <<'PY'
from pathlib import Path
path = Path('/apps/ext/oneforall/OneForAll/config/setting.py')
text = path.read_text()
text = text.replace('enable_check_network = True', 'enable_check_network = False')
text = text.replace('enable_check_version = True', 'enable_check_version = False')
path.write_text(text)
PY
```

- [ ] **Step 5: Add image verification command**

Add a build-time check:

```dockerfile
RUN cd /apps/ext/oneforall/OneForAll && /apps/ext/oneforall/venv/bin/python oneforall.py version
```

- [ ] **Step 6: Build base image manually**

Run:

```bash
./devctl scan rebuild-base
```

Expected: base image builds and the OneForAll version command succeeds.

## Task 2: Add Hot Plugin Template

**Files:**
- Create: `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go`
- Create: `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall_testdata/result.json`

- [ ] **Step 1: Create fixture JSON**

Create `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall_testdata/result.json`:

```json
[
  {"subdomain": "www.example.com"},
  {"subdomain": "api.example.com"},
  {"subdomain": ""},
  {"subdomain": "outside.test"}
]
```

- [ ] **Step 2: Create plugin skeleton**

Create `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go`:

```go
package plugin

import (
	"github.com/Autumn-27/ScopeSentry-Scan/internal/options"
)

func GetName() string { return "oneforall" }
func Install() error { return nil }
func Check() error { return nil }
func Uninstall() error { return nil }
func Execute(input interface{}, op options.PluginOption) (interface{}, error) { return nil, nil }
```

- [ ] **Step 3: Add constants and config parsing**

Add:

```go
const (
	defaultOneForAllPath = "/apps/ext/oneforall/OneForAll"
	defaultPythonPath    = "/apps/ext/oneforall/venv/bin/python"
	defaultTimeoutMinute = 20
)
```

Parse only `timeout`, `path`, and `python` using `utils.Tools.ParseArgs(op.Parameter, "timeout", "path", "python")`.

- [ ] **Step 4: Add environment checks**

Implement `Install()`/`Check()` to verify:

- `<path>/oneforall.py`
- `<python>` executable

Do not install packages or clone repositories from plugin code.

- [ ] **Step 5: Build command arguments**

Build args as a slice:

```go
[]string{
	"oneforall.py",
	"--target", domain,
	"--brute", "False",
	"--dns", "False",
	"--req", "False",
	"--takeover", "False",
	"--fmt", "json",
	"--path", outputDir,
	"run",
}
```

- [ ] **Step 6: Execute with timeout**

Use `exec.CommandContext` with `op.Ctx` plus `context.WithTimeout`. Set `cmd.Dir` to OneForAll home. Capture stderr/stdout into buffers for plugin logs.

- [ ] **Step 7: Parse JSON results**

Read all `*.json` files in the output directory. Decode into:

```go
type oneForAllRow struct {
	Subdomain string `json:"subdomain"`
}
```

Collect unique hosts that end with `.` + domain or equal domain.

- [ ] **Step 8: Convert to ScopeSentry results**

For each host:

```go
dnsData := utils.DNS.QueryOne(host)
dnsData.Host = host
result := utils.DNS.DNSdataToSubdomainResult(dnsData)
result.SourcePlugin = op.Name
result.SourcePluginHash = op.PluginId
op.ResultFunc(result)
```

- [ ] **Step 9: Clean temporary output**

Use `defer os.RemoveAll(outputDir)` after successful directory creation.

## Task 3: Validate Hot Plugin Loading

**Files:**
- Use: `ScopeSentry-Scan/internal/plugins/custom.go`
- Use: `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go`

- [ ] **Step 1: Copy template to a temp plugin path**

Run:

```bash
mkdir -p /tmp/scopesentry-plugin-test/SubdomainScan
cp ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go /tmp/scopesentry-plugin-test/SubdomainScan/oneforall.go
```

- [ ] **Step 2: Add a small local load test if needed**

If no existing test can load arbitrary plugin files, add a focused test to `ScopeSentry-Scan/internal/plugins/plugins_test.go` that calls:

```go
LoadCustomPlugin(path, "SubdomainScan", "oneforall")
```

Expected: plugin loads and `GetName()` returns `oneforall`.

- [ ] **Step 3: Run plugin load tests**

Run:

```bash
cd ScopeSentry-Scan && go test ./internal/plugins
```

Expected: PASS.

## Task 4: Add Operator Documentation

**Files:**
- Create: `docs/oneforall-hot-plugin.md`

- [ ] **Step 1: Document rebuild steps**

Include:

```bash
./devctl scan rebuild-base
./devctl scan rebuild
./devctl scan reload
```

- [ ] **Step 2: Document plugin placement**

Explain that scan-node hot plugins are loaded from:

```text
/apps/plugin/SubdomainScan/<pluginHash>.go
```

Or from the backend plugin DB, which writes the same runtime path.

- [ ] **Step 3: Document suggested plugin metadata**

Use:

```text
Name: oneforall
Module: SubdomainScan
Suggested hash/id: oneforall-passive-subdomain
Default params: -timeout 20
```

- [ ] **Step 4: Document runtime mode**

State that the plugin always runs passive-only:

```text
--brute False --dns False --req False --takeover False
```

## Task 5: End-to-End Verification

**Files:**
- Use: `ScopeSentry-Scan/dockerfile.base`
- Use: `ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go`
- Use: `docs/oneforall-hot-plugin.md`

- [ ] **Step 1: Build Go tests**

Run:

```bash
cd ScopeSentry-Scan && go test ./internal/plugins ./modules/subdomainscan
```

Expected: PASS.

- [ ] **Step 2: Verify image runtime**

Run inside scan container:

```bash
cd /apps/ext/oneforall/OneForAll
/apps/ext/oneforall/venv/bin/python oneforall.py --target example.com --brute False --dns False --req False --takeover False --fmt json --path /tmp/oneforall-check run
```

Expected: command exits successfully and writes JSON output under `/tmp/oneforall-check`.

- [ ] **Step 3: Verify hot plugin in a local scan**

Create or upload the hot plugin as `SubdomainScan`, enable it in a test task, and scan a safe domain such as `example.com`.

Expected:

- plugin logs show OneForAll command start/end
- subdomain discovery events show `pluginName=oneforall`
- downstream subdomain chain receives `types.SubdomainResult`

- [ ] **Step 4: Capture known limitations**

Update `docs/oneforall-hot-plugin.md` if any OneForAll source fails because of missing API keys, blocked search engine access, or network restrictions.
