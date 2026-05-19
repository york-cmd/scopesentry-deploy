# Pull + Lease 任务调度(Redis Streams + XCLAIM)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把扫描任务分发模型从 push(中心端推到 `NodeTask:{NodeName}` 节点专属队列)改成 pull(节点按能力订阅 `scan:stream:{module}` 全局流,`XREADGROUP` 抢任务,`XACK` 确认完成,`XCLAIM` 在节点失踪时由 reaper 自动转移)。一举解决"任务被绑死在某节点 → 节点卡了别人接不了"的根本问题,同时拿到任务级 at-least-once 语义、自动死信队列、租约可观测性。

**Architecture:** 每个 module 一条 Redis Stream(`scan:stream:SubdomainScan`、`scan:stream:VulScan` …),每条流配一个 consumer group `scan-workers`。中心端 dispatcher 把原本写到 `NodeTask:{NodeName}` 的任务,改写到对应 module 的 stream;扫描器内部把任务循环改成 `XREADGROUP COUNT=N BLOCK=3000` 的多 stream 订阅(只订阅自己 capabilities 里的 module)。Reaper 服务在中心端跑,定时 `XPENDING` 扫超过租约的 entry,`XCLAIM` 重新分配。Plan 1 的 budget gate 控制 `XREADGROUP` 的 COUNT 参数,实现真正的 backpressure。

**Tech Stack:** Go 1.21+ / `github.com/redis/go-redis/v9`(已有)/ Redis 6.2+(支持 `XAUTOCLAIM`,你的 7.0.11 OK)/ MongoDB(已有)

**前置条件:** Plan 1 + Plan 2 已合并;扫描器侧有 `Budget.Decision()`;节点有 `capabilities` 字段;Redis ACL 已包含 `+xadd +xack +xreadgroup +xpending +xclaim`(Plan 2 Task 3 已加)。

---

## File Structure

### 扫描器 (ScopeSentry-Scan)

| 文件 | 责任 |
|------|------|
| `internal/streamtask/types.go` (新) | TaskMessage 结构、StreamKey 命名约定 |
| `internal/streamtask/consumer.go` (新) | 多 stream `XREADGROUP` 订阅循环 |
| `internal/streamtask/consumer_test.go` (新) | 注入 fake redis,测试拉取逻辑 |
| `internal/streamtask/lease.go` (新) | 自续约 goroutine(`XCLAIM` 自己持有的 entry,刷新 idle time) |
| `internal/streamtask/lease_test.go` (新) | 续约时机测试 |
| `internal/streamtask/handler.go` (新) | TaskMessage → 现有 task.RunPebbleTarget 适配层 |
| `internal/redis/streams.go` (新) | go-redis stream 操作的薄封装(便于 mock) |
| `internal/redis/streams_test.go` (新) | mock redis client 测试 |
| `internal/task/task.go` (改) | `RunRedisTask` 改成 streamtask 启动器(保留 `RunPebbleTarget` 不动) |
| `internal/global/type.go` (改) | Config 加 `TaskMode string`("legacy"|"stream") 切换开关 |
| `cmd/ScopeSentry/main.go` (改) | 根据 TaskMode 启动新或老的循环 |

### 中心端 (ScopeSentry)

| 文件 | 责任 |
|------|------|
| `internal/services/streamdispatch/producer.go` (新) | 写任务到 `scan:stream:{module}` |
| `internal/services/streamdispatch/producer_test.go` (新) | 测试键名、payload schema |
| `internal/services/streamdispatch/reaper.go` (新) | 定时 `XAUTOCLAIM` 把 idle 超时 entry 重分配 |
| `internal/services/streamdispatch/reaper_test.go` (新) | 注入 fake redis 测重分配逻辑 |
| `internal/services/streamdispatch/dlq.go` (新) | 死信队列:多次失败/无人接的 entry 转入 `scan:dlq:{module}` |
| `internal/api/handlers/streamtask/admin.go` (新) | 管理接口:看 stream 长度、PENDING 列表、DLQ 列表、手动重投 |
| `internal/api/routes/routes.go` (改) | 注册管理路由 |
| `internal/services/dispatch/dispatch.go` (改) | 现有 dispatcher 改成调用 streamdispatch.Producer 而非写 NodeTask:* list |

### 前端 (ScopeSentry-UI)

| 文件 | 责任 |
|------|------|
| `src/views/Node/components/StreamMonitor.vue` (新) | 节点详情页加"流积压"图表 + DLQ 列表 |
| `src/api/streamtask/index.ts` (新) | 调 admin 接口的 client |

---

## Stream Key Schema(先固化好,所有 task 都基于这个)

```
scan:stream:{Module}                  → 主流(每 module 一条)
scan:stream:{Module}:dlq             → 死信流(N 次重试失败转此处)
scan:group:scan-workers              → 唯一 consumer group 名,所有 module 共用
                                      (group 名在 stream 上是局部的,所以重名不冲突)
scan:lease:{node}:{taskId}           → 节点持有的任务清单(value 是 messageId,
                                      reaper 用来快速清单化某个节点的 in-flight)
                                      (可选;XPENDING 也可以查,留作冗余索引)
```

**Consumer name** = `NodeName`(每节点对自己 stream 的 consumer 唯一身份)。

**Task message fields(stream entry 的 fields):**
```
id        UUID(应用层)
module    str (如 "SubdomainScan")
target    JSON of full TaskOptions (兼容现有 options.TaskOptions schema)
ts        创建时间戳(纳秒)
attempt   int(每次 XCLAIM 后 +1)
```

---

## Task 1: Stream Schema 类型定义

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/types.go`

- [ ] **Step 1.1: 写 types.go**

```go
// Package streamtask is the pull-mode task consumer for the scanner.
// It replaces the old "NodeTask:{NodeName}" Redis-list consumer in
// internal/task/task.go::RunRedisTask. Tasks are now organized as
// per-module Redis Streams; nodes only consume streams matching their
// declared capabilities, and the lease/XCLAIM machinery ensures tasks
// don't get stuck on a dead node.
package streamtask

import (
	"fmt"
	"strconv"
	"time"
)

// ConsumerGroup is the single group name used across all module streams.
// Group names are local to each stream so reuse is safe.
const ConsumerGroup = "scan-workers"

// StreamKey returns the Redis key for a module's primary task stream.
func StreamKey(module string) string {
	return "scan:stream:" + module
}

// DLQKey returns the dead-letter stream key for a module.
func DLQKey(module string) string {
	return "scan:stream:" + module + ":dlq"
}

// LeaseKey is a per-node hash that tracks which message IDs the node
// currently owns. Optional secondary index; XPENDING is authoritative.
func LeaseKey(node string) string {
	return "scan:lease:" + node
}

// TaskMessage is the wire shape of a task in a Redis stream entry.
// Field names are the actual Redis stream field names. `target` is JSON.
type TaskMessage struct {
	ID      string // application-level UUID, matches options.TaskOptions.ID
	Module  string
	Target  string // JSON-encoded TaskOptions
	TS      time.Time
	Attempt int
}

// ToFields renders for XADD.
func (m TaskMessage) ToFields() map[string]any {
	return map[string]any{
		"id":      m.ID,
		"module":  m.Module,
		"target":  m.Target,
		"ts":      strconv.FormatInt(m.TS.UnixNano(), 10),
		"attempt": strconv.Itoa(m.Attempt),
	}
}

// ParseTaskMessage rebuilds from XREADGROUP fields.
func ParseTaskMessage(fields map[string]any) (TaskMessage, error) {
	get := func(k string) (string, error) {
		v, ok := fields[k]
		if !ok {
			return "", fmt.Errorf("missing field %q", k)
		}
		s, ok := v.(string)
		if !ok {
			return "", fmt.Errorf("field %q not a string", k)
		}
		return s, nil
	}
	id, err := get("id")
	if err != nil {
		return TaskMessage{}, err
	}
	module, err := get("module")
	if err != nil {
		return TaskMessage{}, err
	}
	target, err := get("target")
	if err != nil {
		return TaskMessage{}, err
	}
	tsStr, _ := get("ts")
	atStr, _ := get("attempt")
	tsNs, _ := strconv.ParseInt(tsStr, 10, 64)
	at, _ := strconv.Atoi(atStr)

	return TaskMessage{
		ID:      id,
		Module:  module,
		Target:  target,
		TS:      time.Unix(0, tsNs),
		Attempt: at,
	}, nil
}

// MaxAttempts is the retry ceiling before a task is moved to DLQ.
// Each XCLAIM by the reaper increments attempt; the reaper checks this
// before re-queueing.
const MaxAttempts = 3

// LeaseDuration is how long an in-flight entry can be idle before the
// reaper considers it abandoned. Should be > slowest realistic plugin.
// Conservative default: 5 minutes. Override via env REAPER_LEASE_SEC.
const DefaultLeaseDuration = 5 * time.Minute

// LeaseRefreshInterval is how often the consumer refreshes its lease via
// self-XCLAIM. Must be < LeaseDuration / 2.
const DefaultLeaseRefreshInterval = 90 * time.Second
```

- [ ] **Step 1.2: 编译**

```bash
cd ScopeSentry-Scan && go build ./internal/streamtask/
```

- [ ] **Step 1.3: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/types.go
git commit -m "feat(streamtask): stream schema and message types"
```

---

## Task 2: go-redis Stream 操作薄封装

**Files:**
- Create: `ScopeSentry-Scan/internal/redis/streams.go`
- Create: `ScopeSentry-Scan/internal/redis/streams_test.go`

go-redis 的 stream API 已经很 ergonomic,这层只做接口适配 + 错误处理。

- [ ] **Step 2.1: 写测试(用 miniredis)**

先确认 miniredis 是否已经在 go.mod;如果没有:

```bash
cd ScopeSentry-Scan && go get github.com/alicebob/miniredis/v2
```

```go
// internal/redis/streams_test.go
package redis

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newMiniClient(t *testing.T) (*redis.Client, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	c := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	return c, mr
}

func TestStreamAdd_AndRead(t *testing.T) {
	c, _ := newMiniClient(t)
	defer c.Close()
	s := NewStreamOps(c)

	ctx := context.Background()
	id, err := s.Add(ctx, "scan:stream:Foo", map[string]any{"k": "v"})
	if err != nil {
		t.Fatal(err)
	}
	if id == "" {
		t.Error("empty id from XADD")
	}

	if err := s.EnsureGroup(ctx, "scan:stream:Foo", "scan-workers"); err != nil {
		t.Fatal(err)
	}

	msgs, err := s.ReadGroup(ctx, ReadGroupOpts{
		Streams:  []string{"scan:stream:Foo"},
		Group:    "scan-workers",
		Consumer: "consumer-A",
		Count:    10,
		Block:    100 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].Stream != "scan:stream:Foo" {
		t.Fatalf("got %+v", msgs)
	}
	if msgs[0].Messages[0].Values["k"] != "v" {
		t.Errorf("payload mismatch")
	}

	if err := s.Ack(ctx, "scan:stream:Foo", "scan-workers", msgs[0].Messages[0].ID); err != nil {
		t.Errorf("ack: %v", err)
	}
}

func TestStreamReadGroup_BlockReturnsEmptyOnTimeout(t *testing.T) {
	c, _ := newMiniClient(t)
	defer c.Close()
	s := NewStreamOps(c)
	ctx := context.Background()

	_ = s.EnsureGroup(ctx, "scan:stream:Empty", "scan-workers")
	msgs, err := s.ReadGroup(ctx, ReadGroupOpts{
		Streams: []string{"scan:stream:Empty"},
		Group: "scan-workers", Consumer: "c1",
		Count: 5, Block: 50 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("expected 0 stream results, got %d", len(msgs))
	}
}

func TestStreamPending_ListsInflight(t *testing.T) {
	c, _ := newMiniClient(t)
	defer c.Close()
	s := NewStreamOps(c)
	ctx := context.Background()

	s.Add(ctx, "scan:stream:Foo", map[string]any{"k": "v"})
	s.EnsureGroup(ctx, "scan:stream:Foo", "scan-workers")
	msgs, _ := s.ReadGroup(ctx, ReadGroupOpts{
		Streams: []string{"scan:stream:Foo"}, Group: "scan-workers",
		Consumer: "c1", Count: 1, Block: 100 * time.Millisecond,
	})
	if len(msgs) == 0 {
		t.Fatal("setup: no msg")
	}

	pending, err := s.Pending(ctx, "scan:stream:Foo", "scan-workers", 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 || pending[0].Consumer != "c1" {
		t.Errorf("pending=%+v", pending)
	}
}
```

- [ ] **Step 2.2: 跑测试,确认失败**

```bash
go test ./internal/redis/ -run Stream -v
```

- [ ] **Step 2.3: 写实现**

```go
// internal/redis/streams.go
package redis

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// StreamOps wraps go-redis stream commands. Behind an interface so
// tests can substitute miniredis or a fake.
type StreamOps struct {
	c *redis.Client
}

func NewStreamOps(c *redis.Client) *StreamOps { return &StreamOps{c: c} }

func (s *StreamOps) Add(ctx context.Context, stream string, fields map[string]any) (string, error) {
	return s.c.XAdd(ctx, &redis.XAddArgs{
		Stream: stream,
		Values: fields,
	}).Result()
}

// EnsureGroup creates the consumer group if absent. MKSTREAM creates the
// stream too if it doesn't exist yet (avoids the chicken/egg of "create
// group on stream that has no entries").
func (s *StreamOps) EnsureGroup(ctx context.Context, stream, group string) error {
	err := s.c.XGroupCreateMkStream(ctx, stream, group, "$").Err()
	if err != nil && !strings.Contains(err.Error(), "BUSYGROUP") {
		return err
	}
	return nil
}

type ReadGroupOpts struct {
	Streams  []string
	Group    string
	Consumer string
	Count    int64
	Block    time.Duration
}

// ReadGroup blocks for up to opts.Block waiting for new entries on any of
// the listed streams. ID ">" means "messages never delivered to this consumer".
func (s *StreamOps) ReadGroup(ctx context.Context, opts ReadGroupOpts) ([]redis.XStream, error) {
	streamArgs := make([]string, 0, len(opts.Streams)*2)
	streamArgs = append(streamArgs, opts.Streams...)
	for range opts.Streams {
		streamArgs = append(streamArgs, ">")
	}
	res, err := s.c.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    opts.Group,
		Consumer: opts.Consumer,
		Streams:  streamArgs,
		Count:    opts.Count,
		Block:    opts.Block,
	}).Result()
	if errors.Is(err, redis.Nil) {
		return nil, nil // timeout, no messages
	}
	return res, err
}

func (s *StreamOps) Ack(ctx context.Context, stream, group string, ids ...string) error {
	if len(ids) == 0 {
		return nil
	}
	return s.c.XAck(ctx, stream, group, ids...).Err()
}

// PendingEntry mirrors a row of XPENDING.
type PendingEntry struct {
	ID         string
	Consumer   string
	IdleMs     int64
	Deliveries int64
}

// Pending returns up to `count` pending entries for the group on the stream.
func (s *StreamOps) Pending(ctx context.Context, stream, group string, count int64) ([]PendingEntry, error) {
	res, err := s.c.XPendingExt(ctx, &redis.XPendingExtArgs{
		Stream: stream,
		Group:  group,
		Start:  "-",
		End:    "+",
		Count:  count,
	}).Result()
	if err != nil {
		return nil, err
	}
	out := make([]PendingEntry, 0, len(res))
	for _, r := range res {
		out = append(out, PendingEntry{
			ID:         r.ID,
			Consumer:   r.Consumer,
			IdleMs:     r.Idle.Milliseconds(),
			Deliveries: r.RetryCount,
		})
	}
	return out, nil
}

// AutoClaim atomically claims pending entries idle for at least minIdle.
// Returns the new owner's claimed messages plus the next cursor for paging.
func (s *StreamOps) AutoClaim(ctx context.Context, stream, group, consumer string, minIdle time.Duration, start string, count int64) ([]redis.XMessage, string, error) {
	res, next, err := s.c.XAutoClaim(ctx, &redis.XAutoClaimArgs{
		Stream:   stream,
		Group:    group,
		Consumer: consumer,
		MinIdle:  minIdle,
		Start:    start,
		Count:    count,
	}).Result()
	return res, next, err
}

// Claim is the explicit, single-message version (used by self-refresh).
func (s *StreamOps) Claim(ctx context.Context, stream, group, consumer string, minIdle time.Duration, ids ...string) ([]redis.XMessage, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	return s.c.XClaim(ctx, &redis.XClaimArgs{
		Stream:   stream,
		Group:    group,
		Consumer: consumer,
		MinIdle:  minIdle,
		Messages: ids,
	}).Result()
}

// Len returns stream length (for monitoring).
func (s *StreamOps) Len(ctx context.Context, stream string) (int64, error) {
	return s.c.XLen(ctx, stream).Result()
}
```

- [ ] **Step 2.4: 跑测试,确认通过**

```bash
go test ./internal/redis/ -run Stream -v -timeout 30s
```

Expected: 3 PASS。

- [ ] **Step 2.5: Commit**

```bash
git add ScopeSentry-Scan/internal/redis/streams.go \
        ScopeSentry-Scan/internal/redis/streams_test.go \
        ScopeSentry-Scan/go.mod ScopeSentry-Scan/go.sum
git commit -m "feat(redis): add stream operation wrapper with miniredis tests"
```

---

## Task 3: Consumer (XREADGROUP 循环)

这是 plan 的核心。

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/consumer.go`
- Create: `ScopeSentry-Scan/internal/streamtask/consumer_test.go`

- [ ] **Step 3.1: 写测试**

```go
// internal/streamtask/consumer_test.go
package streamtask

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	scanredis "github.com/Autumn-27/ScopeSentry-Scan/internal/redis"
)

func newOps(t *testing.T) (*scanredis.StreamOps, *redis.Client) {
	mr := miniredis.RunT(t)
	c := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	return scanredis.NewStreamOps(c), c
}

// fakeBudget always returns the configured Decision.
type fakeBudget struct {
	state string
	conc  int
}

func (b *fakeBudget) Decision() (state string, maxConcurrency int) {
	return b.state, b.conc
}

// fakeRunner records dispatched messages.
type fakeRunner struct {
	calls atomic.Int64
	stub  func(TaskMessage) error
}

func (r *fakeRunner) Run(_ context.Context, m TaskMessage) error {
	r.calls.Add(1)
	if r.stub != nil {
		return r.stub(m)
	}
	return nil
}

func TestConsumer_PullsAndAcksOnSuccess(t *testing.T) {
	ops, _ := newOps(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	bg := &fakeBudget{state: "open", conc: 4}
	rn := &fakeRunner{}
	cons := NewConsumer(ConsumerOpts{
		NodeName:     "test-node",
		Capabilities: []string{"SubdomainScan"},
		Streams:      ops,
		Budget:       bg,
		Runner:       rn,
		BlockTimeout: 100 * time.Millisecond,
	})

	// Pre-seed a task on the stream
	ops.EnsureGroup(ctx, StreamKey("SubdomainScan"), ConsumerGroup)
	tm := TaskMessage{
		ID: "tid-1", Module: "SubdomainScan",
		Target: `{"id":"tid-1","domain":"example.com"}`,
		TS: time.Now(),
	}
	_, err := ops.Add(ctx, StreamKey("SubdomainScan"), tm.ToFields())
	if err != nil {
		t.Fatal(err)
	}

	go cons.Run(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	cons.Wait()

	if rn.calls.Load() != 1 {
		t.Errorf("runner called %d times, want 1", rn.calls.Load())
	}
	pending, _ := ops.Pending(ctx, StreamKey("SubdomainScan"), ConsumerGroup, 10)
	if len(pending) != 0 {
		t.Errorf("pending=%v, expected 0 after ack", pending)
	}
}

func TestConsumer_DoesNotAckOnHandlerError(t *testing.T) {
	ops, _ := newOps(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	bg := &fakeBudget{state: "open", conc: 4}
	rn := &fakeRunner{stub: func(_ TaskMessage) error { return errors.New("plugin failure") }}
	cons := NewConsumer(ConsumerOpts{
		NodeName:     "test-node",
		Capabilities: []string{"SubdomainScan"},
		Streams:      ops,
		Budget:       bg,
		Runner:       rn,
		BlockTimeout: 100 * time.Millisecond,
	})

	ops.EnsureGroup(ctx, StreamKey("SubdomainScan"), ConsumerGroup)
	ops.Add(ctx, StreamKey("SubdomainScan"), TaskMessage{
		ID: "tid-1", Module: "SubdomainScan", Target: `{"id":"tid-1"}`, TS: time.Now(),
	}.ToFields())

	go cons.Run(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	cons.Wait()

	pending, _ := ops.Pending(ctx, StreamKey("SubdomainScan"), ConsumerGroup, 10)
	if len(pending) != 1 {
		t.Errorf("pending=%d, expected 1 (entry must remain unacked on failure)", len(pending))
	}
}

func TestConsumer_BudgetPaused_DoesNotPull(t *testing.T) {
	ops, _ := newOps(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	bg := &fakeBudget{state: "paused", conc: 0}
	rn := &fakeRunner{}
	cons := NewConsumer(ConsumerOpts{
		NodeName:     "test-node",
		Capabilities: []string{"SubdomainScan"},
		Streams:      ops,
		Budget:       bg,
		Runner:       rn,
		BlockTimeout: 100 * time.Millisecond,
	})
	ops.EnsureGroup(ctx, StreamKey("SubdomainScan"), ConsumerGroup)
	ops.Add(ctx, StreamKey("SubdomainScan"), TaskMessage{ID: "x", Module: "SubdomainScan", Target: "{}"}.ToFields())

	go cons.Run(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	cons.Wait()

	if rn.calls.Load() != 0 {
		t.Errorf("budget paused: runner called %d times, want 0", rn.calls.Load())
	}
}

func TestConsumer_OnlySubscribesToCapabilities(t *testing.T) {
	ops, _ := newOps(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	bg := &fakeBudget{state: "open", conc: 4}
	rn := &fakeRunner{}
	cons := NewConsumer(ConsumerOpts{
		NodeName:     "test-node",
		Capabilities: []string{"SubdomainScan"}, // only subdomain
		Streams:      ops,
		Budget:       bg,
		Runner:       rn,
		BlockTimeout: 100 * time.Millisecond,
	})

	// Seed a VulScan task — node should NOT pick it up
	ops.EnsureGroup(ctx, StreamKey("VulScan"), ConsumerGroup)
	ops.Add(ctx, StreamKey("VulScan"), TaskMessage{ID: "v1", Module: "VulScan", Target: "{}"}.ToFields())

	// Seed a SubdomainScan task — node SHOULD pick it up
	ops.EnsureGroup(ctx, StreamKey("SubdomainScan"), ConsumerGroup)
	ops.Add(ctx, StreamKey("SubdomainScan"), TaskMessage{ID: "s1", Module: "SubdomainScan", Target: "{}"}.ToFields())

	go cons.Run(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	cons.Wait()

	if rn.calls.Load() != 1 {
		t.Errorf("calls=%d, want exactly 1 (VulScan should be skipped)", rn.calls.Load())
	}
}
```

- [ ] **Step 3.2: 跑测试,确认失败**

```bash
go test ./internal/streamtask/ -run Consumer -v
```

- [ ] **Step 3.3: 写实现**

```go
// internal/streamtask/consumer.go
package streamtask

import (
	"context"
	"sync"
	"time"

	"github.com/Autumn-27/ScopeSentry-Scan/internal/redis"
	"github.com/Autumn-27/ScopeSentry-Scan/pkg/logger"
)

// budgetSource is the read view consumer needs from Plan 1's Budget.
// Avoid importing the budget package directly to keep streamtask import
// graph clean. main wires this up.
type budgetSource interface {
	Decision() (state string, maxConcurrency int)
}

// Runner is what the consumer calls when it gets a task.
// In production this dispatches to internal/runner; tests pass a fake.
type Runner interface {
	Run(ctx context.Context, msg TaskMessage) error
}

type ConsumerOpts struct {
	NodeName     string   // becomes the XREADGROUP consumer name
	Capabilities []string // module names to subscribe to
	Streams      *redis.StreamOps
	Budget       budgetSource
	Runner       Runner
	BlockTimeout time.Duration // default 3s
}

type Consumer struct {
	opts ConsumerOpts
	wg   sync.WaitGroup
}

func NewConsumer(opts ConsumerOpts) *Consumer {
	if opts.BlockTimeout <= 0 {
		opts.BlockTimeout = 3 * time.Second
	}
	return &Consumer{opts: opts}
}

// Run blocks until ctx is cancelled. Spawns one outer loop; concurrency
// is controlled by the Count parameter (capped by budget.MaxConcurrency).
// In-flight task processing happens on goroutines spawned per message,
// bounded by a semaphore reflecting the current decision.
func (c *Consumer) Run(parent context.Context) {
	c.wg.Add(1)
	defer c.wg.Done()

	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	// Ensure groups exist on every stream we care about.
	for _, mod := range c.opts.Capabilities {
		_ = c.opts.Streams.EnsureGroup(ctx, StreamKey(mod), ConsumerGroup)
	}

	streams := make([]string, 0, len(c.opts.Capabilities))
	for _, m := range c.opts.Capabilities {
		streams = append(streams, StreamKey(m))
	}

	// per-task semaphore — bounded by current decision.MaxConcurrency
	sem := newDynSemaphore(1)

	for {
		select {
		case <-ctx.Done():
			c.wg.Wait()
			return
		default:
		}

		state, conc := c.opts.Budget.Decision()
		if conc <= 0 || state == "paused" || state == "emergency_cooldown" {
			// Sleep for budget eval interval to avoid busy loop.
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
			}
			continue
		}
		sem.resize(conc)

		// Don't ask for more than the semaphore can hold.
		count := int64(sem.available())
		if count <= 0 {
			// All slots full; wait for one to free.
			select {
			case <-ctx.Done():
				return
			case <-time.After(500 * time.Millisecond):
			}
			continue
		}

		results, err := c.opts.Streams.ReadGroup(ctx, redis.ReadGroupOpts{
			Streams:  streams,
			Group:    ConsumerGroup,
			Consumer: c.opts.NodeName,
			Count:    count,
			Block:    c.opts.BlockTimeout,
		})
		if err != nil && ctx.Err() == nil {
			logger.SlogErrorLocal("XReadGroup error: " + err.Error())
			time.Sleep(time.Second) // backoff
			continue
		}

		for _, sr := range results {
			for _, m := range sr.Messages {
				values := stringMap(m.Values)
				task, err := ParseTaskMessage(values)
				if err != nil {
					// Bad shape; ack to drop. Real prod would ship to DLQ.
					_ = c.opts.Streams.Ack(ctx, sr.Stream, ConsumerGroup, m.ID)
					logger.SlogErrorLocal("malformed task: " + err.Error())
					continue
				}
				sem.acquire()
				c.wg.Add(1)
				go func(streamKey, msgID string, t TaskMessage) {
					defer c.wg.Done()
					defer sem.release()
					if err := c.opts.Runner.Run(ctx, t); err != nil {
						// Don't ack; reaper will reclaim if idle long enough.
						logger.SlogErrorLocal("task " + t.ID + " failed: " + err.Error())
						return
					}
					if err := c.opts.Streams.Ack(ctx, streamKey, ConsumerGroup, msgID); err != nil {
						logger.SlogErrorLocal("ack failed: " + err.Error())
					}
				}(sr.Stream, m.ID, task)
			}
		}
	}
}

// Wait blocks until the run loop and all in-flight task goroutines finish.
func (c *Consumer) Wait() { c.wg.Wait() }

// stringMap coerces redis library's map[string]any (always strings in stream
// fields) into a more ergonomic shape for ParseTaskMessage.
func stringMap(in map[string]any) map[string]any {
	// already string-valued; provided as a future hook if shape changes
	return in
}
```

- [ ] **Step 3.4: 写动态信号量**

新建 `internal/streamtask/dyn_sem.go`:

```go
package streamtask

import "sync"

// dynSemaphore is a counting semaphore whose capacity can be resized at runtime.
// On shrink, currently-acquired permits are not revoked; new acquires block
// until the in-flight count drops below the new capacity.
type dynSemaphore struct {
	mu       sync.Mutex
	cond     *sync.Cond
	capacity int
	inUse    int
}

func newDynSemaphore(cap int) *dynSemaphore {
	s := &dynSemaphore{capacity: cap}
	s.cond = sync.NewCond(&s.mu)
	return s
}

func (s *dynSemaphore) resize(newCap int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if newCap < 0 {
		newCap = 0
	}
	s.capacity = newCap
	s.cond.Broadcast() // wake possibly-waiting acquires
}

func (s *dynSemaphore) acquire() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for s.inUse >= s.capacity {
		s.cond.Wait()
	}
	s.inUse++
}

func (s *dynSemaphore) release() {
	s.mu.Lock()
	s.inUse--
	s.cond.Signal()
	s.mu.Unlock()
}

func (s *dynSemaphore) available() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.capacity - s.inUse
	if a < 0 {
		a = 0
	}
	return a
}
```

- [ ] **Step 3.5: 跑测试**

```bash
go test ./internal/streamtask/ -run Consumer -v -timeout 30s
```

Expected: 4 PASS。

- [ ] **Step 3.6: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/consumer.go \
        ScopeSentry-Scan/internal/streamtask/consumer_test.go \
        ScopeSentry-Scan/internal/streamtask/dyn_sem.go
git commit -m "feat(streamtask): consumer with capability + budget gating"
```

---

## Task 4: Lease 自续约 goroutine

防止任务跑到一半被 reaper 误判超时。consumer 持有的 entry 需要每隔 N 秒 `XCLAIM` 自己一次刷新 idle time。

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/lease.go`
- Create: `ScopeSentry-Scan/internal/streamtask/lease_test.go`

- [ ] **Step 4.1: 写测试**

```go
package streamtask

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	scanredis "github.com/Autumn-27/ScopeSentry-Scan/internal/redis"
)

func TestLeaseRenewer_RefreshesPendingIdle(t *testing.T) {
	mr := miniredis.RunT(t)
	c := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer c.Close()
	ops := scanredis.NewStreamOps(c)
	ctx := context.Background()

	stream := StreamKey("SubdomainScan")
	ops.EnsureGroup(ctx, stream, ConsumerGroup)
	ops.Add(ctx, stream, TaskMessage{ID: "x", Module: "SubdomainScan", Target: "{}"}.ToFields())
	msgs, _ := ops.ReadGroup(ctx, scanredis.ReadGroupOpts{
		Streams: []string{stream}, Group: ConsumerGroup, Consumer: "node-A",
		Count: 1, Block: 100 * time.Millisecond,
	})
	if len(msgs) == 0 || len(msgs[0].Messages) == 0 {
		t.Fatal("no msg")
	}

	// fast-forward miniredis 200ms (pretend the entry has been idle for that long)
	mr.FastForward(200 * time.Millisecond)
	pending, _ := ops.Pending(ctx, stream, ConsumerGroup, 10)
	if pending[0].IdleMs < 100 {
		t.Fatalf("setup: idle=%dms", pending[0].IdleMs)
	}
	idleBefore := pending[0].IdleMs

	r := NewLeaseRenewer(ops, "node-A", []string{"SubdomainScan"}, 10*time.Millisecond)
	rctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(rctx)
	time.Sleep(50 * time.Millisecond)
	cancel()

	pendingAfter, _ := ops.Pending(ctx, stream, ConsumerGroup, 10)
	if len(pendingAfter) != 1 {
		t.Fatalf("lost pending: %v", pendingAfter)
	}
	if pendingAfter[0].IdleMs >= idleBefore {
		t.Errorf("idle did not refresh: before=%d after=%d", idleBefore, pendingAfter[0].IdleMs)
	}
}
```

- [ ] **Step 4.2: 写实现**

```go
// internal/streamtask/lease.go
package streamtask

import (
	"context"
	"time"

	"github.com/Autumn-27/ScopeSentry-Scan/internal/redis"
	"github.com/Autumn-27/ScopeSentry-Scan/pkg/logger"
)

// LeaseRenewer periodically XCLAIMs entries owned by this node to refresh
// their idle timer, so the reaper doesn't reclaim work that's still in
// progress on long-running plugins.
//
// XCLAIM with min_idle=0 + same consumer is the cheapest way to "touch"
// pending entries; it just resets idle time to zero.
type LeaseRenewer struct {
	ops      *redis.StreamOps
	node     string
	modules  []string
	interval time.Duration
}

func NewLeaseRenewer(ops *redis.StreamOps, node string, modules []string, interval time.Duration) *LeaseRenewer {
	if interval <= 0 {
		interval = DefaultLeaseRefreshInterval
	}
	return &LeaseRenewer{ops: ops, node: node, modules: modules, interval: interval}
}

func (r *LeaseRenewer) Run(ctx context.Context) {
	t := time.NewTicker(r.interval)
	defer t.Stop()

	refresh := func() {
		for _, mod := range r.modules {
			stream := StreamKey(mod)
			pending, err := r.ops.Pending(ctx, stream, ConsumerGroup, 256)
			if err != nil {
				continue
			}
			ids := make([]string, 0, len(pending))
			for _, p := range pending {
				if p.Consumer == r.node {
					ids = append(ids, p.ID)
				}
			}
			if len(ids) == 0 {
				continue
			}
			// XCLAIM with MinIdle=0 + same consumer = touch (reset idle to 0)
			if _, err := r.ops.Claim(ctx, stream, ConsumerGroup, r.node, 0, ids...); err != nil {
				logger.SlogErrorLocal("lease refresh: " + err.Error())
			}
		}
	}

	refresh() // immediate
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			refresh()
		}
	}
}
```

- [ ] **Step 4.3: 跑测试**

```bash
go test ./internal/streamtask/ -run Lease -v
```

Expected: PASS。

- [ ] **Step 4.4: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/lease.go \
        ScopeSentry-Scan/internal/streamtask/lease_test.go
git commit -m "feat(streamtask): lease renewer for in-flight tasks"
```

---

## Task 5: Handler 适配层(把 TaskMessage 喂给现有 RunPebbleTarget)

**Files:**
- Create: `ScopeSentry-Scan/internal/streamtask/handler.go`

- [ ] **Step 5.1: 写适配 Runner**

```go
// internal/streamtask/handler.go
package streamtask

import (
	"context"
	"encoding/json"

	"github.com/Autumn-27/ScopeSentry-Scan/internal/contextmanager"
	"github.com/Autumn-27/ScopeSentry-Scan/internal/options"
	"github.com/Autumn-27/ScopeSentry-Scan/internal/task"
)

// PebbleTargetRunner adapts a stream TaskMessage into the existing
// task.RunPebbleTarget pipeline. Reusing the existing runner means we
// don't have to change any plugin code — only the dispatch surface.
type PebbleTargetRunner struct{}

func NewPebbleTargetRunner() *PebbleTargetRunner { return &PebbleTargetRunner{} }

func (r *PebbleTargetRunner) Run(_ context.Context, m TaskMessage) error {
	var opt options.TaskOptions
	if err := json.Unmarshal([]byte(m.Target), &opt); err != nil {
		return err
	}
	contextmanager.GlobalContextManagers.AddContext(opt.ID)
	task.RunPebbleTarget(opt)
	return nil
}
```

⚠️ `task.RunPebbleTarget` 是现有函数(看 `internal/task/task.go`)。如果它不存在或签名不同,改适配层。**绝对不要在此 task 里改 RunPebbleTarget 自身**——保持向后兼容是这次重构的核心原则。

- [ ] **Step 5.2: 编译**

```bash
go build ./internal/streamtask/
```

- [ ] **Step 5.3: Commit**

```bash
git add ScopeSentry-Scan/internal/streamtask/handler.go
git commit -m "feat(streamtask): pebble target runner adapter"
```

---

## Task 6: 扫描器入口切换(双模式开关)

**Files:**
- Modify: `ScopeSentry-Scan/internal/global/type.go`
- Modify: `ScopeSentry-Scan/internal/config/config.go`
- Modify: `ScopeSentry-Scan/cmd/ScopeSentry/main.go`
- Modify: `ScopeSentry-Scan/internal/task/task.go`(老入口保留)

- [ ] **Step 6.1: 加 TaskMode 字段**

`internal/global/type.go`:

```go
type Config struct {
	// ... existing ...
	Capabilities []string `yaml:"capabilities"`
	TaskMode     string   `yaml:"taskMode"` // "legacy" | "stream"; default "legacy"
}
```

`internal/config/config.go::LoadConfig` env 分支:

```go
		TaskMode: getEnv("TASK_MODE", "legacy"),
```

- [ ] **Step 6.2: main.go 根据 TaskMode 选启动**

修改 `cmd/ScopeSentry/main.go` 第 134 行附近的 task 启动 goroutine,改为:

```go
	wg.Add(1)
	go func() {
		defer wg.Done()
		switch global.AppConfig.TaskMode {
		case "stream":
			runStreamTaskLoop(budgetCtx)
		default:
			for {
				task.GetTask()
			}
		}
	}()
```

并在文件末尾加:

```go
func runStreamTaskLoop(ctx context.Context) {
	streamOps := redis.NewStreamOps(redis.RedisClient.Client())
	cons := streamtask.NewConsumer(streamtask.ConsumerOpts{
		NodeName:     global.AppConfig.NodeName,
		Capabilities: global.AppConfig.Capabilities,
		Streams:      streamOps,
		Budget:       budgetAdapter{},
		Runner:       streamtask.NewPebbleTargetRunner(),
		BlockTimeout: 3 * time.Second,
	})

	renewer := streamtask.NewLeaseRenewer(
		streamOps, global.AppConfig.NodeName,
		global.AppConfig.Capabilities, streamtask.DefaultLeaseRefreshInterval,
	)
	go renewer.Run(ctx)

	cons.Run(ctx)
}

// budgetAdapter bridges Plan 1's node.CurrentBudget to streamtask.budgetSource.
type budgetAdapter struct{}

func (budgetAdapter) Decision() (string, int) {
	if node.CurrentBudget == nil {
		return "open", 8
	}
	d := node.CurrentBudget.Decision()
	return d.State.String(), d.MaxConcurrency
}
```

import 加 `streamtask`、`redis`(scan internal redis 包)。注意 `redis.RedisClient.Client()` 返回底层 `*redis.Client`(确认 facade 有这个方法,如果没有,在 redis facade 加一个 `func (c *Client) Client() *redis.Client { return c.client }`)。

- [ ] **Step 6.3: 编译**

```bash
go build ./...
```

确保 import cycle、缺失符号等都解决。

- [ ] **Step 6.4: Commit**

```bash
git add ScopeSentry-Scan/cmd/ScopeSentry/main.go \
        ScopeSentry-Scan/internal/global/type.go \
        ScopeSentry-Scan/internal/config/config.go \
        ScopeSentry-Scan/internal/redis/redis.go
git commit -m "feat(streamtask): wire stream consumer behind TASK_MODE switch"
```

---

## Task 7: 中心端 Producer(写任务到 Stream)

**Files:**
- Create: `ScopeSentry/internal/services/streamdispatch/producer.go`
- Create: `ScopeSentry/internal/services/streamdispatch/producer_test.go`

- [ ] **Step 7.1: 写测试**

```go
// internal/services/streamdispatch/producer_test.go
package streamdispatch

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newClient(t *testing.T) *redis.Client {
	mr := miniredis.RunT(t)
	return redis.NewClient(&redis.Options{Addr: mr.Addr()})
}

func TestProducer_PublishesToCorrectStream(t *testing.T) {
	c := newClient(t)
	defer c.Close()
	p := NewProducer(c)

	id, err := p.Publish(context.Background(), TaskInput{
		ID:     "task-1",
		Module: "SubdomainScan",
		TargetJSON: `{"id":"task-1"}`,
	})
	if err != nil {
		t.Fatal(err)
	}
	if id == "" {
		t.Error("empty id")
	}

	n, _ := c.XLen(context.Background(), "scan:stream:SubdomainScan").Result()
	if n != 1 {
		t.Errorf("stream len=%d want 1", n)
	}
	if other, _ := c.XLen(context.Background(), "scan:stream:VulScan").Result(); other != 0 {
		t.Errorf("VulScan stream contaminated")
	}
}

func TestProducer_FieldsMatchScannerSchema(t *testing.T) {
	c := newClient(t)
	defer c.Close()
	p := NewProducer(c)

	_, err := p.Publish(context.Background(), TaskInput{
		ID: "t1", Module: "PortScan", TargetJSON: "{}",
	})
	if err != nil {
		t.Fatal(err)
	}
	res, _ := c.XRange(context.Background(), "scan:stream:PortScan", "-", "+").Result()
	if len(res) != 1 {
		t.Fatalf("range=%d", len(res))
	}
	v := res[0].Values
	for _, k := range []string{"id", "module", "target", "ts", "attempt"} {
		if _, ok := v[k]; !ok {
			t.Errorf("missing field %q (scanner won't parse)", k)
		}
	}
	if v["module"] != "PortScan" || v["id"] != "t1" {
		t.Errorf("wrong field values: %+v", v)
	}
}

func TestProducer_PublishMany(t *testing.T) {
	c := newClient(t)
	defer c.Close()
	p := NewProducer(c)

	tasks := []TaskInput{
		{ID: "a", Module: "PortScan", TargetJSON: "{}"},
		{ID: "b", Module: "PortScan", TargetJSON: "{}"},
		{ID: "c", Module: "VulScan", TargetJSON: "{}"},
	}
	if _, err := p.PublishMany(context.Background(), tasks); err != nil {
		t.Fatal(err)
	}
	if n, _ := c.XLen(context.Background(), "scan:stream:PortScan").Result(); n != 2 {
		t.Errorf("PortScan len=%d want 2", n)
	}
	if n, _ := c.XLen(context.Background(), "scan:stream:VulScan").Result(); n != 1 {
		t.Errorf("VulScan len=%d want 1", n)
	}
	_ = time.Millisecond // shut up unused import; remove if not needed
}
```

- [ ] **Step 7.2: 写实现**

```go
// internal/services/streamdispatch/producer.go
package streamdispatch

import (
	"context"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

// TaskInput is what dispatcher hands to the producer.
type TaskInput struct {
	ID         string
	Module     string
	TargetJSON string
}

type Producer struct {
	c *redis.Client
}

func NewProducer(c *redis.Client) *Producer { return &Producer{c: c} }

func streamKey(module string) string { return "scan:stream:" + module }

func (p *Producer) Publish(ctx context.Context, t TaskInput) (string, error) {
	return p.c.XAdd(ctx, &redis.XAddArgs{
		Stream: streamKey(t.Module),
		Values: map[string]any{
			"id":      t.ID,
			"module":  t.Module,
			"target":  t.TargetJSON,
			"ts":      strconv.FormatInt(time.Now().UnixNano(), 10),
			"attempt": "0",
		},
	}).Result()
}

// PublishMany uses pipelining for throughput. Returns map[id]→streamMsgID.
func (p *Producer) PublishMany(ctx context.Context, tasks []TaskInput) (map[string]string, error) {
	pipe := p.c.Pipeline()
	cmds := make([]*redis.StringCmd, len(tasks))
	for i, t := range tasks {
		cmds[i] = pipe.XAdd(ctx, &redis.XAddArgs{
			Stream: streamKey(t.Module),
			Values: map[string]any{
				"id":      t.ID,
				"module":  t.Module,
				"target":  t.TargetJSON,
				"ts":      strconv.FormatInt(time.Now().UnixNano(), 10),
				"attempt": "0",
			},
		})
	}
	if _, err := pipe.Exec(ctx); err != nil {
		return nil, err
	}
	out := make(map[string]string, len(tasks))
	for i, c := range cmds {
		out[tasks[i].ID], _ = c.Result()
	}
	return out, nil
}
```

- [ ] **Step 7.3: 跑测试**

```bash
cd ScopeSentry && go get github.com/alicebob/miniredis/v2 && go test ./internal/services/streamdispatch/ -v
```

Expected: 3 PASS。

- [ ] **Step 7.4: Commit**

```bash
git add ScopeSentry/internal/services/streamdispatch/producer.go \
        ScopeSentry/internal/services/streamdispatch/producer_test.go \
        ScopeSentry/go.mod ScopeSentry/go.sum
git commit -m "feat(streamdispatch): producer publishes tasks to per-module streams"
```

---

## Task 8: Reaper(死节点任务回收 + DLQ)

**Files:**
- Create: `ScopeSentry/internal/services/streamdispatch/reaper.go`
- Create: `ScopeSentry/internal/services/streamdispatch/reaper_test.go`

- [ ] **Step 8.1: 写测试**

```go
package streamdispatch

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newRedisAndStream(t *testing.T) (*redis.Client, *miniredis.Miniredis) {
	mr := miniredis.RunT(t)
	c := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { c.Close() })
	return c, mr
}

func TestReaper_ReassignsIdleEntries(t *testing.T) {
	c, mr := newRedisAndStream(t)

	stream := "scan:stream:PortScan"
	c.XAdd(context.Background(), &redis.XAddArgs{Stream: stream, Values: map[string]any{
		"id": "t1", "module": "PortScan", "target": "{}", "ts": "1", "attempt": "0",
	}})
	c.XGroupCreateMkStream(context.Background(), stream, "scan-workers", "$")
	// node-dead picks it up
	res, _ := c.XReadGroup(context.Background(), &redis.XReadGroupArgs{
		Group: "scan-workers", Consumer: "node-dead",
		Streams: []string{stream, ">"}, Count: 1, Block: 100 * time.Millisecond,
	}).Result()
	if len(res) == 0 || len(res[0].Messages) == 0 {
		t.Fatal("setup failed")
	}

	// fast-forward 10 minutes — entry now idle long enough
	mr.FastForward(10 * time.Minute)

	r := NewReaper(c, ReaperConfig{
		Modules:    []string{"PortScan"},
		LeaseAfter: 5 * time.Minute,
		Reaper:     "reaper-1",
		MaxAttempts: 3,
	})
	if err := r.Sweep(context.Background()); err != nil {
		t.Fatal(err)
	}

	// After sweep, the entry should have been XCLAIMed away from node-dead.
	// Verify by reading pending; the consumer should now be "reaper-1".
	pendings, _ := c.XPendingExt(context.Background(), &redis.XPendingExtArgs{
		Stream: stream, Group: "scan-workers", Start: "-", End: "+", Count: 10,
	}).Result()
	if len(pendings) != 1 {
		t.Fatalf("pending=%v", pendings)
	}
	if pendings[0].Consumer != "reaper-1" {
		t.Errorf("consumer=%s want reaper-1 (entry was reassigned)", pendings[0].Consumer)
	}
}

func TestReaper_MovesToDLQAfterMaxAttempts(t *testing.T) {
	c, mr := newRedisAndStream(t)
	stream := "scan:stream:PortScan"

	// task with attempt=3 (already at max)
	c.XAdd(context.Background(), &redis.XAddArgs{Stream: stream, Values: map[string]any{
		"id": "t1", "module": "PortScan", "target": "{}", "ts": "1", "attempt": "3",
	}})
	c.XGroupCreateMkStream(context.Background(), stream, "scan-workers", "$")
	c.XReadGroup(context.Background(), &redis.XReadGroupArgs{
		Group: "scan-workers", Consumer: "node-dead",
		Streams: []string{stream, ">"}, Count: 1, Block: 100 * time.Millisecond,
	})
	mr.FastForward(10 * time.Minute)

	r := NewReaper(c, ReaperConfig{
		Modules:    []string{"PortScan"},
		LeaseAfter: 5 * time.Minute,
		Reaper:     "reaper-1",
		MaxAttempts: 3,
	})
	if err := r.Sweep(context.Background()); err != nil {
		t.Fatal(err)
	}

	dlqLen, _ := c.XLen(context.Background(), "scan:stream:PortScan:dlq").Result()
	if dlqLen != 1 {
		t.Errorf("DLQ len=%d want 1", dlqLen)
	}
	primaryPending, _ := c.XPendingExt(context.Background(), &redis.XPendingExtArgs{
		Stream: stream, Group: "scan-workers", Start: "-", End: "+", Count: 10,
	}).Result()
	if len(primaryPending) != 0 {
		t.Errorf("primary still pending after DLQ move: %v", primaryPending)
	}
}
```

- [ ] **Step 8.2: 写实现**

```go
// internal/services/streamdispatch/reaper.go
package streamdispatch

import (
	"context"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

type ReaperConfig struct {
	Modules     []string
	LeaseAfter  time.Duration // entries idle longer than this are reclaimed
	Reaper      string        // consumer name to claim entries to (admin-only)
	MaxAttempts int           // beyond this, entries go to DLQ
	BatchSize   int64         // XAUTOCLAIM page size, default 64
}

type Reaper struct {
	c   *redis.Client
	cfg ReaperConfig
}

func NewReaper(c *redis.Client, cfg ReaperConfig) *Reaper {
	if cfg.BatchSize == 0 {
		cfg.BatchSize = 64
	}
	if cfg.MaxAttempts == 0 {
		cfg.MaxAttempts = 3
	}
	return &Reaper{c: c, cfg: cfg}
}

// Run loops until ctx cancelled, sweeping every cfg.LeaseAfter/2.
func (r *Reaper) Run(ctx context.Context) {
	interval := r.cfg.LeaseAfter / 2
	if interval < 30*time.Second {
		interval = 30 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = r.Sweep(ctx)
		}
	}
}

// Sweep does one pass across all configured module streams.
// For each stream:
//   1. XAUTOCLAIM idle entries to ourselves.
//   2. For claimed entries, parse attempt; if ≥ max, push to DLQ + XACK + XDEL.
//      Otherwise increment attempt and re-add to primary (XACK old + XADD new).
func (r *Reaper) Sweep(ctx context.Context) error {
	for _, mod := range r.cfg.Modules {
		stream := "scan:stream:" + mod
		dlq := stream + ":dlq"
		var cursor = "0-0"
		for {
			res, next, err := r.c.XAutoClaim(ctx, &redis.XAutoClaimArgs{
				Stream:   stream,
				Group:    "scan-workers",
				Consumer: r.cfg.Reaper,
				MinIdle:  r.cfg.LeaseAfter,
				Start:    cursor,
				Count:    r.cfg.BatchSize,
			}).Result()
			if err != nil {
				return err
			}
			if len(res) == 0 {
				break
			}
			for _, msg := range res {
				if err := r.handleClaimed(ctx, stream, dlq, msg); err != nil {
					return err
				}
			}
			cursor = next
			if next == "0-0" {
				break
			}
		}
	}
	return nil
}

func (r *Reaper) handleClaimed(ctx context.Context, stream, dlq string, msg redis.XMessage) error {
	attempt := 0
	if a, ok := msg.Values["attempt"]; ok {
		if s, ok := a.(string); ok {
			attempt, _ = strconv.Atoi(s)
		}
	}
	attempt++ // count this re-claim

	if attempt > r.cfg.MaxAttempts {
		// move to DLQ
		newVals := make(map[string]any, len(msg.Values)+2)
		for k, v := range msg.Values {
			newVals[k] = v
		}
		newVals["attempt"] = strconv.Itoa(attempt)
		newVals["dlq_reason"] = "max_attempts_exceeded"
		newVals["dlq_at"] = strconv.FormatInt(time.Now().Unix(), 10)
		if _, err := r.c.XAdd(ctx, &redis.XAddArgs{Stream: dlq, Values: newVals}).Result(); err != nil {
			return err
		}
		if err := r.c.XAck(ctx, stream, "scan-workers", msg.ID).Err(); err != nil {
			return err
		}
		// best-effort cleanup
		r.c.XDel(ctx, stream, msg.ID)
		return nil
	}

	// Re-publish with bumped attempt; ack + delete the old.
	newVals := make(map[string]any, len(msg.Values))
	for k, v := range msg.Values {
		newVals[k] = v
	}
	newVals["attempt"] = strconv.Itoa(attempt)
	if _, err := r.c.XAdd(ctx, &redis.XAddArgs{Stream: stream, Values: newVals}).Result(); err != nil {
		return err
	}
	if err := r.c.XAck(ctx, stream, "scan-workers", msg.ID).Err(); err != nil {
		return err
	}
	r.c.XDel(ctx, stream, msg.ID)
	return nil
}
```

- [ ] **Step 8.3: 跑测试**

```bash
go test ./internal/services/streamdispatch/ -v -timeout 30s
```

Expected: 5 PASS(包括之前 producer 的 3 + reaper 的 2)。

- [ ] **Step 8.4: Commit**

```bash
git add ScopeSentry/internal/services/streamdispatch/reaper.go \
        ScopeSentry/internal/services/streamdispatch/reaper_test.go
git commit -m "feat(streamdispatch): reaper auto-claims idle entries and routes to DLQ"
```

---

## Task 9: 中心端启动 Reaper + 接入 dispatch

**Files:**
- Modify: 现有 dispatcher 代码(找到调用 `NodeTask:` 写入的地方)
- Modify: server bootstrap 加 Reaper 启动

- [ ] **Step 9.1: 找现有 dispatch 代码**

```bash
cd ScopeSentry
grep -rn "NodeTask:" internal/ --include="*.go"
```

预期能看到现在 dispatcher 把任务推给 `NodeTask:{NodeName}`(或类似名字)的代码点。这是要替换的地方。

- [ ] **Step 9.2: 在 dispatcher 改成调用 streamdispatch.Producer**

具体改动取决于现有代码,大致模式:

```go
// 现在的代码(类似)
// redisClient.LPush(ctx, "NodeTask:"+nodeName, taskJSON)

// 改成
producer := streamdispatch.NewProducer(redisClient)
_, err := producer.Publish(ctx, streamdispatch.TaskInput{
    ID:         taskOpts.ID,
    Module:     taskOpts.ModuleName, // 现有 TaskOptions 里应该有 module 字段
    TargetJSON: taskJSON,
})
```

如果一个 task 涉及多个 module(像现在 task 是个大综合体),需要把它**拆**成 N 条 stream 消息(每个 module 一条),或者保持原样发到一个"composite"流并由扫描器内部按 module 拆分。

**第一阶段简化:** 保持现有 task 结构,在 dispatcher 入口判断 module:
- 如果 task 涉及多 module → 暂时先发到 `scan:stream:Composite` 流(或者沿用 NodeTask 旧路径,通过 `TASK_MODE=legacy` 保持兼容)
- 如果是单 module(细粒度任务)→ 走 stream

具体决策依现有 dispatcher 形态。建议:**先做 dual-write**(同时写老队列和新流),逐步迁移。

- [ ] **Step 9.3: 启动 Reaper**

在 server bootstrap 里:

```go
reaper := streamdispatch.NewReaper(redisClient, streamdispatch.ReaperConfig{
	Modules:     allModuleNames(), // []string{"SubdomainScan", ..., "PageMonitoring"}
	LeaseAfter:  5 * time.Minute,
	Reaper:      "central-reaper",
	MaxAttempts: 3,
})
go reaper.Run(context.Background())
```

`allModuleNames()` 返回 12 个 capability 字符串(同 Plan 2 Task 1.2)。

- [ ] **Step 9.4: 编译 + 测试**

```bash
go build ./... && go test ./...
```

- [ ] **Step 9.5: Commit**

```bash
git commit -am "feat(dispatch): publish tasks to streams + start reaper"
```

---

## Task 10: 管理 API + 前端监控

**Files:**
- Create: `ScopeSentry/internal/api/handlers/streamtask/admin.go`
- Modify: `ScopeSentry/internal/api/routes/routes.go` 注册路由
- Create: `ScopeSentry-UI/src/views/Node/components/StreamMonitor.vue`

接口:
- `GET /api/streamtask/length` — 各 module 的 stream 长度
- `GET /api/streamtask/pending?module=xxx` — XPENDING 列表
- `GET /api/streamtask/dlq?module=xxx` — DLQ 内容(分页)
- `POST /api/streamtask/dlq/replay` — 把 DLQ entry 重投回主流

- [ ] **Step 10.1: 写 admin handler**

```go
// internal/api/handlers/streamtask/admin.go
package streamtask

import (
	"context"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

type Handler struct {
	c       *redis.Client
	modules []string
}

func NewHandler(c *redis.Client, modules []string) *Handler {
	return &Handler{c: c, modules: modules}
}

func (h *Handler) ListLengths(c *gin.Context) {
	ctx := c.Request.Context()
	out := make(map[string]map[string]int64, len(h.modules))
	for _, m := range h.modules {
		primary, _ := h.c.XLen(ctx, "scan:stream:"+m).Result()
		dlq, _ := h.c.XLen(ctx, "scan:stream:"+m+":dlq").Result()
		out[m] = map[string]int64{"primary": primary, "dlq": dlq}
	}
	c.JSON(http.StatusOK, gin.H{"streams": out})
}

func (h *Handler) ListPending(c *gin.Context) {
	module := c.Query("module")
	if module == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "module required"})
		return
	}
	res, err := h.c.XPendingExt(c.Request.Context(), &redis.XPendingExtArgs{
		Stream: "scan:stream:" + module, Group: "scan-workers",
		Start: "-", End: "+", Count: 200,
	}).Result()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"pending": res})
}

func (h *Handler) ListDLQ(c *gin.Context) {
	module := c.Query("module")
	if module == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "module required"})
		return
	}
	limit := int64(50)
	if l, err := strconv.ParseInt(c.DefaultQuery("limit", "50"), 10, 64); err == nil {
		limit = l
	}
	res, err := h.c.XRevRangeN(c.Request.Context(), "scan:stream:"+module+":dlq", "+", "-", limit).Result()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"entries": res})
}

func (h *Handler) ReplayDLQ(c *gin.Context) {
	var req struct {
		Module    string `json:"module"`
		MessageID string `json:"message_id"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	dlq := "scan:stream:" + req.Module + ":dlq"
	primary := "scan:stream:" + req.Module
	ctx := c.Request.Context()
	r := h.c.XRange(ctx, dlq, req.MessageID, req.MessageID)
	res, err := r.Result()
	if err != nil || len(res) == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "DLQ entry not found"})
		return
	}
	vals := res[0].Values
	delete(vals, "dlq_reason")
	delete(vals, "dlq_at")
	vals["attempt"] = "0"
	newID, err := h.c.XAdd(ctx, &redis.XAddArgs{Stream: primary, Values: vals}).Result()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if err := h.c.XDel(ctx, dlq, req.MessageID).Err(); err != nil {
		// not fatal — task is replayed; DLQ entry will linger until cleaned manually
	}
	c.JSON(http.StatusOK, gin.H{"new_id": newID})
	_ = context.Background // satisfy import
}
```

- [ ] **Step 10.2: 注册路由**

修改 `internal/api/routes/routes.go`,在认证保护的 api 组里加:

```go
sth := streamtask.NewHandler(redisClient, allModuleNames())
api.GET("/streamtask/length", sth.ListLengths)
api.GET("/streamtask/pending", sth.ListPending)
api.GET("/streamtask/dlq", sth.ListDLQ)
api.POST("/streamtask/dlq/replay", sth.ReplayDLQ)
```

- [ ] **Step 10.3: 前端组件 StreamMonitor.vue**(简略版)

```vue
<!-- src/views/Node/components/StreamMonitor.vue -->
<template>
  <div class="stream-monitor">
    <h3>任务流监控</h3>
    <el-table :data="rows">
      <el-table-column prop="module" label="模块" />
      <el-table-column prop="primary" label="待处理" />
      <el-table-column prop="dlq" label="死信(DLQ)">
        <template #default="{ row }">
          <el-link v-if="row.dlq > 0" type="danger" @click="openDlq(row.module)">
            {{ row.dlq }}
          </el-link>
          <span v-else>{{ row.dlq }}</span>
        </template>
      </el-table-column>
    </el-table>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref, onBeforeUnmount } from 'vue'
import request from '@/axios'

const rows = ref<{ module: string; primary: number; dlq: number }[]>([])
let timer: number | undefined

async function refresh() {
  const r = await request.get<{ streams: Record<string, { primary: number; dlq: number }> }>({
    url: '/api/streamtask/length',
  })
  rows.value = Object.entries(r.streams).map(([m, v]) => ({ module: m, ...v }))
}
function openDlq(_m: string) { /* navigate to DLQ detail page */ }

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 5000)
})
onBeforeUnmount(() => timer && clearInterval(timer))
</script>
```

集成到节点详情页 / dashboard。

- [ ] **Step 10.4: Commit**

```bash
git add ScopeSentry/internal/api/handlers/streamtask/ \
        ScopeSentry/internal/api/routes/routes.go \
        ScopeSentry-UI/src/views/Node/components/StreamMonitor.vue
git commit -m "feat(streamtask): admin API + monitoring UI"
```

---

## Task 11: 灰度切换流程

**Files:** 无代码改,纯运维。

按以下顺序滚动:

- [ ] **Step 11.1: 中心端 dual-write**

中心端 dispatcher 改成同时:
1. 写到 `NodeTask:{NodeName}` 老队列(老节点继续用)
2. 写到 `scan:stream:{Module}` 新流(新节点用)

这一步对老节点完全透明,新节点(`TASK_MODE=stream`)开始消费 stream。

- [ ] **Step 11.2: 切第一个节点到 stream 模式**

```bash
# 在某台 VPS 上重启容器,加 -e TASK_MODE=stream
docker stop scopesentry-scan && docker rm scopesentry-scan
docker run -d --name scopesentry-scan ... -e TASK_MODE=stream -e CAPABILITIES=SubdomainScan ...
```

观察:
- 该节点 `NodeTask:{NodeName}` 队列长度持续增长(老路径不再消费)→ **预期** dual-write 是问题,改成 single-write 到 stream
- stream 消费正常吗?手动塞一个测试任务:
  ```bash
  redis-cli -a xxx XADD scan:stream:SubdomainScan '*' \
    id test-1 module SubdomainScan target '{"id":"test-1"}' ts $(date +%s%N) attempt 0
  ```
- 节点 docker logs 应该有 task running 输出
- 几秒后 `XPENDING` 看不到该 entry(已 ack)

- [ ] **Step 11.3: 把 dispatcher 改成 single-write**

确认 stream 模式稳定后,中心端 dispatcher 停止写 `NodeTask:{}` 老队列。这一步**所有还在 legacy 模式的节点都要先迁好**,否则它们饿死。

- [ ] **Step 11.4: 全部节点迁移**

逐个 VPS 重启,加 `TASK_MODE=stream` + 该节点的 `CAPABILITIES`。

- [ ] **Step 11.5: 停 reaper 之前的旧 list 清理脚本(如果有)**

老的 `NodeTask:*` list 可以留着不动(空的,不占空间);或定期清理。

- [ ] **Step 11.6: 可选:删除 task.GetTask 老路径代码**

留几周观察期后,可以从 `internal/task/task.go` 移除 `GetTask` / `RunRedisTask`,只保留 `RunPebbleTarget`(被 streamtask handler 调用)。

---

## Task 12: 容错验证

- [ ] **Step 12.1: 模拟节点死亡**

```bash
# 节点 A 正在跑 5 个任务
docker stop -t 0 scopesentry-scan  # 强杀,不给清理时间

# 5 分钟后(LeaseAfter)
# Reaper 应该 XAUTOCLAIM 把 A 的任务转到 reaper consumer
# 然后 attempt+1 重新 XADD

# 验证:
redis-cli -a xxx XRANGE scan:stream:SubdomainScan - +  # 应该看到带 attempt=1 的新条目
redis-cli -a xxx XPENDING scan:stream:SubdomainScan scan-workers  # node-A 的 pending 应清零
```

- [ ] **Step 12.2: 模拟任务永久失败**

让某个任务的 plugin 永远报错(如 target=`bad://invalid`),3 次重试后:

```bash
redis-cli -a xxx XLEN scan:stream:SubdomainScan:dlq  # 应 = 1
```

前端"任务流监控"页应看到 DLQ 显示红色 1。

- [ ] **Step 12.3: 模拟节点过载**

`stress-ng --cpu 8` 让节点 budget 进 paused 状态。验证:
- 节点不再 `XREADGROUP`(`docker logs scopesentry-scan` 看到 budget skip)
- stream 长度增长(其他空闲节点会接走)

---

## 验收

| Task | 验收点 |
|---|---|
| 1-2 | 类型 + Stream 操作单元测试全 PASS |
| 3 | Consumer 4 个测试 PASS:成功 ack、失败不 ack、budget paused 不拉、capability 过滤 |
| 4 | Lease 测试 PASS:idle 重置生效 |
| 5 | Pebble runner 适配编译通过 |
| 6 | 双模式开关:`TASK_MODE=legacy` 走老路;`=stream` 走新路 |
| 7-8 | 中心端 producer + reaper 测试 PASS,reaper 能 DLQ |
| 9 | dispatcher 改造完,任务实际写到 stream |
| 10 | 前端能看到各 module stream 长度 + DLQ 列表;能手动重投 |
| 11 | 灰度切换不丢任务、不重复消费 |
| 12 | 节点 kill -9 后,5min 内任务被其他节点接走 |

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| dual-write 阶段任务被消费两次(老 list + 新 stream 都有) | 中心端 dual-write 时,标记"哪个版本是权威":`primary=stream`,老节点跳过该任务;或干脆不 dual-write,先把节点全部迁完再切 dispatcher |
| stream entry 丢失(Redis 重启 + 没有 AOF) | 启用 Redis AOF (`appendonly yes`);或 `MAXLEN` 控制不要无限增长 |
| Reaper 启动太频繁导致 race(同一 entry 被两个 reaper 抢) | 部署单实例 reaper(中心端 leader election),或用 `XAUTOCLAIM` 的天然原子性(同一 entry 不会被 claim 两次) |
| 任务负载不均(全部进 SubdomainScan stream,节点都被占用做 subdomain) | 不是 stream 的问题——是 capability 配置问题。前端能看到 stream 长度对比,人工调度;后续可加权重 |
| MaxAttempts=3 不够,某些 plugin 偶发失败被误判 | 阈值可配置;DLQ replay 接口给运维兜底 |
| `XAUTOCLAIM` 在 Redis < 6.2 不存在 | 你 Redis 7.0,无问题。如果有更老节点用同一 redis,需要他们也 ≥ 6.2 |
| 老的 `task.GetTask` 还在,新老共存难调试 | TASK_MODE 显式开关 + 部署时 `docker logs` 看选了哪条路径 |

---

## Self-Review

**Spec coverage:**
- 节点抢自己能干的活(pull) → Task 3 (Consumer + Capability) ✅
- 任务卡死能转移给别人 → Task 4 (Lease) + Task 8 (Reaper XAUTOCLAIM) ✅
- 完成保证(at-least-once) → ack 机制 + DLQ ✅
- 节点能力声明影响调度 → Task 3 (Streams 列表只含 capabilities) ✅
- 总控保证任务都能完成 → Reaper + DLQ + 管理界面手动重投 ✅
- 与 budget 配合实现 backpressure → Task 3 budget gate 控制 COUNT ✅

**Placeholder scan:** 无 TBD/TODO。Step 9.2 中"如果一个 task 涉及多个 module..."这段是设计指引,不是占位 — 真正实施时是按这段决策做(并非"待补")。

**Type consistency:**
- `TaskMessage` 字段名(`id/module/target/ts/attempt`) 在 scanner producer.ToFields、ParseTaskMessage、reaper、admin handler 中完全一致。
- `ConsumerGroup = "scan-workers"` 单点常量,所有引用同源。
- `StreamKey()/DLQKey()` 函数签名跨 plan 一致(scanner + 中心端都按 `scan:stream:{Module}` 拼)。

---

## 总结:三份计划的执行顺序与时间预估

| Plan | 时间预估 | 依赖 | 价值 |
|---|---|---|---|
| **Plan 1: 节点资源保命** | 3-4 天 | 无 | 立即解决 VPS 12h 关机问题 |
| **Plan 2: HTTP 一键上线** | 6-8 天(可分前后端并行) | Plan 1 | 多 VPS 部署体验从 30 分钟 → 60 秒 |
| **Plan 3: Pull + Lease** | 5-7 天 | Plan 1 + Plan 2 | 任务级容错 + 真正的负载均衡 |

**总计 ~3 周**,但 Plan 1 一上线就能止血。Plan 2-3 可以先在测试环境推进。
