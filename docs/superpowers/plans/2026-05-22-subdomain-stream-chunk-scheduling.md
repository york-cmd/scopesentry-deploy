# SubdomainScan Stream Chunk Scheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Redis Streams based SubdomainScan chunk scheduler that splits work by root domain and plugin, keeps strict stage ordering, supports lease renewal and DLQ, and preserves the legacy task path.

**Architecture:** The scanner keeps TargetHandler in the legacy chain long enough to normalize task inputs and persist stage inputs. The server then plans SubdomainScan work into durable MongoDB chunk documents and Redis Stream messages. Scanner nodes consume SubdomainScan chunks, run one plugin against one root domain per chunk, record discovered subdomains through the existing result pipeline, and only after all chunks are terminal does the server dispatch a resume task for downstream stages.

**Tech Stack:** Go, Gin, MongoDB, Redis Streams via `github.com/redis/go-redis/v9`, Vue 3, Element Plus, existing ScopeSentry task/progress APIs.

---

## Confirmed Product Decisions

| Decision | Value |
|---|---|
| Stage strategy | Strict stage mode only |
| Migrated module | SubdomainScan v1 only |
| Chunking rule | 1 root domain + 1 SubdomainScan plugin = 1 chunk |
| Dictionary sharding | Out of scope for v1 |
| Max attempts | 3 |
| Chunk timeout | 2 hours default; built-in process-based plugins receive timeout parameters from the chunk timeout during chunk execution |
| Node adaptive pull | Reuse existing config-gated adaptive pull; disabled by default for rollout |
| DLQ behavior | Blocks next stage by default; user can manually ignore failed chunks and continue |
| Legacy compatibility | Keep `NodeTask:{node}` path and add an opt-in stream mode |
| UI strategy | Generalize the PortScan chunk panel into a reusable StreamChunk panel |

## Scope

### In Scope

- SubdomainScan chunk planning on the server.
- Persisting TargetHandler outputs needed to plan SubdomainScan chunks and resume downstream stages.
- Redis Streams producer/consumer for SubdomainScan chunks.
- Lease renewal while a SubdomainScan chunk is running.
- Reaper retry and DLQ routing for SubdomainScan chunks.
- DLQ admin APIs that accept a stage and work for both SubdomainScan and PortScan.
- Task progress APIs extended with SubdomainScan chunk summary.
- UI additions in task progress for SubdomainScan chunk summary and DLQ operations.
- Config switches for stream SubdomainScan and per-chunk timeout.
- Smoke tests using fake SubdomainScan plugins.

### Out of Scope

- Splitting one dictionary into many shard files.
- Running the same mutable plugin instance concurrently on one scanner node.
- Stream scheduling for SubdomainSecurity, URLScan, WebCrawler, DirScan, or VulnerabilityScan.
- Pipeline mode where downstream stages start before SubdomainScan chunks are terminal.
- Exactly-once delivery. The implementation remains at-least-once and relies on existing de-duplication.
- Rewriting every SubdomainScan plugin to support a hard process kill. v1 only injects timeout-aware parameters for built-in process-based plugins that already expose timeout flags; custom plugins keep their own timeout behavior.

## Current Code Context

- `ScopeSentry-Scan/modules/manage.go` wires the legacy chain as `TargetHandler -> SubdomainScan -> SubdomainSecurity -> PortScanPreparation -> PortScan`.
- `ScopeSentry-Scan/modules/targethandler/module.go` receives raw task targets and sends normalized outputs to SubdomainScan through an in-memory channel.
- `ScopeSentry-Scan/modules/targethandler/targetparser/targetparser.go` emits `types.RootDomain` for root domains and strings / typed structs for other inputs.
- `ScopeSentry-Scan/modules/subdomainscan/module.go` currently runs all selected SubdomainScan plugins for each string input and forwards results downstream.
- `ScopeSentry-Scan/internal/results/discovery.go` already records `subdomain_discovery_events` and `subdomain_plugin_runtime_events`.
- PortScan stream scheduling already has reusable models, repository, producer, reaper, continuation, API, scanner consumer, lease renewal, and UI patterns.
- `ScopeSentry/internal/services/task/task/task.go` already loads `subdomain_discovery_events` for PortScan dispatch when SubdomainScan was selected.

## Design Notes

### Why TargetHandler Output Persistence Is Required

The server cannot plan SubdomainScan chunks from the raw task target alone because TargetHandler can expand URLs, root domains, IPs, CIDR, company targets, app targets, and other typed inputs. In the legacy flow, those outputs only exist inside scanner memory.

SubdomainScan stream mode must persist the outputs that would have entered the SubdomainScan module. The persisted data has two purposes:

1. Root-domain inputs become SubdomainScan chunks.
2. Non-root-domain pass-through inputs are preserved for downstream resume so strict mode does not drop IPs, direct subdomains, `DomainSkip`, or other typed objects.

### Strict Stage Behavior

When stream SubdomainScan is enabled and the task template selected SubdomainScan plugins:

1. The legacy task runs TargetHandler.
2. The legacy SubdomainScan module is bypassed and does not forward to downstream stages.
3. The server waits until TargetHandler is marked complete.
4. The server reads persisted root-domain stage inputs and creates SubdomainScan chunks.
5. Scanner nodes consume and execute chunks.
6. The server waits until all SubdomainScan chunks are terminal and no unignored DLQ remains.
7. The server dispatches a resume task whose template starts after SubdomainScan.
8. The resume task target list is the union of discovered subdomains and preserved pass-through inputs.

## File Structure

### Server: `ScopeSentry`

| File | Responsibility |
|---|---|
| `internal/models/stream_task.go` | Add SubdomainScan module constant, stage input model, continuation target model |
| `internal/models/stream_task_test.go` | Model terminal status and DLQ blocking tests |
| `internal/repositories/streamstageinput/repository.go` | MongoDB persistence for TargetHandler outputs |
| `internal/repositories/streamstageinput/repository_test.go` | Stage input insert/find/dedup tests |
| `internal/repositories/streamtask/repository.go` | Keep generic chunk repository; no PortScan-specific fields in methods |
| `internal/services/streamdispatch/chunker.go` | Add SubdomainScan chunk builder |
| `internal/services/streamdispatch/chunker_test.go` | Unit tests for 1 root domain x 1 plugin chunks |
| `internal/services/streamdispatch/producer.go` | Add generic `PublishChunks` and module-specific stream routing |
| `internal/services/streamdispatch/producer_test.go` | Producer tests for SubdomainScan stream fields |
| `internal/services/streamdispatch/dispatcher.go` | Add `DispatchSubdomainScanIfReady` |
| `internal/services/streamdispatch/dispatcher_test.go` | Dispatcher tests for duplicate planning and stage gate |
| `internal/services/streamdispatch/continuation.go` | Add generic continuation readiness by stage |
| `internal/services/streamdispatch/continuation_test.go` | SubdomainScan terminal/DLQ readiness tests |
| `internal/services/streamdispatch/reaper.go` | Retry/DLQ publish by chunk module |
| `internal/services/streamdispatch/reaper_test.go` | Reaper tests for SubdomainScan retry and DLQ stream |
| `internal/api/handlers/streamtask/admin.go` | Accept `stage` in summary/DLQ requests; retry by chunk module |
| `internal/api/routes/task/task.go` | Register generic stream chunk routes and keep old PortScan routes if UI still calls them |
| `internal/services/task/task/task.go` | Dispatch SubdomainScan chunks after TargetHandler, resume downstream when ready |
| `internal/config/config.go` | Add server-side `stream_task.subdomain_scan_enabled` |
| `internal/database/mongodb/initdb.go` | Add indexes for `stream_stage_inputs` and general chunk filtering |

### Scanner: `ScopeSentry-Scan`

| File | Responsibility |
|---|---|
| `internal/global/type.go` | Add `SubdomainScanEnabled` and `SubdomainChunkTimeoutSeconds` |
| `internal/config/config.go` | Load stream SubdomainScan config from env/YAML |
| `internal/options/task.go` | Add `StreamSubdomainScanBypass`, `StreamSubdomainScanPending`, `StreamSubdomainScanResume` |
| `internal/results/stage_input.go` | Persist TargetHandler outputs as stage inputs |
| `internal/results/stage_input_test.go` | Stage input normalization and insert tests |
| `modules/targethandler/module.go` | Record outputs that would enter SubdomainScan |
| `modules/targethandler/module_test.go` | Verify root domains and pass-through inputs are recorded |
| `modules/subdomainscan/module.go` | Add strict bypass mode and `RunSubdomainScanChunk` |
| `modules/subdomainscan/module_test.go` | Chunk execution, plugin lock, bypass, and result processing tests |
| `internal/streamtask/types.go` | Generalize stream message parsing; keep PortScan compatibility |
| `internal/streamtask/handler.go` | Route messages by module to SubdomainScan or PortScan runner adapters |
| `internal/streamtask/consumer.go` | Start SubdomainScan consumer when enabled |
| `internal/streamtask/consumer_test.go` | Consumer stream key and ack tests |
| `internal/task/task.go` | Apply stream SubdomainScan bypass before process creation |
| `modules/subdomainscan/subfinder/subfinder.go` | Ensure plugin timeout parameter is respected for chunk mode |
| `modules/subdomainscan/puredns/puredns.go` | Ensure `-et` timeout is respected for chunk mode |

### UI: `ScopeSentry-UI`

| File | Responsibility |
|---|---|
| `src/api/task/types.ts` | Rename chunk types to generic `StreamChunkSummary` and `StreamTaskChunk` |
| `src/api/task/index.ts` | Add generic stream chunk API clients with `stage` parameter |
| `src/views/Task/components/StreamChunkProgress.vue` | Reusable chunk summary/DLQ panel |
| `src/views/Task/components/PortChunkProgress.vue` | Thin wrapper or removal after `StreamChunkProgress` is wired |
| `src/views/Task/components/ProgressInfo.vue` | Show SubdomainScan chunk panel and keep PortScan panel |
| `src/locales/zh-CN.ts` | Chinese labels for SubdomainScan chunks |
| `src/locales/en.ts` | English labels for SubdomainScan chunks |

### Scripts and Smoke Tests

| File | Responsibility |
|---|---|
| `scripts/tests/subdomain_stream_chunk_smoke.sh` | Deterministic stream SubdomainScan smoke with fake plugin |
| `scripts/dev-smoke.sh` | Add `--stream-subdomain` delegation |
| `scripts/dev-scan.sh` | Expose stream SubdomainScan env flags |
| `scripts/dev-scan-docker.sh` | Expose stream SubdomainScan env flags for Docker scan node |
| `scripts/dev-scan-docker-compose.yml` | Pass env flags into scan container |

## Redis Key Schema

```text
scan:stream:SubdomainScan             primary SubdomainScan work stream
scan:stream:SubdomainScan:dlq         SubdomainScan dead-letter stream
scan:group:subdomain-workers          consumer group name
scan:stream:PortScan                  existing PortScan work stream
scan:stream:PortScan:dlq              existing PortScan dead-letter stream
scan:group:portscan-workers           existing PortScan consumer group name
scan:chunk:{chunkId}:heartbeat        optional heartbeat key for debugging
```

Generic Redis Stream field schema:

```text
chunkId       Mongo chunk _id as hex string
taskId        ScopeSentry task id
taskName      task name
stage         "SubdomainScan" or "PortScan"
module        "SubdomainScan" or "PortScan"
pluginHash    selected plugin hash
pluginName    selected plugin name if known
targets       JSON string array of targets
targetKind    "rootDomain" for SubdomainScan chunks, empty for PortScan
portRange     PortScan only
fullPort      PortScan only
taskOptions   JSON encoded template/options
attempt       integer as string
createdAt     formatted time string
timeoutSec    integer as string
```

## MongoDB Collections

### `stream_task_chunks`

Reuse the existing collection. Add fields that are useful for SubdomainScan without breaking PortScan:

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
    TargetKind     string             `bson:"targetKind,omitempty" json:"targetKind,omitempty"`
    PortRange      string             `bson:"portRange,omitempty" json:"portRange,omitempty"`
    TaskOptions    string             `bson:"taskOptions,omitempty" json:"taskOptions,omitempty"`
    FullPort       bool               `bson:"fullPort" json:"fullPort"`
    TimeoutSeconds int                `bson:"timeoutSeconds,omitempty" json:"timeoutSeconds,omitempty"`
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

### `stream_stage_inputs`

Create this collection for persisted TargetHandler outputs:

```go
type StreamStageInput struct {
    ID         primitive.ObjectID `bson:"_id,omitempty" json:"id"`
    TaskID     string             `bson:"taskId" json:"taskId"`
    TaskName   string             `bson:"taskName" json:"taskName"`
    Stage      string             `bson:"stage" json:"stage"`
    Target     string             `bson:"target" json:"target"`
    TargetKind string             `bson:"targetKind" json:"targetKind"`
    Payload    string             `bson:"payload,omitempty" json:"payload,omitempty"`
    Source     string             `bson:"source" json:"source"`
    CreatedAt  string             `bson:"createdAt" json:"createdAt"`
}
```

`TargetKind` values:

```text
rootDomain   Used to generate SubdomainScan chunks
subdomain    Preserved for downstream resume
ip           Preserved for downstream resume
domainSkip   Preserved for downstream resume
other        Preserved as string payload when safe
```

Indexes:

```text
stream_task_chunks:
  { taskId: 1, stage: 1, status: 1 }
  { taskId: 1, stage: 1, pluginHash: 1 }
  { status: 1, leaseExpiresAt: 1 }
  { taskId: 1, stage: 1, ignored: 1 }

stream_stage_inputs:
  unique { taskId: 1, stage: 1, targetKind: 1, target: 1 }
  { taskId: 1, stage: 1, targetKind: 1 }
```

## Task Breakdown

### Task 1: Server Models And Constants

**Files:**
- Modify: `ScopeSentry/internal/models/stream_task.go`
- Modify: `ScopeSentry/internal/models/stream_task_test.go`

- [ ] **Step 1: Write failing model tests**

Add tests:

```go
func TestStreamTaskSubdomainConstants(t *testing.T) {
    if StreamTaskStageSubdomainScan != "SubdomainScan" {
        t.Fatalf("unexpected SubdomainScan stage %q", StreamTaskStageSubdomainScan)
    }
    if StreamTaskModuleSubdomainScan != "SubdomainScan" {
        t.Fatalf("unexpected SubdomainScan module %q", StreamTaskModuleSubdomainScan)
    }
}

func TestStreamStageInputTargetKinds(t *testing.T) {
    input := StreamStageInput{
        TaskID: "task-1",
        Stage: StreamTaskStageSubdomainScan,
        Target: "example.com",
        TargetKind: StreamStageInputKindRootDomain,
    }
    if input.TargetKind != "rootDomain" {
        t.Fatalf("unexpected target kind %q", input.TargetKind)
    }
}
```

Run:

```bash
cd ScopeSentry
go test ./internal/models -run 'StreamTaskSubdomain|StreamStageInput' -v
```

Expected: FAIL because constants/types are missing.

- [ ] **Step 2: Add constants and model types**

Add:

```go
const (
    StreamTaskModulePortScan      = "PortScan"
    StreamTaskModuleSubdomainScan = "SubdomainScan"
)

const (
    StreamStageInputKindRootDomain = "rootDomain"
    StreamStageInputKindSubdomain  = "subdomain"
    StreamStageInputKindIP         = "ip"
    StreamStageInputKindDomainSkip = "domainSkip"
    StreamStageInputKindOther      = "other"
)

type StreamStageInput struct {
    ID         primitive.ObjectID `bson:"_id,omitempty" json:"id"`
    TaskID     string             `bson:"taskId" json:"taskId"`
    TaskName   string             `bson:"taskName" json:"taskName"`
    Stage      string             `bson:"stage" json:"stage"`
    Target     string             `bson:"target" json:"target"`
    TargetKind string             `bson:"targetKind" json:"targetKind"`
    Payload    string             `bson:"payload,omitempty" json:"payload,omitempty"`
    Source     string             `bson:"source" json:"source"`
    CreatedAt  string             `bson:"createdAt" json:"createdAt"`
}
```

Add `TargetKind` and `TimeoutSeconds` to `StreamTaskChunk`.

- [ ] **Step 3: Verify tests pass**

Run:

```bash
cd ScopeSentry
go test ./internal/models -run 'StreamTask|StreamStageInput' -v
```

Expected: PASS.

### Task 2: Stage Input Repository

**Files:**
- Create: `ScopeSentry/internal/repositories/streamstageinput/repository.go`
- Create: `ScopeSentry/internal/repositories/streamstageinput/repository_test.go`
- Modify: `ScopeSentry/internal/database/mongodb/initdb.go`
- Modify: `ScopeSentry/internal/database/mongodb/initdb_test.go`

- [ ] **Step 1: Write repository tests**

Test behavior:

```go
func TestRepositoryUpsertsAndFindsStageInputs(t *testing.T) {
    collection := streamStageInputTestCollection(t)
    repo := NewRepositoryWithCollection(collection)
    ctx := context.Background()

    input := models.StreamStageInput{
        TaskID: "task-1",
        TaskName: "scan",
        Stage: models.StreamTaskStageSubdomainScan,
        Target: "example.com",
        TargetKind: models.StreamStageInputKindRootDomain,
        Source: "TargetHandler",
        CreatedAt: "2026-05-22 10:00:00",
    }

    if err := repo.UpsertInput(ctx, input); err != nil {
        t.Fatalf("upsert input: %v", err)
    }
    if err := repo.UpsertInput(ctx, input); err != nil {
        t.Fatalf("upsert duplicate input: %v", err)
    }
    inputs, err := repo.FindInputs(ctx, bson.M{"taskId": "task-1"})
    if err != nil {
        t.Fatalf("find inputs: %v", err)
    }
    if len(inputs) != 1 {
        t.Fatalf("expected deduped input, got %d", len(inputs))
    }
}
```

Run:

```bash
cd ScopeSentry
go test ./internal/repositories/streamstageinput -run Repository -v
```

Expected: FAIL because repository does not exist.

- [ ] **Step 2: Implement repository**

Interface:

```go
type Repository interface {
    UpsertInput(ctx context.Context, input models.StreamStageInput) error
    FindInputs(ctx context.Context, filter bson.M, opts ...*options.FindOptions) ([]models.StreamStageInput, error)
    CountInputs(ctx context.Context, filter bson.M) (int64, error)
}
```

Collection name:

```go
const CollectionName = "stream_stage_inputs"
```

`UpsertInput` filter:

```go
bson.M{
    "taskId": input.TaskID,
    "stage": input.Stage,
    "targetKind": input.TargetKind,
    "target": input.Target,
}
```

- [ ] **Step 3: Add index tests**

Add `streamStageInputIndexModels()` tests that assert the unique index keys:

```text
taskId, stage, targetKind, target
```

Run:

```bash
cd ScopeSentry
go test ./internal/database/mongodb -run 'StreamStageInput|ExistingDatabaseIndexSpecs' -v
```

Expected: PASS after indexes are added.

### Task 3: Scanner Stage Input Recording

**Files:**
- Create: `ScopeSentry-Scan/internal/results/stage_input.go`
- Create: `ScopeSentry-Scan/internal/results/stage_input_test.go`
- Modify: `ScopeSentry-Scan/modules/targethandler/module.go`
- Create or modify: `ScopeSentry-Scan/modules/targethandler/module_test.go`

- [ ] **Step 1: Write scanner result tests**

Test normalizing outputs:

```go
func TestBuildSubdomainStageInputFromRootDomain(t *testing.T) {
    input, ok := BuildSubdomainStageInput("task-1", "scan", types.RootDomain{Domain: "example.com"})
    if !ok {
        t.Fatalf("expected root domain input")
    }
    if input.Target != "example.com" || input.TargetKind != "rootDomain" {
        t.Fatalf("unexpected input %#v", input)
    }
}

func TestBuildSubdomainStageInputFromIP(t *testing.T) {
    input, ok := BuildSubdomainStageInput("task-1", "scan", "192.0.2.10")
    if !ok {
        t.Fatalf("expected IP passthrough input")
    }
    if input.TargetKind != "ip" {
        t.Fatalf("unexpected kind %#v", input)
    }
}
```

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/results -run 'BuildSubdomainStageInput|RecordSubdomainStageInput' -v
```

Expected: FAIL because functions do not exist.

- [ ] **Step 2: Implement stage input insert helpers**

Functions:

```go
func BuildSubdomainStageInput(taskID string, taskName string, raw interface{}) (models.StreamStageInput, bool)
func RecordSubdomainStageInput(taskID string, taskName string, raw interface{}) error
```

Use a scanner-local `StreamStageInput` struct in `ScopeSentry-Scan/internal/results/stage_input.go`. Do not import server-side models into `ScopeSentry-Scan`; the BSON field names must match server `stream_stage_inputs`.

Insert with upsert into `stream_stage_inputs` using:

```go
filter := bson.M{
    "taskId": input.TaskID,
    "stage": input.Stage,
    "targetKind": input.TargetKind,
    "target": input.Target,
}
update := bson.M{
    "$setOnInsert": input,
}
```

- [ ] **Step 3: Wire TargetHandler recording**

In `modules/targethandler/module.go`, before forwarding a normalized output to the next module, call:

```go
if global.AppConfig.TaskMode == "stream" && global.AppConfig.StreamTask.SubdomainScanEnabled {
    if err := results.RecordSubdomainStageInput(r.Option.ID, r.Option.TaskName, result); err != nil {
        logger.SlogError(fmt.Sprintf("record subdomain stage input error: %v", err))
    }
}
```

Apply this to both typed outputs and string outputs in the result goroutine.

- [ ] **Step 4: Verify scanner tests**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/results ./modules/targethandler -run 'SubdomainStageInput|TargetHandler' -v
```

Expected: PASS.

### Task 4: Server Subdomain Chunk Builder

**Files:**
- Modify: `ScopeSentry/internal/services/streamdispatch/chunker.go`
- Modify: `ScopeSentry/internal/services/streamdispatch/chunker_test.go`

- [ ] **Step 1: Write failing chunk tests**

Add:

```go
func TestBuildSubdomainScanChunksOneRootDomainPerPluginChunk(t *testing.T) {
    task := models.Task{TaskID: "task-sub", Name: "subdomain task"}
    template := models.ScanTemplate{
        SubdomainScan: []string{"subfinder-hash", "puredns-hash"},
        Parameters: models.Parameters{
            SubdomainScan: map[string]string{
                "subfinder-hash": "-t 10",
                "puredns-hash": "-subfile /tmp/subs.txt",
            },
        },
    }
    roots := []string{"example.com", "test.com", "demo.com"}

    chunks, err := BuildSubdomainScanChunks(task, template, roots)
    if err != nil {
        t.Fatalf("BuildSubdomainScanChunks returned error: %v", err)
    }
    if len(chunks) != 6 {
        t.Fatalf("expected 6 chunks, got %d", len(chunks))
    }
    for _, chunk := range chunks {
        if chunk.Stage != models.StreamTaskStageSubdomainScan {
            t.Fatalf("unexpected stage %#v", chunk)
        }
        if chunk.Module != models.StreamTaskModuleSubdomainScan {
            t.Fatalf("unexpected module %#v", chunk)
        }
        if len(chunk.Targets) != 1 {
            t.Fatalf("SubdomainScan v1 chunk must contain one root domain, got %d", len(chunk.Targets))
        }
        if chunk.TargetKind != models.StreamStageInputKindRootDomain {
            t.Fatalf("unexpected target kind %q", chunk.TargetKind)
        }
        if chunk.MaxAttempts != 3 || chunk.TimeoutSeconds != 7200 {
            t.Fatalf("unexpected defaults %#v", chunk)
        }
    }
}
```

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run 'BuildSubdomainScanChunks' -v
```

Expected: FAIL because builder does not exist.

- [ ] **Step 2: Implement builder**

Add:

```go
const defaultSubdomainChunkTimeoutSeconds = 7200
```

Builder rules:

```go
func BuildSubdomainScanChunks(task models.Task, template models.ScanTemplate, rootDomains []string) ([]models.StreamTaskChunk, error)
```

Rules:

- Return empty slice when root domains are empty or `template.SubdomainScan` is empty.
- Deduplicate and trim root domains.
- For every plugin hash and root domain, create one chunk.
- Set `Stage=SubdomainScan`, `Module=SubdomainScan`, `TargetKind=rootDomain`.
- Set `Attempt=1`, `MaxAttempts=3`, `TimeoutSeconds=7200`, `Status=pending`.
- Marshal `template` into `TaskOptions`.

- [ ] **Step 3: Verify tests**

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run 'SubdomainScanChunks|PortScanChunks|SplitTargets' -v
```

Expected: PASS.

### Task 5: Generic Producer And Stream Routing

**Files:**
- Modify: `ScopeSentry/internal/services/streamdispatch/producer.go`
- Modify: `ScopeSentry/internal/services/streamdispatch/producer_test.go`

- [ ] **Step 1: Write failing producer tests**

Add a test that publishes a SubdomainScan chunk and asserts:

```text
stream = scan:stream:SubdomainScan
group = subdomain-workers
stage = SubdomainScan
module = SubdomainScan
targetKind = rootDomain
timeoutSec = 7200
```

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run 'Producer.*Subdomain|Producer.*PortScan' -v
```

Expected: FAIL before generic routing exists.

- [ ] **Step 2: Implement stream routing**

Add constants:

```go
const (
    SubdomainScanStreamKey     = "scan:stream:SubdomainScan"
    SubdomainScanDLQKey        = "scan:stream:SubdomainScan:dlq"
    SubdomainScanConsumerGroup = "subdomain-workers"
)
```

Add:

```go
func StreamKeyForModule(module string) (stream string, group string, dlq string, ok bool)
func (p *Producer) PublishChunks(ctx context.Context, chunks []models.StreamTaskChunk) error
func (p *Producer) PublishSubdomainScanChunks(ctx context.Context, chunks []models.StreamTaskChunk) error
```

Keep `PublishPortScanChunks` as a wrapper around `PublishChunks` so existing code keeps compiling.

- [ ] **Step 3: Convert field builder to generic**

Replace `portScanChunkFields` with:

```go
func chunkFields(chunk models.StreamTaskChunk) (map[string]interface{}, error)
```

Keep `portScanChunkFields` as a wrapper if existing tests reference it.

- [ ] **Step 4: Verify producer tests**

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run Producer -v
```

Expected: PASS.

### Task 6: Generic Reaper And DLQ Publisher

**Files:**
- Modify: `ScopeSentry/internal/services/streamdispatch/reaper.go`
- Modify: `ScopeSentry/internal/services/streamdispatch/reaper_test.go`

- [ ] **Step 1: Write failing reaper tests**

Add SubdomainScan retry and DLQ tests:

```go
func TestReaperRepublishesExpiredSubdomainChunkToSubdomainStream(t *testing.T) {
    chunk := models.StreamTaskChunk{
        ID: primitive.NewObjectID(),
        TaskID: "task-1",
        Stage: models.StreamTaskStageSubdomainScan,
        Module: models.StreamTaskModuleSubdomainScan,
        PluginHash: "subfinder",
        Targets: []string{"example.com"},
        Status: models.StreamTaskChunkStatusRunning,
        Attempt: 1,
        MaxAttempts: 3,
        LeaseExpiresAt: "2026-05-22 10:00:00",
    }
    repo := &fakeReaperRepository{chunks: []models.StreamTaskChunk{chunk}}
    producer := &fakeChunkProducer{}
    reaper := NewReaper(repo, producer, &fakeDLQPublisher{})

    if err := reaper.ReapExpired(context.Background()); err != nil {
        t.Fatalf("reap expired: %v", err)
    }
    if len(producer.published) != 1 || producer.published[0].Module != models.StreamTaskModuleSubdomainScan {
        t.Fatalf("expected subdomain chunk to be republished, got %#v", producer.published)
    }
}
```

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run Reaper -v
```

Expected: FAIL until producer interface is generic.

- [ ] **Step 2: Update interfaces**

Change:

```go
type ChunkProducer interface {
    PublishChunks(ctx context.Context, chunks []models.StreamTaskChunk) error
}
```

Update reaper to call `PublishChunks`.

- [ ] **Step 3: Route DLQ by module**

In `RedisDLQPublisher.PublishDLQ`, call `StreamKeyForModule(chunk.Module)` and XADD to the returned DLQ stream.

- [ ] **Step 4: Verify tests**

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run 'Reaper|Producer' -v
```

Expected: PASS.

### Task 7: Generic Continuation Readiness

**Files:**
- Modify: `ScopeSentry/internal/services/streamdispatch/continuation.go`
- Modify: `ScopeSentry/internal/services/streamdispatch/continuation_test.go`

- [ ] **Step 1: Write failing tests**

Add:

```go
func TestSubdomainContinuationBlocksOnActiveChunks(t *testing.T) {
    controller := NewContinuationController(&fakeContinuationRepository{
        total: 3,
        active: 1,
    })
    state, err := controller.StageReadyForContinuation(context.Background(), "task-1", models.StreamTaskStageSubdomainScan)
    if err != nil {
        t.Fatalf("StageReadyForContinuation returned error: %v", err)
    }
    if state.Ready || state.Reason != "SubdomainScan chunks still running" {
        t.Fatalf("unexpected state %#v", state)
    }
}
```

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run Continuation -v
```

Expected: FAIL until generic method exists.

- [ ] **Step 2: Implement generic method**

Add:

```go
type StageContinuationState struct {
    Ready       bool
    Reason      string
    Total       int64
    Active      int64
    BlockingDLQ int64
}

func (c *ContinuationController) StageReadyForContinuation(ctx context.Context, taskID string, stage string) (StageContinuationState, error)
```

Keep:

```go
func (c *ContinuationController) PortScanReadyForContinuation(ctx context.Context, taskID string) (PortScanContinuationState, error)
```

as a compatibility wrapper.

- [ ] **Step 3: Verify readiness tests**

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run Continuation -v
```

Expected: PASS.

### Task 8: Subdomain Dispatcher And Stage Gate

**Files:**
- Modify: `ScopeSentry/internal/services/streamdispatch/dispatcher.go`
- Modify: `ScopeSentry/internal/services/streamdispatch/dispatcher_test.go`
- Modify: `ScopeSentry/internal/services/streamdispatch/stage_controller.go`
- Modify: `ScopeSentry/internal/services/streamdispatch/stage_controller_test.go`

- [ ] **Step 1: Write failing dispatcher tests**

Test:

```go
func TestDispatcherPlansSubdomainChunksAfterTargetHandler(t *testing.T) {
    task := models.Task{TaskID: "task-1", Name: "scan"}
    template := models.ScanTemplate{TargetHandler: []string{"parser"}, SubdomainScan: []string{"subfinder", "puredns"}}
    stage := NewStageController(&fakeStageProgressStore{
        done: map[string]bool{models.StreamTaskStageTargetHandler: true},
    }, &fakeStageChunkRepository{})
    repo := &fakeDispatcherChunkRepository{}
    producer := &fakeChunkProducer{}
    dispatcher := NewDispatcher(stage, repo, producer)

    dispatched, reason, err := dispatcher.DispatchSubdomainScanIfReady(context.Background(), task, template, []string{"example.com", "test.com"})
    if err != nil {
        t.Fatalf("dispatch: %v", err)
    }
    if !dispatched || reason != "" {
        t.Fatalf("expected dispatch, dispatched=%v reason=%q", dispatched, reason)
    }
    if len(producer.published) != 4 {
        t.Fatalf("expected 4 chunks, got %d", len(producer.published))
    }
}
```

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run 'Dispatcher.*Subdomain|StageController.*Subdomain' -v
```

Expected: FAIL until dispatcher exists.

- [ ] **Step 2: Implement stage gate**

Add:

```go
func (c *StageController) CanGenerateSubdomainScanChunks(ctx context.Context, task models.Task, template models.ScanTemplate) (bool, string, error)
```

Rules:

- If no `TargetHandler` selected, allow immediately.
- If `TargetHandler` selected, require `TargetHandler` progress end.
- If any unignored SubdomainScan DLQ already exists, block.
- Do not require PortScanPreparation or later stages.

- [ ] **Step 3: Implement dispatcher**

Add:

```go
func (d *Dispatcher) DispatchSubdomainScanIfReady(ctx context.Context, task models.Task, template models.ScanTemplate, rootDomains []string) (bool, string, error)
```

Rules:

- Do nothing if chunks already exist for `{taskId, stage: SubdomainScan}`.
- Call `CanGenerateSubdomainScanChunks`.
- Call `BuildSubdomainScanChunks`.
- Insert chunks.
- Publish chunks.

- [ ] **Step 4: Verify tests**

Run:

```bash
cd ScopeSentry
go test ./internal/services/streamdispatch -run 'Dispatcher|StageController|SubdomainScanChunks' -v
```

Expected: PASS.

### Task 9: Server Task Service Dispatch And Downstream Resume

**Files:**
- Modify: `ScopeSentry/internal/services/task/task/task.go`
- Create: `ScopeSentry/internal/services/task/task/subdomain_downstream_test.go`
- Create: `ScopeSentry/internal/services/task/task/subdomain_dispatch_targets_test.go`

- [ ] **Step 1: Write failing dispatch target tests**

Test loading root domains and pass-through inputs from `stream_stage_inputs`:

```go
func TestResolveSubdomainDispatchRootsUsesStageInputs(t *testing.T) {
    roots, passthrough, err := resolveSubdomainDispatchInputs(context.Background(), "task-1")
    if err != nil {
        t.Fatalf("resolve inputs: %v", err)
    }
    if !slices.Contains(roots, "example.com") {
        t.Fatalf("expected example.com root, got %#v", roots)
    }
    if !slices.Contains(passthrough, "192.0.2.10") {
        t.Fatalf("expected passthrough IP, got %#v", passthrough)
    }
}
```

Use function variables similar to existing `loadSubdomainDiscoveryHostsForTask` to make this test isolated.

Run:

```bash
cd ScopeSentry
go test ./internal/services/task/task -run 'SubdomainDispatch|SubdomainDownstream' -v
```

Expected: FAIL until functions exist.

- [ ] **Step 2: Add dispatch hook**

Add:

```go
func (s *service) dispatchSubdomainScanChunksIfReady(ctx context.Context, task models.Task)
```

Call it from the same progress/task heartbeat path where `dispatchPortScanChunksIfReady` is called, gated by:

```go
if config.GlobalConfig.StreamTask.SubdomainScanEnabled {
    s.dispatchSubdomainScanChunksIfReady(ctx, task)
}
```

- [ ] **Step 3: Add downstream continuation**

Add:

```go
func (s *service) continueSubdomainScanDownstreamIfReady(ctx context.Context, task models.Task) error
```

Rules:

- Check generic stage readiness for `SubdomainScan`.
- Claim continuation once with `{taskId, stage: SubdomainScan}`.
- Load discovered hosts from `subdomain_discovery_events`.
- Load pass-through inputs from `stream_stage_inputs`.
- Deduplicate union.
- If no downstream stages after SubdomainScan, complete task.
- Otherwise trim template before SubdomainScan resume and dispatch legacy resume tasks.

- [ ] **Step 4: Add template trimming**

Add:

```go
func hasPostSubdomainScanStages(template models.ScanTemplate) bool
func trimTemplateBeforeSubdomainScanResume(template *models.ScanTemplate)
```

`trimTemplateBeforeSubdomainScanResume` must clear:

```go
template.TargetHandler = nil
template.SubdomainScan = nil
```

It must keep:

```go
SubdomainSecurity
PortScanPreparation
PortScan
PortFingerprint
AssetMapping
URLScan
WebCrawler
URLSecurity
DirScan
VulnerabilityScan
PassiveScan
```

- [ ] **Step 5: Verify service tests**

Run:

```bash
cd ScopeSentry
go test ./internal/services/task/task -run 'SubdomainDispatch|SubdomainDownstream|ContinueSubdomain|PortScanDownstream' -v
```

Expected: PASS.

### Task 10: Server Config And Indexes

**Files:**
- Modify: `ScopeSentry/internal/config/config.go`
- Modify: `ScopeSentry/internal/config/config.go`
- Modify: `ScopeSentry/internal/database/mongodb/initdb.go`
- Modify: `ScopeSentry/internal/database/mongodb/initdb_test.go`
- Modify: `scripts/install-server.sh`
- Modify: `LOCAL_DEV_SETUP.md`

- [ ] **Step 1: Write config tests**

Add a test for default false:

```go
func TestStreamTaskSubdomainScanDefaultDisabled(t *testing.T) {
    var cfg StreamTaskConfig
    if cfg.SubdomainScanEnabled {
        t.Fatalf("subdomain stream should default disabled")
    }
}
```

- [ ] **Step 2: Add config fields**

Add server config:

```go
type StreamTaskConfig struct {
    PortScanEnabled      bool `mapstructure:"portscan_enabled"`
    SubdomainScanEnabled bool `mapstructure:"subdomain_scan_enabled"`
}
```

Keep default disabled.

- [ ] **Step 3: Add Mongo indexes**

Add `streamStageInputIndexModels`.

Extend chunk indexes if current init only covers PortScan cases.

- [ ] **Step 4: Verify config/index tests**

Run:

```bash
cd ScopeSentry
go test ./internal/config ./internal/database/mongodb -run 'StreamTask|StreamStageInput|ExistingDatabaseIndexSpecs' -v
```

Expected: PASS.

### Task 11: Scanner Config And Task Option Flags

**Files:**
- Modify: `ScopeSentry-Scan/internal/global/type.go`
- Modify: `ScopeSentry-Scan/internal/config/config.go`
- Modify: `ScopeSentry-Scan/internal/options/task.go`
- Modify: `ScopeSentry-Scan/internal/task/task.go`
- Modify: `ScopeSentry-Scan/internal/task/task_test.go`

- [ ] **Step 1: Write failing bypass tests**

Add:

```go
func TestApplyStreamSubdomainScanLegacyBypassClearsLegacySubdomainOnlyInStreamMode(t *testing.T) {
    originalMode := global.AppConfig.TaskMode
    originalEnabled := global.AppConfig.StreamTask.SubdomainScanEnabled
    defer func() {
        global.AppConfig.TaskMode = originalMode
        global.AppConfig.StreamTask.SubdomainScanEnabled = originalEnabled
    }()

    global.AppConfig.TaskMode = "stream"
    global.AppConfig.StreamTask.SubdomainScanEnabled = true

    runnerOption := options.TaskOptions{
        TargetHandler: []string{"target-parser"},
        SubdomainScan: []string{"subfinder"},
        SubdomainSecurity: []string{"takeover"},
        PortScan: []string{"naabu"},
    }
    applyStreamSubdomainScanLegacyBypass(&runnerOption)

    if len(runnerOption.SubdomainScan) != 0 {
        t.Fatalf("expected legacy SubdomainScan plugins to be cleared, got %#v", runnerOption.SubdomainScan)
    }
    if !runnerOption.StreamSubdomainScanBypass || !runnerOption.StreamSubdomainScanPending {
        t.Fatalf("expected stream SubdomainScan flags to be set")
    }
    if len(runnerOption.SubdomainSecurity) != 1 || len(runnerOption.PortScan) != 1 {
        t.Fatalf("downstream stages should remain in template for resume metadata: %#v", runnerOption)
    }
}
```

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/task -run 'StreamSubdomainScanLegacyBypass' -v
```

Expected: FAIL until flags/functions exist.

- [ ] **Step 2: Add config fields**

Add scanner config:

```go
type StreamTaskConfig struct {
    PortScanEnabled              bool `yaml:"streamPortScanEnabled"`
    SubdomainScanEnabled         bool `yaml:"streamSubdomainScanEnabled"`
    AdaptivePullEnabled          bool `yaml:"adaptivePullEnabled"`
    SubdomainChunkTimeoutSeconds int  `yaml:"subdomainChunkTimeoutSeconds"`
}
```

Load env:

```text
STREAM_SUBDOMAIN_ENABLED=false
STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS=7200
```

- [ ] **Step 3: Add task option flags**

Add:

```go
StreamSubdomainScanBypass  bool `bson:"streamSubdomainScanBypass" json:"streamSubdomainScanBypass"`
StreamSubdomainScanPending bool `bson:"streamSubdomainScanPending" json:"streamSubdomainScanPending"`
StreamSubdomainScanResume  bool `bson:"streamSubdomainScanResume" json:"streamSubdomainScanResume"`
```

- [ ] **Step 4: Implement bypass**

Add:

```go
func applyStreamSubdomainScanLegacyBypass(runnerOption *options.TaskOptions)
```

Rules:

- Only apply when `TaskMode == "stream"`, `SubdomainScanEnabled == true`, and template has SubdomainScan plugins.
- Clear `runnerOption.SubdomainScan`.
- Set bypass and pending flags.
- Do not clear downstream stages; they are needed for server-side resume metadata.

- [ ] **Step 5: Verify tests**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/task -run 'StreamSubdomain|StreamPortScan|ApplyStream' -v
```

Expected: PASS.

### Task 12: SubdomainScan Strict Bypass

**Files:**
- Modify: `ScopeSentry-Scan/modules/subdomainscan/module.go`
- Modify: `ScopeSentry-Scan/modules/subdomainscan/module_test.go`

- [ ] **Step 1: Write failing bypass tests**

Add:

```go
func TestSubdomainModuleRunBypassDoesNotForwardInputsDownstream(t *testing.T) {
    next := &fakeNextModule{input: make(chan interface{}, 10)}
    option := &options.TaskOptions{
        ID: "task-1",
        StreamSubdomainScanBypass: true,
        ModuleRunWg: &sync.WaitGroup{},
    }
    option.ModuleRunWg.Add(1)
    runner := NewRunner(option, next)
    input := make(chan interface{}, 2)
    runner.SetInput(input)

    done := make(chan struct{})
    go func() {
        _ = runner.ModuleRun()
        close(done)
    }()
    input <- "example.com"
    close(input)

    select {
    case <-done:
    case <-time.After(time.Second):
        t.Fatalf("module did not exit")
    }
    if len(next.received) != 0 {
        t.Fatalf("bypass should not forward inputs downstream, got %#v", next.received)
    }
}
```

Run:

```bash
cd ScopeSentry-Scan
go test ./modules/subdomainscan -run 'Bypass' -v
```

Expected: FAIL until bypass mode exists.

- [ ] **Step 2: Implement bypass mode**

At the start of `ModuleRun`, if `r.Option.StreamSubdomainScanBypass`:

- Start `NextModule.ModuleRun()` so downstream WaitGroups can drain.
- Drain `r.Input` until closed or task context is canceled.
- Do not call `processDiscoveredSubdomain`.
- Do not forward inputs to downstream.
- Close downstream input when the module exits.
- Mark module WaitGroup done exactly once.

- [ ] **Step 3: Verify tests**

Run:

```bash
cd ScopeSentry-Scan
go test ./modules/subdomainscan -run 'Bypass|ProcessDiscoveredSubdomain' -v
```

Expected: PASS.

### Task 13: SubdomainScan Chunk Execution

**Files:**
- Modify: `ScopeSentry-Scan/modules/subdomainscan/module.go`
- Modify: `ScopeSentry-Scan/modules/subdomainscan/module_test.go`

- [ ] **Step 1: Write failing chunk tests**

Add tests for:

- Calls only requested plugin.
- Handles one root domain per chunk.
- Records plugin runtime event with target and error.
- Processes plugin results through `processDiscoveredSubdomain`.
- Returns error for missing plugin.

Core test:

```go
func TestRunSubdomainScanChunkCallsOnlyRequestedPlugin(t *testing.T) {
    originalGetPlugin := getSubdomainScanPlugin
    defer func() { getSubdomainScanPlugin = originalGetPlugin }()

    called := make(map[string]int)
    getSubdomainScanPlugin = func(module, id string) (interfaces.Plugin, bool) {
        return &fakeSubdomainPlugin{
            id: id,
            name: id,
            execute: func(input interface{}) (interface{}, error) {
                called[id]++
                return nil, nil
            },
        }, true
    }

    option := options.TaskOptions{
        ID: "task-1",
        TaskName: "scan",
        SubdomainScan: []string{"plugin-a", "plugin-b"},
        Parameters: map[string]map[string]string{"SubdomainScan": {}},
    }
    runner := NewRunner(&option, &fakeNextModule{input: make(chan interface{}, 10)})
    err := runner.RunSubdomainScanChunk(context.Background(), "plugin-b", []string{"example.com"}, make(chan interface{}, 10))
    if err != nil {
        t.Fatalf("RunSubdomainScanChunk returned error: %v", err)
    }
    if called["plugin-b"] != 1 || called["plugin-a"] != 0 {
        t.Fatalf("unexpected calls %#v", called)
    }
}
```

Run:

```bash
cd ScopeSentry-Scan
go test ./modules/subdomainscan -run 'RunSubdomainScanChunk' -v
```

Expected: FAIL until chunk runner exists.

- [ ] **Step 2: Add plugin getters and locks**

Add package-level variables:

```go
var getSubdomainScanPlugin = func(module, id string) (interfaces.Plugin, bool) {
    return plugins.GlobalPluginManager.GetPlugin(module, id)
}

var subdomainPluginLocks sync.Map
```

Add helper:

```go
func lockSubdomainPlugin(pluginHash string) func()
```

This prevents one node from mutating the same plugin instance concurrently.

- [ ] **Step 3: Implement chunk execution**

Add:

```go
func (r *Runner) RunSubdomainScanChunk(ctx context.Context, pluginHash string, targets []string, resultChan chan interface{}) error
```

Rules:

- Require exactly one or more root domain targets, but v1 builder sends one.
- Look up only `pluginHash`.
- Set plugin parameter from `r.Option.Parameters["SubdomainScan"][pluginHash]`.
- Set result channel, task ID, task name.
- Execute each target sequentially.
- For every `types.SubdomainResult` from the plugin result channel, call `processDiscoveredSubdomain`.
- Record `SubdomainPluginRuntime` once per target.
- Return first plugin execution error.

- [ ] **Step 4: Verify tests**

Run:

```bash
cd ScopeSentry-Scan
go test ./modules/subdomainscan -run 'RunSubdomainScanChunk|ProcessDiscoveredSubdomain|Bypass' -v
```

Expected: PASS.

### Task 14: Scanner Stream Handler Routing

**Files:**
- Modify: `ScopeSentry-Scan/internal/streamtask/types.go`
- Modify: `ScopeSentry-Scan/internal/streamtask/types_test.go`
- Modify: `ScopeSentry-Scan/internal/streamtask/handler.go`
- Modify: `ScopeSentry-Scan/internal/streamtask/handler_test.go`

- [ ] **Step 1: Write failing message parse tests**

Add:

```go
func TestParseTaskMessageSupportsSubdomainFields(t *testing.T) {
    msg, err := ParseTaskMessage(map[string]interface{}{
        "chunkId": "chunk-1",
        "taskId": "task-1",
        "stage": "SubdomainScan",
        "module": "SubdomainScan",
        "pluginHash": "subfinder",
        "targets": `["example.com"]`,
        "targetKind": "rootDomain",
        "timeoutSec": "7200",
    })
    if err != nil {
        t.Fatalf("ParseTaskMessage returned error: %v", err)
    }
    if msg.Module != "SubdomainScan" || msg.TargetKind != "rootDomain" || msg.TimeoutSeconds != 7200 {
        t.Fatalf("unexpected message %#v", msg)
    }
}
```

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask -run 'ParseTaskMessageSupportsSubdomain|Handler.*Subdomain' -v
```

Expected: FAIL until fields/routing exist.

- [ ] **Step 2: Add generic runner interfaces**

Add:

```go
type SubdomainScanChunkRunner interface {
    Run(ctx context.Context, option options.TaskOptions, pluginHash string, targets []string) error
}
```

Keep `PortScanChunkRunner`.

- [ ] **Step 3: Route by module**

In `Handler.Handle`:

```go
switch message.Module {
case "PortScan":
    return h.handlePortScan(ctx, message)
case "SubdomainScan":
    return h.handleSubdomainScan(ctx, message)
default:
    return fmt.Errorf("unsupported stream module %q", message.Module)
}
```

Both paths must mark running, start lease renewal, mark success, and mark failed on error.

- [ ] **Step 4: Add Subdomain runner adapter**

Add:

```go
type SubdomainScanRunnerAdapter struct{}

func (SubdomainScanRunnerAdapter) Run(ctx context.Context, option options.TaskOptions, pluginHash string, targets []string) error {
    resultChan := make(chan interface{}, 1024)
    runner := subdomainscan.NewRunner(&option, nil)
    err := runner.RunSubdomainScanChunk(ctx, pluginHash, targets, resultChan)
    close(resultChan)
    return err
}
```

If `RunSubdomainScanChunk` consumes its own result channel internally, keep adapter simple and pass a drain channel.

- [ ] **Step 5: Verify handler tests**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask -run 'Message|Handler|Lease' -v
```

Expected: PASS.

### Task 15: Scanner Consumer For Subdomain Stream

**Files:**
- Modify: `ScopeSentry-Scan/internal/streamtask/consumer.go`
- Modify: `ScopeSentry-Scan/internal/streamtask/consumer_test.go`
- Modify: `ScopeSentry-Scan/internal/task/task.go`

- [ ] **Step 1: Write failing consumer tests**

Add tests that `NewDefaultSubdomainConsumer` uses:

```text
scan:stream:SubdomainScan
subdomain-workers
```

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask -run 'SubdomainConsumer|Consumer' -v
```

Expected: FAIL until consumer factory exists.

- [ ] **Step 2: Generalize consumer config**

Refactor consumer to store:

```go
streamKey string
consumerGroup string
```

Keep existing `NewDefaultConsumer()` as the PortScan default.

Add:

```go
func NewDefaultSubdomainConsumer() *Consumer
```

- [ ] **Step 3: Start consumer when enabled**

In `internal/task/task.go`, when:

```go
global.AppConfig.TaskMode == "stream" && global.AppConfig.StreamTask.SubdomainScanEnabled
```

start the SubdomainScan stream consumer in the same lifecycle as the PortScan consumer.

- [ ] **Step 4: Verify consumer tests**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/streamtask ./internal/task -run 'Consumer|StreamSubdomain|StreamPortScan' -v
```

Expected: PASS.

### Task 16: Stream Admin APIs Become Stage-Aware

**Files:**
- Modify: `ScopeSentry/internal/api/handlers/streamtask/admin.go`
- Modify: `ScopeSentry/internal/api/routes/task/task.go`
- Create: `ScopeSentry/internal/api/handlers/streamtask/admin_test.go`

- [ ] **Step 1: Write failing request tests**

Request shape:

```go
type TaskStageRequest struct {
    TaskID string `json:"taskId" binding:"required"`
    Stage  string `json:"stage" binding:"required"`
}
```

Test summary for `SubdomainScan` filters by `stage`.

Run:

```bash
cd ScopeSentry
go test ./internal/api/handlers/streamtask ./internal/api/routes/task -run 'Summary|DLQ|Retry|Ignore|Register' -v
```

Expected: FAIL until stage-aware handler exists.

- [ ] **Step 2: Add stage validation**

Allowed stages:

```text
SubdomainScan
PortScan
```

Reject unsupported stages with bad request.

- [ ] **Step 3: Add generic routes**

Add:

```text
POST /api/task/stream/chunk/summary
POST /api/task/stream/chunk/dlq
POST /api/task/stream/chunk/dlq/retry
POST /api/task/stream/chunk/dlq/ignore
```

Keep existing `/stream/portscan/*` routes as wrappers for backward compatibility.

- [ ] **Step 4: Retry by module**

`Retry` must load the chunk, reset status, and call `streamdispatch.NewProducer().PublishChunks(...)` so SubdomainScan retries go to the SubdomainScan stream.

- [ ] **Step 5: Verify API tests**

Run:

```bash
cd ScopeSentry
go test ./internal/api/handlers/streamtask ./internal/api/routes/task -run 'Summary|DLQ|Retry|Ignore|Register' -v
```

Expected: PASS.

### Task 17: UI Generic Stream Chunk Panel

**Files:**
- Modify: `ScopeSentry-UI/src/api/task/types.ts`
- Modify: `ScopeSentry-UI/src/api/task/index.ts`
- Create: `ScopeSentry-UI/src/views/Task/components/StreamChunkProgress.vue`
- Modify: `ScopeSentry-UI/src/views/Task/components/PortChunkProgress.vue`
- Modify: `ScopeSentry-UI/src/views/Task/components/ProgressInfo.vue`
- Modify: `ScopeSentry-UI/src/locales/zh-CN.ts`
- Modify: `ScopeSentry-UI/src/locales/en.ts`

- [ ] **Step 1: Rename/add generic types**

Add:

```ts
export type StreamChunkStage = 'SubdomainScan' | 'PortScan'

export type StreamChunkSummary = {
  stage: StreamChunkStage
  total: number
  pending: number
  queued: number
  running: number
  success: number
  retrying: number
  dlq: number
  ignored: number
  blocked: boolean
}

export type StreamTaskChunk = {
  id: string
  taskId: string
  taskName: string
  stage: StreamChunkStage
  module: string
  pluginHash: string
  pluginName: string
  targets: string[]
  targetKind?: string
  portRange?: string
  fullPort?: boolean
  timeoutSeconds?: number
  status: string
  node?: string
  streamId?: string
  attempt: number
  maxAttempts: number
  leaseExpiresAt?: string
  createdAt: string
  startedAt?: string
  finishedAt?: string
  error?: string
  ignored: boolean
}
```

Keep aliases:

```ts
export type PortScanChunkSummary = StreamChunkSummary
export type PortScanChunk = StreamTaskChunk
```

- [ ] **Step 2: Add API clients**

Add:

```ts
export const getStreamChunkSummaryApi = (taskId: string, stage: StreamChunkStage) =>
  request.post<IResponse<StreamChunkSummary>>({ url: '/api/task/stream/chunk/summary', data: { taskId, stage } })
```

Add DLQ/retry/ignore variants with `stage`.

- [ ] **Step 3: Build reusable component**

`StreamChunkProgress.vue` props:

```ts
const props = defineProps<{
  taskId: string
  stage: StreamChunkStage
  active: boolean
}>()
```

Behavior:

- Load summary and DLQ chunks in parallel.
- Show stage-specific labels.
- Hide PortRange column when stage is SubdomainScan.
- Show TargetKind / root domain count for SubdomainScan.
- Keep retry and ignore buttons.

- [ ] **Step 4: Wire task progress**

In `ProgressInfo.vue`, show:

```vue
<StreamChunkProgress
  v-if="activeStage === 'SubdomainScan'"
  :task-id="taskId"
  stage="SubdomainScan"
  :active="activeStage === 'SubdomainScan'"
/>
```

Keep PortScan panel with `stage="PortScan"`.

- [ ] **Step 5: Verify UI**

Run:

```bash
cd ScopeSentry-UI
pnpm exec eslint --ext .js,.ts,.vue ./src
pnpm run build:pro
```

Expected: 0 lint errors and successful production build. Existing unrelated warnings may remain.

### Task 18: Smoke Test And Dev Scripts

**Files:**
- Create: `scripts/tests/subdomain_stream_chunk_smoke.sh`
- Modify: `scripts/dev-smoke.sh`
- Modify: `scripts/dev-scan.sh`
- Modify: `scripts/dev-scan-docker.sh`
- Modify: `scripts/dev-scan-docker-compose.yml`
- Modify: `LOCAL_DEV_SETUP.md`

- [ ] **Step 1: Write dry-run chunk math smoke**

The script must support:

```bash
bash scripts/tests/subdomain_stream_chunk_smoke.sh --dry-run
```

Dry-run checks:

```text
3 root domains x 2 plugins = 6 chunks
each chunk has one root domain
maxAttempts = 3
timeoutSeconds = 7200
```

- [ ] **Step 2: Write fake-plugin smoke**

Use deterministic fake SubdomainScan plugin behavior:

```text
example.com + fake-subfinder -> a.example.com, b.example.com
test.com + fake-subfinder -> a.test.com
```

Assertions:

- TargetHandler completes first.
- SubdomainScan chunks are created after TargetHandler.
- PortScan chunks are not created while a SubdomainScan chunk is running.
- After all SubdomainScan chunks succeed, downstream resume receives discovered hosts.
- A forced chunk failure goes DLQ and blocks downstream.
- Ignoring the DLQ chunk allows downstream continuation.

- [ ] **Step 3: Add dev-smoke delegation**

In `scripts/dev-smoke.sh`:

```bash
if [[ "${1:-}" == "--stream-subdomain" ]]; then
  shift
  exec "$ROOT_DIR/scripts/tests/subdomain_stream_chunk_smoke.sh" "$@"
fi
```

- [ ] **Step 4: Add scan env flags**

Expose:

```text
STREAM_SUBDOMAIN_ENABLED
STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS
```

in host and Docker scan dev scripts.

- [ ] **Step 5: Verify scripts**

Run:

```bash
bash -n scripts/tests/subdomain_stream_chunk_smoke.sh scripts/dev-smoke.sh scripts/dev-scan.sh scripts/dev-scan-docker.sh
bash scripts/tests/subdomain_stream_chunk_smoke.sh --dry-run
bash scripts/dev-smoke.sh --stream-subdomain --dry-run
```

Expected: PASS.

### Task 19: End-To-End Verification

**Files:**
- No code files if previous tasks are complete.

- [ ] **Step 1: Server targeted tests**

Run:

```bash
cd ScopeSentry
go test ./internal/models ./internal/database/mongodb ./internal/repositories/streamtask ./internal/repositories/streamstageinput ./internal/services/streamdispatch ./internal/services/task/task ./internal/api/handlers/streamtask ./internal/api/routes/task -run 'StreamTask|StreamStageInput|Subdomain|Continuation|Chunk|Producer|Reaper|DLQ|Dispatcher|Progress|Register|PortScan' -v
```

Expected: PASS.

- [ ] **Step 2: Scanner targeted tests**

Run:

```bash
cd ScopeSentry-Scan
go test ./internal/results ./internal/streamtask ./internal/task ./modules/targethandler ./modules/subdomainscan ./modules/portscan -run 'Subdomain|Stream|Message|Handler|Consumer|Lease|Bypass|Chunk|TargetHandler|PortScan' -v
```

Expected: PASS.

- [ ] **Step 3: UI verification**

Run:

```bash
cd ScopeSentry-UI
pnpm exec eslint --ext .js,.ts,.vue ./src
pnpm run build:pro
```

Expected: PASS.

- [ ] **Step 4: Smoke verification**

Run:

```bash
bash scripts/tests/subdomain_stream_chunk_smoke.sh --dry-run
bash scripts/dev-smoke.sh --stream-subdomain --dry-run
```

Expected: PASS.

- [ ] **Step 5: Diff hygiene**

Run:

```bash
git diff --check
git -C ScopeSentry diff --check
git -C ScopeSentry-Scan diff --check
git -C ScopeSentry-UI diff --check
```

Expected: no output, exit 0.

## Rollout Plan

1. Keep production default as legacy mode.
2. Enable stream SubdomainScan only in local dev.
3. Run fake-plugin smoke.
4. Run one root domain with `subfinder` only.
5. Run three root domains with `subfinder` only.
6. Add `puredns` with a small dictionary and explicit timeout parameter.
7. Enable one remote node.
8. Enable multiple remote nodes.
9. Observe chunk counts, DLQ rate, subdomain de-duplication, runtime events, and downstream PortScan start time.
10. After two stable multi-node runs, consider enabling stream SubdomainScan in the recommended deployment config.

## Operational Notes

- SubdomainScan DLQ blocks downstream stages until the user retries or ignores the failed chunk.
- Ignoring one SubdomainScan chunk means accepting partial SubdomainScan results for that root-domain/plugin pair.
- Retry creates a new stream message and increments attempt.
- Result writes remain at-least-once; existing duplicate checks must stay enabled.
- Per-node same-plugin concurrency is intentionally conservative in v1 because plugin structs are mutable.
- Built-in process-based plugin timeout parameters are set from chunk timeout for `subfinder` and `puredns`. Generic custom plugins may still run until their own process exits; this is documented as a v1 limitation.
- If TargetHandler produces no root domains but has pass-through inputs, SubdomainScan chunks are not created and the server should resume downstream with pass-through inputs.
- If TargetHandler produces root domains but every SubdomainScan plugin fails and all failed chunks are ignored, downstream resumes with pass-through inputs plus any partial subdomain discoveries.

## Failure Modes And Expected Behavior

| Failure | Expected behavior |
|---|---|
| Node dies mid-chunk | Lease expires; reaper retries until max attempts |
| Plugin returns error | Chunk marks failed; reaper retries or DLQs depending attempt count |
| Chunk enters DLQ | Downstream blocked until retry or ignore |
| User ignores DLQ | Chunk terminal; downstream can continue when all chunks terminal |
| Duplicate stream message | Existing result de-duplication prevents duplicated assets |
| TargetHandler emits duplicate root domain | `stream_stage_inputs` unique index deduplicates |
| No SubdomainScan plugins selected | Legacy behavior remains unchanged |
| Stream SubdomainScan disabled | Legacy behavior remains unchanged |
| PortScan stream also enabled | SubdomainScan continuation runs first, then PortScan chunks are planned after downstream reaches PortScan gate |

## Self-Review

- Spec coverage: root-domain/plugin chunking, strict stage order, DLQ blocking with manual ignore, max attempts, timeout default, scanner consumer, UI, tests, and rollout are represented.
- Placeholder scan: this plan intentionally avoids placeholder steps and gives concrete files, functions, commands, and expected results.
- Type consistency: stage/module names use `SubdomainScan` and `PortScan`; chunk status values reuse the existing stream task status constants.
- Risk coverage: mutable plugin state, pass-through target preservation, no dictionary sharding, partial results, and old legacy compatibility are explicitly handled.
