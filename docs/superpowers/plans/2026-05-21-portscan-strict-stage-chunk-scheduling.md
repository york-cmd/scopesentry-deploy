# PortScan Strict-Stage Chunk Scheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Redis Streams based PortScan chunk scheduler that keeps strict stage ordering, splits full-port scans into one-IP chunks, splits non-full-port scans into ten-IP chunks, supports lease renewal and DLQ, and leaves the legacy task path available.

**Architecture:** The central server plans PortScan work into durable chunk documents and Redis Stream messages only after earlier stages have completed. Scanner nodes consume PortScan chunks only when stream mode is enabled, renew their lease while executing, acknowledge completed chunks, and let a server-side reaper move exhausted failures into DLQ. The first release is scoped to PortScan only; other stages continue to use the existing task flow.

**Tech Stack:** Go, Gin, MongoDB, Redis Streams via `github.com/redis/go-redis/v9`, Vue 3, Element Plus, existing ScopeSentry task/progress APIs.

---

## Confirmed Product Decisions

| Decision | Value |
|---|---|
| Stage strategy | Strict stage mode only |
| First migrated module | PortScan only |
| Full-port chunking | One IP or host per chunk |
| Non-full-port chunking | Ten IPs or hosts per chunk |
| Node adaptive pull | Config-gated; disabled by default for rollout |
| DLQ behavior | Blocks next stage by default; user can manually ignore failed chunks and continue |
| Legacy compatibility | Keep `NodeTask:{node}` path and add an opt-in stream mode |

## Scope

### In Scope

- PortScan chunk planning on the server.
- Redis Streams producer/consumer for PortScan chunks.
- Lease renewal while a PortScan chunk is running.
- Reaper that retries abandoned chunks and moves exhausted chunks to DLQ.
- DLQ admin APIs: list, retry, ignore.
- Task progress APIs extended with PortScan chunk summary.
- UI additions in task progress / port comparison view.
- Config switches for stream PortScan and adaptive node pull.

### Out of Scope

- Streaming or chunking SubdomainScan, VulnerabilityScan, URLScan, WebCrawler, DirScan.
- Pipeline mode where PortScan starts before SubdomainScan is complete.
- Per-node MongoDB users / Redis ACL isolation.
- Rewriting existing scan result storage.
- Exactly-once delivery. The implementation provides at-least-once delivery and relies on existing result de-duplication.

## Current Code Context

- Server task creation currently pushes template messages to `NodeTask:{node}` in `ScopeSentry/internal/services/task/common/common.go`.
- Scanner nodes currently poll `NodeTask:{NodeName}` in `ScopeSentry-Scan/internal/task/task.go`.
- PortScan currently executes selected plugins inside `ScopeSentry-Scan/modules/portscan/module.go`.
- PortScan comparison already depends on `PortDiscoveryEvent` and `PortPluginRuntimeEvent` in `ScopeSentry/internal/models/task.go`.
- Scanner Redis wrapper lives in `ScopeSentry-Scan/internal/redis/redis.go`; use `Client()` for Redis Streams operations rather than duplicating connection setup.

## File Structure

### Server: `ScopeSentry`

| File | Responsibility |
|---|---|
| `internal/models/stream_task.go` | Shared task stage/chunk/DLQ models and constants |
| `internal/repositories/streamtask/repository.go` | MongoDB persistence for chunks and DLQ status |
| `internal/services/streamdispatch/chunker.go` | PortScan chunk split rules |
| `internal/services/streamdispatch/chunker_test.go` | Unit tests for full-port and non-full-port chunking |
| `internal/services/streamdispatch/producer.go` | XADD PortScan chunk messages to Redis Streams |
| `internal/services/streamdispatch/producer_test.go` | Redis producer tests with miniredis or fake ops |
| `internal/services/streamdispatch/stage_controller.go` | Strict-stage gate and chunk generation trigger |
| `internal/services/streamdispatch/stage_controller_test.go` | Tests that PortScan is blocked until dependencies complete |
| `internal/services/streamdispatch/reaper.go` | Reclaim stale chunks, retry, and DLQ exhausted chunks |
| `internal/services/streamdispatch/reaper_test.go` | Reaper retry/DLQ tests |
| `internal/api/handlers/streamtask/admin.go` | Chunk summary, DLQ list, retry, ignore APIs |
| `internal/api/routes/task/task.go` | Register authenticated stream task admin routes |
| `internal/services/task/common/common.go` | Dispatch PortScan stream mode when enabled, otherwise keep legacy behavior |
| `internal/services/task/task/task.go` | Merge chunk summary into task progress and allow manual ignore continue |
| `internal/config/config.go` and related config types | Add stream PortScan feature flags |

### Scanner: `ScopeSentry-Scan`

| File | Responsibility |
|---|---|
| `internal/global/type.go` | Add task mode and adaptive pull config fields |
| `internal/config/config.go` | Load stream/adaptive config from env and config file |
| `internal/streamtask/types.go` | Redis stream message schema |
| `internal/streamtask/consumer.go` | XREADGROUP loop for PortScan chunks |
| `internal/streamtask/consumer_test.go` | Consumer parsing and ack behavior tests |
| `internal/streamtask/lease.go` | Lease renewer while chunk is running |
| `internal/streamtask/lease_test.go` | Lease renewal timing tests |
| `internal/streamtask/handler.go` | Convert chunk message into PortScan execution |
| `internal/node/budget/types.go` | Adaptive pull decision types |
| `internal/node/budget/gate.go` | CPU/memory based pull decision, gated by config |
| `internal/node/budget/gate_test.go` | Pull count decisions under resource thresholds |
| `internal/task/task.go` | Start stream consumer when stream mode is enabled; keep legacy loop |
| `modules/portscan/module.go` | Add targeted plugin/chunk execution entrypoint without changing legacy ModuleRun |

### UI: `ScopeSentry-UI`

| File | Responsibility |
|---|---|
| `src/api/task/types.ts` | Stream chunk summary and DLQ types |
| `src/api/task/index.ts` | API clients for summary, DLQ retry, DLQ ignore |
| `src/views/Task/components/PortChunkProgress.vue` | Stage/chunk/DLQ panel for PortScan |
| `src/views/Task/components/ProgressInfo.vue` | Add PortScan chunk progress tab/panel |
| `src/views/Task/components/PortToolComparison.vue` | Show chunk runtime fields alongside plugin comparison |
| `src/locales/zh-CN.ts` and `src/locales/en.ts` | UI labels |

## Redis Key Schema

```text
scan:stream:PortScan                 primary PortScan work stream
scan:stream:PortScan:dlq             PortScan dead-letter stream
scan:group:portscan-workers          consumer group name
scan:lease:{nodeName}                optional hash of chunkId -> stream message id
scan:chunk:{chunkId}:heartbeat       optional heartbeat key for debugging
```

Redis Stream field schema:

```text
chunkId       Mongo chunk _id as hex string
taskId        ScopeSentry task id
taskName      task name
module        "PortScan"
pluginHash    selected PortScan plugin hash
pluginName    selected PortScan plugin name if known at planning time
targets       JSON string array of targets
portRange     effective port range string
fullPort      "true" or "false"
attempt       integer as string
createdAt     unix nanos as string
```

## MongoDB Collections

Use a new collection instead of overloading existing progress hashes:

```text
stream_task_chunks
```

Chunk document:

```go
type StreamTaskChunk struct {
    ID             primitive.ObjectID `bson:"_id,omitempty" json:"id"`
    TaskID         string             `bson:"taskId" json:"taskId"`
    TaskName       string             `bson:"taskName" json:"taskName"`
    Stage          string             `bson:"stage" json:"stage"`
    Module         string             `bson:"module" json:"module"`
    PluginHash     string             `bson:"pluginHash" json:"pluginHash"`
    PluginName     string             `bson:"pluginName" json:"pluginName"`
    Targets        []string           `bson:"targets" json:"targets"`
    PortRange      string             `bson:"portRange" json:"portRange"`
    FullPort       bool               `bson:"fullPort" json:"fullPort"`
    Status         string             `bson:"status" json:"status"`
    Node           string             `bson:"node,omitempty" json:"node,omitempty"`
    StreamID       string             `bson:"streamId,omitempty" json:"streamId,omitempty"`
    Attempt        int                `bson:"attempt" json:"attempt"`
    MaxAttempts    int                `bson:"maxAttempts" json:"maxAttempts"`
    LeaseExpiresAt string             `bson:"leaseExpiresAt,omitempty" json:"leaseExpiresAt,omitempty"`
    CreatedAt      string             `bson:"createdAt" json:"createdAt"`
    StartedAt      string             `bson:"startedAt,omitempty" json:"startedAt,omitempty"`
    FinishedAt     string             `bson:"finishedAt,omitempty" json:"finishedAt,omitempty"`
    Error          string             `bson:"error,omitempty" json:"error,omitempty"`
    Ignored        bool               `bson:"ignored" json:"ignored"`
}
```

Allowed status values:

```text
pending
queued
running
success
retrying
dlq
ignored
cancelled
```

Indexes:

```text
{ taskId: 1, stage: 1, status: 1 }
{ chunkId: 1 } via _id
{ streamId: 1 }
{ status: 1, leaseExpiresAt: 1 }
```

## Chunking Rules

PortScan chunking uses the effective port range after template parameter parsing.

Full-port detection:

```text
full port if portRange is "1-65535", "0-65535", "all", or equivalent normalized range covering 1..65535
```

Split rules:

```text
if fullPort:
  chunk size = 1 target
else:
  chunk size = 10 targets
```

Each selected PortScan plugin gets its own chunk set. For 100 targets and 4 plugins:

```text
fullPort=true  -> 400 chunks
fullPort=false -> 40 chunks
```

This is intentional: it lets nodes distribute work across plugins and targets while preserving plugin comparison data.

## Stage Rules

First release uses strict stage mode:

```text
PortScan chunks are generated only after TargetHandler and PortScanPreparation are complete.
If the task includes SubdomainScan before PortScan, PortScan chunks are generated only after SubdomainScan is complete.
```

No PortScan chunk is XADDed until the strict dependency gate passes.

If DLQ contains unignored PortScan chunks:

```text
PortScan stage status = blocked
Downstream stages are not generated
User can retry DLQ or ignore DLQ
If every DLQ chunk is ignored, downstream stages may continue
```

## Task 1: Add Stream Task Models

**Files:**
- Create: `ScopeSentry/internal/models/stream_task.go`
- Test: `ScopeSentry/internal/models/stream_task_test.go`

- [x] **Step 1.1: Add model constants and structs**

Create `ScopeSentry/internal/models/stream_task.go` with chunk statuses, stage constants, and the `StreamTaskChunk` model shown in the MongoDB Collections section.

- [x] **Step 1.2: Add status helper tests**

Create tests that verify:

```text
success and ignored are terminal statuses
dlq blocks continuation unless ignored=true
running is not terminal
```

Run:

```bash
cd ScopeSentry
go test ./internal/models -run StreamTask -v
```

Expected: tests pass.

- [ ] **Step 1.3: Commit**

```bash
git add ScopeSentry/internal/models/stream_task.go ScopeSentry/internal/models/stream_task_test.go
git commit -m "feat(streamtask): add chunk status models"
```

## Task 2: Add Server Repository

**Files:**
- Create: `ScopeSentry/internal/repositories/streamtask/repository.go`
- Test: `ScopeSentry/internal/repositories/streamtask/repository_test.go`

- [x] **Step 2.1: Define repository interface**

The repository must expose:

```go
type Repository interface {
    InsertChunks(ctx context.Context, chunks []models.StreamTaskChunk) error
    UpdateChunkStatus(ctx context.Context, id primitive.ObjectID, update bson.M) error
    FindChunks(ctx context.Context, filter bson.M, opts ...*options.FindOptions) ([]models.StreamTaskChunk, error)
    CountChunks(ctx context.Context, filter bson.M) (int64, error)
    MarkChunkQueued(ctx context.Context, id primitive.ObjectID, streamID string) error
    MarkChunkRunning(ctx context.Context, id primitive.ObjectID, node string, leaseExpiresAt string) error
    MarkChunkSuccess(ctx context.Context, id primitive.ObjectID) error
    MarkChunkDLQ(ctx context.Context, id primitive.ObjectID, errMsg string) error
    MarkChunkIgnored(ctx context.Context, id primitive.ObjectID) error
}
```

- [x] **Step 2.2: Add tests with a test Mongo database**

Use existing Mongo test patterns from `ScopeSentry/internal/database/mongodb/*_test.go`. Verify insert, queued, running, success, dlq, ignored transitions.

Run:

```bash
cd ScopeSentry
go test ./internal/repositories/streamtask -v
```

Expected: repository tests pass when Mongo test setup is available; if local Mongo is unavailable, skip using the same guard pattern used by existing Mongo tests.

- [ ] **Step 2.3: Commit**

```bash
git add ScopeSentry/internal/repositories/streamtask
git commit -m "feat(streamtask): persist task chunks"
```

## Task 3: Add PortScan Chunker

**Files:**
- Create: `ScopeSentry/internal/services/streamdispatch/chunker.go`
- Test: `ScopeSentry/internal/services/streamdispatch/chunker_test.go`

- [x] **Step 3.1: Implement port range normalization**

Add helpers:

```go
func IsFullPortRange(portRange string) bool
func PortScanChunkSize(portRange string) int
func SplitTargets(targets []string, chunkSize int) [][]string
```

Expected behavior:

```text
IsFullPortRange("1-65535") == true
IsFullPortRange("0-65535") == true
IsFullPortRange("all") == true
IsFullPortRange("80,443") == false
PortScanChunkSize("1-65535") == 1
PortScanChunkSize("80,443") == 10
```

- [x] **Step 3.2: Implement plugin-target chunk expansion**

Add:

```go
func BuildPortScanChunks(task models.Task, template models.ScanTemplate, targets []string) ([]models.StreamTaskChunk, error)
```

Rules:

```text
For each selected PortScan plugin, create chunks from the same target list.
Use chunk size 1 for full ports.
Use chunk size 10 for non-full ports.
Set Status=pending and MaxAttempts=3.
```

- [x] **Step 3.3: Test the confirmed split rules**

Tests:

```text
25 targets, 2 plugins, portRange=1-65535 -> 50 chunks, each with 1 target
25 targets, 2 plugins, portRange=80,443 -> 6 chunks, target sizes 10,10,5 for each plugin
0 targets -> no chunks
0 plugins -> no chunks
```

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run Chunk -v
```

Expected: tests pass.

- [ ] **Step 3.4: Commit**

```bash
git add ScopeSentry/internal/services/streamdispatch/chunker.go \
        ScopeSentry/internal/services/streamdispatch/chunker_test.go
git commit -m "feat(streamdispatch): split portscan work into chunks"
```

## Task 4: Add Redis Stream Producer

**Files:**
- Create: `ScopeSentry/internal/services/streamdispatch/producer.go`
- Test: `ScopeSentry/internal/services/streamdispatch/producer_test.go`

- [x] **Step 4.1: Define stream producer**

Add:

```go
const PortScanStreamKey = "scan:stream:PortScan"
const PortScanDLQKey = "scan:stream:PortScan:dlq"
const PortScanConsumerGroup = "portscan-workers"

type Producer struct {
    redis *redis.Client
    repo  streamtask.Repository
}
```

Producer responsibilities:

```text
Ensure consumer group exists for scan:stream:PortScan.
XADD one entry per chunk.
Mark chunk status queued and store stream id.
```

- [x] **Step 4.2: Test stream fields**

Verify `XADD` fields include `chunkId`, `taskId`, `module`, `pluginHash`, `targets`, `portRange`, `fullPort`, and `attempt`.

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run Producer -v
```

Expected: tests pass.

- [ ] **Step 4.3: Commit**

```bash
git add ScopeSentry/internal/services/streamdispatch/producer.go \
        ScopeSentry/internal/services/streamdispatch/producer_test.go
git commit -m "feat(streamdispatch): publish portscan chunks to redis streams"
```

## Task 5: Add Strict Stage Controller

**Files:**
- Create: `ScopeSentry/internal/services/streamdispatch/stage_controller.go`
- Test: `ScopeSentry/internal/services/streamdispatch/stage_controller_test.go`
- Modify: `ScopeSentry/internal/services/task/common/common.go`

- [x] **Step 5.1: Implement dependency gate**

Add:

```go
func CanGeneratePortScanChunks(ctx context.Context, task models.Task) (bool, string, error)
```

First release checks:

```text
The task selected PortScan in its template.
TargetHandler is complete for all targets.
If SubdomainScan is selected, SubdomainScan is complete for all targets.
PortScanPreparation is complete when selected.
No unignored DLQ chunks exist for this task and PortScan stage.
```

- [x] **Step 5.2: Integrate opt-in stream dispatch**

Add server config:

```text
stream_task.portscan_enabled
```

In `CreateTaskScan`, when enabled and `CanGeneratePortScanChunks` passes, create and publish PortScan chunks. When disabled, keep `RPushNodeTask` behavior unchanged.

- [x] **Step 5.3: Test strict blocking**

Tests:

```text
SubdomainScan selected and not complete -> no PortScan chunks
SubdomainScan selected and complete -> PortScan chunks generated
Unignored DLQ chunk exists -> no downstream continuation
Ignored DLQ chunk exists -> continuation allowed
```

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch ./internal/services/task/common -run PortScan -v
```

Expected: tests pass.

- [ ] **Step 5.4: Commit**

```bash
git add ScopeSentry/internal/services/streamdispatch/stage_controller.go \
        ScopeSentry/internal/services/streamdispatch/stage_controller_test.go \
        ScopeSentry/internal/services/task/common/common.go
git commit -m "feat(streamdispatch): gate portscan chunks behind strict stage dependencies"
```

## Task 6: Add Scanner Stream Types and Config

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/types.go`
- Modify: `ScopeSentry-Scan/internal/global/type.go`
- Modify: `ScopeSentry-Scan/internal/config/config.go`
- Test: `ScopeSentry-Scan/internal/streamtask/types_test.go`

- [x] **Step 6.1: Add scanner config fields**

Add config values:

```go
TaskMode string `yaml:"taskMode"` // "legacy" or "stream"
StreamPortScanEnabled bool `yaml:"streamPortScanEnabled"`
AdaptivePullEnabled bool `yaml:"adaptivePullEnabled"`
```

Env defaults:

```text
TASK_MODE=legacy
STREAM_PORTSCAN_ENABLED=false
ADAPTIVE_PULL_ENABLED=false
```

- [x] **Step 6.2: Add stream message parser**

`TaskMessage` fields must match the Redis schema. Parser must reject missing `chunkId`, `taskId`, `pluginHash`, or invalid `targets` JSON.

- [x] **Step 6.3: Test parser**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask -run Message -v
```

Expected: tests pass.

- [ ] **Step 6.4: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/types.go \
        ScopeSentry-Scan/internal/streamtask/types_test.go \
        ScopeSentry-Scan/internal/global/type.go \
        ScopeSentry-Scan/internal/config/config.go
git commit -m "feat(streamtask): add scanner stream config and message schema"
```

## Task 7: Add Scanner Lease Renewer

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/lease.go`
- Test: `ScopeSentry-Scan/internal/streamtask/lease_test.go`

- [x] **Step 7.1: Implement lease renewer**

The lease renewer runs while a chunk executes:

```text
Every 60 seconds:
  update chunk lease via server-compatible Redis fields or a server API
  refresh scan:chunk:{chunkId}:heartbeat
Stop when context is cancelled or chunk completes.
```

Use 10 minutes as lease timeout for the first release.

- [x] **Step 7.2: Test renewal lifecycle**

Tests:

```text
renewer writes at least one heartbeat before cancellation
renewer stops after context cancel
renewer does not panic when Redis returns an error
```

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask -run Lease -v
```

Expected: tests pass.

- [ ] **Step 7.3: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/lease.go \
        ScopeSentry-Scan/internal/streamtask/lease_test.go
git commit -m "feat(streamtask): renew portscan chunk leases"
```

## Task 8: Add Scanner Adaptive Pull Gate

**Files:**
- Create: `ScopeSentry-Scan/internal/node/budget/types.go`
- Create: `ScopeSentry-Scan/internal/node/budget/gate.go`
- Test: `ScopeSentry-Scan/internal/node/budget/gate_test.go`

- [x] **Step 8.1: Implement config-gated decision**

When adaptive pull is disabled:

```text
return PullCount = 1
```

When enabled:

```text
CPU < 50 and Mem < 75       -> PullCount 4
CPU >= 50 and CPU < 75      -> PullCount 2
CPU >= 75 and CPU < 85      -> PullCount 1
CPU >= 85 or Mem >= 85      -> PullCount 0
Disk free below configured floor -> PullCount 0
```

- [x] **Step 8.2: Test threshold behavior**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/node/budget -v
```

Expected: tests pass.

- [ ] **Step 8.3: Commit**

```bash
git add ScopeSentry-Scan/internal/node/budget
git commit -m "feat(budget): gate stream pull count by node resources"
```

## Task 9: Add PortScan Chunk Handler on Scanner

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/handler.go`
- Modify: `ScopeSentry-Scan/modules/portscan/module.go`
- Test: `ScopeSentry-Scan/modules/portscan/module_test.go`

- [x] **Step 9.1: Add targeted plugin execution API**

Add a method that executes exactly one PortScan plugin over the chunk target list:

```go
func (r *Runner) RunPortScanChunk(pluginHash string, targets []types.DomainSkip, resultChan chan interface{}) error
```

It must:

```text
Resolve the configured plugin by pluginHash.
Apply existing plugin parameter parsing and PortRange merge.
Run only that plugin.
Record PortPluginRuntimeEvent per chunk.
Use existing processPortScanResult for de-duplication and discovery events.
```

Legacy `ModuleRun` remains unchanged.

- [x] **Step 9.2: Add chunk handler**

`handler.go` converts stream message targets into `types.DomainSkip`, builds `options.TaskOptions`, creates a PortScan runner, starts lease renewal, runs the chunk, and returns success/failure.

- [x] **Step 9.3: Test chunk handler**

Tests:

```text
RunPortScanChunk calls only the requested plugin
RunPortScanChunk handles ten targets
RunPortScanChunk returns error for unknown plugin hash
```

Run:

```bash
cd ScopeSentry-Scan
go test ./modules/portscan ./internal/streamtask -run PortScanChunk -v
```

Expected: tests pass.

- [ ] **Step 9.4: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/handler.go \
        ScopeSentry-Scan/modules/portscan/module.go \
        ScopeSentry-Scan/modules/portscan/module_test.go
git commit -m "feat(portscan): execute stream chunks by plugin and target batch"
```

## Task 10: Add Scanner Consumer

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/consumer.go`
- Test: `ScopeSentry-Scan/internal/streamtask/consumer_test.go`
- Modify: `ScopeSentry-Scan/internal/task/task.go`

- [x] **Step 10.1: Implement XREADGROUP loop**

Consumer behavior:

```text
Ensure group exists.
Ask budget gate for pull count.
If pull count is 0, sleep and continue.
XREADGROUP from scan:stream:PortScan with COUNT=pullCount.
Mark chunk running.
Run chunk handler.
On success, XACK and mark chunk success.
On failure, leave unacked and record error for reaper.
```

- [x] **Step 10.2: Keep legacy mode**

`GetTask()` behavior:

```text
if TaskMode == "stream" && StreamPortScanEnabled:
  start PortScan stream consumer
else:
  RunRedisTask()
```

First release may run both only when explicitly configured, but default remains legacy.

- [x] **Step 10.3: Test consumer**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask ./internal/task -run Consumer -v
```

Expected: tests pass.

- [ ] **Step 10.4: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/consumer.go \
        ScopeSentry-Scan/internal/streamtask/consumer_test.go \
        ScopeSentry-Scan/internal/task/task.go
git commit -m "feat(streamtask): consume portscan chunks from redis streams"
```

## Task 11: Add Server Reaper and DLQ Admin

**Files:**
- Create: `ScopeSentry/internal/services/streamdispatch/reaper.go`
- Test: `ScopeSentry/internal/services/streamdispatch/reaper_test.go`
- Create: `ScopeSentry/internal/api/handlers/streamtask/admin.go`
- Modify: `ScopeSentry/internal/api/routes/task/task.go`

- [x] **Step 11.1: Implement reaper**

Reaper behavior:

```text
Find running chunks with leaseExpiresAt older than now.
If attempt < maxAttempts:
  increment attempt
  set status retrying
  XADD replacement message
  set status queued
If attempt >= maxAttempts:
  set status dlq
  XADD compact DLQ event to scan:stream:PortScan:dlq
```

- [x] **Step 11.2: Implement admin APIs**

Routes:

```text
POST /api/task/stream/portscan/summary
POST /api/task/stream/portscan/dlq
POST /api/task/stream/portscan/dlq/retry
POST /api/task/stream/portscan/dlq/ignore
```

Ignore behavior:

```text
Mark chunk ignored=true, status=ignored.
If all DLQ chunks for the stage are ignored, allow manual continuation.
```

- [x] **Step 11.3: Test retry and ignore**

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch ./internal/api/handlers/streamtask -run "Reaper|DLQ" -v
```

Expected: tests pass.

- [ ] **Step 11.4: Commit**

```bash
git add ScopeSentry/internal/services/streamdispatch/reaper.go \
        ScopeSentry/internal/services/streamdispatch/reaper_test.go \
        ScopeSentry/internal/api/handlers/streamtask/admin.go \
        ScopeSentry/internal/api/routes/task/task.go
git commit -m "feat(streamdispatch): requeue stale chunks and expose dlq controls"
```

## Task 12: Add Progress Summary Integration

**Files:**
- Modify: `ScopeSentry/internal/services/task/task/task.go`
- Modify: `ScopeSentry/internal/api/handlers/task/task.go`

- [x] **Step 12.1: Extend task progress response**

Add optional `portScanChunks` payload:

```json
{
  "stage": "PortScan",
  "total": 40,
  "pending": 5,
  "running": 3,
  "success": 30,
  "dlq": 2,
  "ignored": 0,
  "blocked": true
}
```

- [x] **Step 12.2: Preserve existing response shape**

Existing `list` and `total` fields must not change so `ProgressInfo.vue` keeps working during rollout.

- [x] **Step 12.3: Test response compatibility**

Run:

```bash
cd ScopeSentry
go test ./internal/services/task/task ./internal/api/handlers/task -run Progress -v
```

Expected: tests pass.

- [ ] **Step 12.4: Commit**

```bash
git add ScopeSentry/internal/services/task/task/task.go \
        ScopeSentry/internal/api/handlers/task/task.go
git commit -m "feat(task): include portscan chunk summary in progress"
```

## Task 13: Add UI Chunk and DLQ Panel

**Files:**
- Modify: `ScopeSentry-UI/src/api/task/types.ts`
- Modify: `ScopeSentry-UI/src/api/task/index.ts`
- Create: `ScopeSentry-UI/src/views/Task/components/PortChunkProgress.vue`
- Modify: `ScopeSentry-UI/src/views/Task/components/ProgressInfo.vue`
- Modify: `ScopeSentry-UI/src/locales/zh-CN.ts`
- Modify: `ScopeSentry-UI/src/locales/en.ts`

- [x] **Step 13.1: Add API types and clients**

Add clients for summary, DLQ list, retry, and ignore routes.

- [x] **Step 13.2: Build `PortChunkProgress.vue`**

Panel sections:

```text
Summary cards: total / running / success / dlq / ignored
Chunk table: plugin, target count, node, status, attempt, start, finish, error
DLQ actions: retry, ignore
Blocked banner when unignored DLQ exists
```

- [x] **Step 13.3: Integrate into progress dialog**

Add the panel under the existing `PortToolComparison` tab or as a sibling panel in `ProgressInfo.vue`.

- [x] **Step 13.4: Run UI checks**

Run:

```bash
cd ScopeSentry-UI
pnpm lint
pnpm build
```

Expected: build completes.

- [ ] **Step 13.5: Commit**

```bash
git add ScopeSentry-UI/src/api/task/types.ts \
        ScopeSentry-UI/src/api/task/index.ts \
        ScopeSentry-UI/src/views/Task/components/PortChunkProgress.vue \
        ScopeSentry-UI/src/views/Task/components/ProgressInfo.vue \
        ScopeSentry-UI/src/locales/zh-CN.ts \
        ScopeSentry-UI/src/locales/en.ts
git commit -m "feat(ui): show portscan chunk progress and dlq controls"
```

## Task 14: End-to-End Smoke Test

**Files:**
- Modify: `scripts/dev-smoke.sh`
- Create: `scripts/tests/portscan_stream_chunk_smoke.sh`

- [x] **Step 14.1: Add stream mode smoke script**

Script should:

```text
Start local DB/server/scan.
Enable stream PortScan mode.
Create a task with at least 21 targets and two PortScan plugins.
Use non-full port range 80,443.
Assert 6 chunks are created.
Assert at least one chunk reaches success.
Assert task progress API returns portScanChunks.
```

- [x] **Step 14.2: Add full-port chunk assertion**

Create a second task with three targets and full port range `1-65535`; assert each plugin gets one-target chunks.

- [x] **Step 14.3: Run smoke**

Run:

```bash
bash scripts/tests/portscan_stream_chunk_smoke.sh
```

Expected:

```text
portscan stream chunk smoke passed
```

- [ ] **Step 14.4: Commit**

```bash
git add scripts/dev-smoke.sh scripts/tests/portscan_stream_chunk_smoke.sh
git commit -m "test(smoke): cover portscan stream chunk scheduling"
```

## Verification Commands

Run targeted server tests:

```bash
cd ScopeSentry
go test ./internal/models ./internal/repositories/streamtask ./internal/services/streamdispatch ./internal/services/task/common ./internal/services/task/task ./internal/api/handlers/streamtask ./internal/api/handlers/task -v
```

Run targeted scanner tests:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask ./internal/node/budget ./internal/task ./modules/portscan -v
```

Run UI build:

```bash
cd ScopeSentry-UI
pnpm build
```

Run local smoke:

```bash
bash scripts/tests/portscan_stream_chunk_smoke.sh
```

## Rollout Plan

1. Keep production default as legacy mode.
2. Enable stream PortScan only in local dev.
3. Run non-full-port task with 20-50 targets.
4. Run full-port task with 2-3 targets only.
5. Enable on one remote node.
6. Enable on multiple remote nodes.
7. After two stable multi-node runs, consider making PortScan stream mode the recommended mode.

## Operational Notes

- DLQ blocks downstream stages until user retries or ignores failures.
- Ignoring a DLQ chunk must be auditable in chunk document fields.
- Retry creates a new stream message and increments attempt.
- Stream mode must not remove or corrupt existing Redis list keys used by legacy tasks.
- Result writes remain at-least-once; existing duplicate checks must stay enabled.
- Full-port mode can generate many chunks. Start with small target counts during validation.

## Current Implementation Status

- PortScan stream mode is opt-in and legacy mode remains the default.
- Legacy task flow now runs only pre-PortScan stages while stream PortScan is pending, so upstream completion does not mark the whole task complete early.
- Server-side continuation now waits until all PortScan chunks are terminal and no unignored DLQ chunk remains, then dispatches a resume task from PortFingerprint onward.
- Resume dispatch is claimed once per task/stage through `stream_task_continuations` with a unique `{ taskId, stage }` index.
- If PortScan has no downstream stages, or no open ports are discovered for downstream stages, the server completes the task after the chunk gate passes.
- Adaptive pull is now wired into the default scanner stream consumer. It remains disabled by default; when enabled, one consumer read batch is processed concurrently so every pulled chunk is marked running and leased promptly.
- PortScan discovery and runtime event collections now get task-oriented indexes to support comparison and downstream resume queries on large tasks.
- UI shows PortScan chunk summary and DLQ actions with localized labels.
- Plan checkbox state has been synchronized with the actual snapshot state: implementation/test steps through Task 14.3 are marked complete, commit steps remain open.
- Task 14 now has a stream PortScan smoke script and a dev-smoke delegation entrypoint. The script includes dry-run chunk math checks for 21 non-full-port targets with two plugins and three full-port targets with two plugins.
- The stream PortScan smoke is deterministic by default: it uses an isolated host scan runtime, unique smoke node names, fake RustScan/Naabu tools, and clears local PortScan stream keys before creating smoke tasks. Set `PORTSCAN_SMOKE_FAKE_TOOLS=false` or `PORTSCAN_SMOKE_RESET_STREAM=false` to opt out locally.

## Latest Verification

- Server targeted tests passed:

```bash
cd ScopeSentry
go test ./internal/models ./internal/database/mongodb ./internal/services/streamdispatch ./internal/services/task/task ./internal/api/handlers/streamtask ./internal/api/routes/task -run 'StreamTask|Continuation|Chunk|Producer|Reaper|DLQ|PortScanStageGate|Dispatcher|Progress|ResolvePortScanDispatchTargets|Register|ExistingDatabaseIndexSpecs|PortDiscoveryEventIndexes|StreamTaskContinuationIndex|ContinuePortScanDownstream' -v
```

- Scanner targeted tests passed:

```bash
cd ScopeSentry-Scan
go test ./internal/runner ./internal/streamtask ./internal/node/budget ./internal/task ./modules ./modules/portscan ./modules/vulnerabilityscan -run 'ParseStreamPortScanResumeTarget|CreatePortScanResumeProcess|Message|Handler|Consumer|Lease|Decide|RuntimePullBudget|DefaultPullBudget|PortScanChunk|RunPortScanChunk|ModuleRunBypass|ApplyStream|Vulnerability|Passive|Submit|Fatal' -v
```

- UI filtered type check passed for the touched task files:

```bash
cd ScopeSentry-UI
pnpm exec vue-tsc --noEmit --skipLibCheck --pretty false 2>&1 | rg 'PortChunkProgress|ProgressInfo.vue|src/api/task/(index|types)|locales/(zh-CN|en)'
```

- Task 13.4 UI check status:

The exact plan commands are unavailable in this package (`Command "lint" not found`, `Command "build" not found`). Equivalent checks were run with the existing scripts/tools:

```bash
pnpm exec eslint --ext .js,.ts,.vue ./src
pnpm run build:pro
```

Result: full-project ESLint passes with 0 errors and 5 existing warnings in Asset views, and `build:pro` completes. Task 13.4 is complete.

- Stream smoke script checks passed:

```bash
bash -n scripts/tests/dev_scan_env_smoke.sh scripts/tests/portscan_stream_chunk_smoke.sh scripts/dev-smoke.sh scripts/dev-scan.sh scripts/dev-scan-docker.sh
bash scripts/tests/dev_scan_env_smoke.sh
bash scripts/tests/portscan_stream_chunk_smoke.sh --dry-run
bash scripts/dev-smoke.sh --stream-portscan --dry-run
BACKEND_URL=http://127.0.0.1:18082 BACKEND_HEALTH_URL=http://127.0.0.1:18082 MONGODB_DATABASE=ScopeSentry bash scripts/tests/portscan_stream_chunk_smoke.sh
```

The full stream smoke output ended with:

```text
portscan stream chunk smoke passed
```

## Self-Review

- Spec coverage: strict stage, PortScan only, full-port one-IP chunks, non-full-port ten-IP chunks, adaptive pull as config switch, and DLQ blocking with manual ignore are all represented.
- Placeholder scan: no unresolved placeholder items are intentionally left in this plan.
- Type consistency: `StreamTaskChunk`, chunk statuses, Redis stream fields, and UI/API names are used consistently across tasks.
