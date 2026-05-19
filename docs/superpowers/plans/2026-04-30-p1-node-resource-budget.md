# P-1 节点资源保命(多窗口预算 + Cooldown 注入)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让扫描器节点能基于多时间窗的 CPU/内存/磁盘水位自我节流(动态调整并发 + 主动 cooldown),保证持续高负载下 12 小时滑动平均不击穿 VPS 厂商策略,从根源避免节点被强制关机。

**Architecture:** 三层结构:`internal/node/budget` 包内部有 (1) 滑动窗口采样器(短/中/长 三个 Ring buffer)、(2) 滞后状态机(Open / Throttled / Paused / EmergencyCooldown)、(3) Cooldown 调度器(占空比注入)。通过单例 `Gate` 暴露给 `task.go` 决策"现在能否接新任务、并发数应当是多少"。所有决策本地完成,不依赖中心端;心跳里附带预算遥测供前端可视化。

**Tech Stack:** Go 1.24 / `github.com/shirou/gopsutil/v3` / `github.com/redis/go-redis/v9`(已有依赖)/ `testing` 标准库 / `github.com/stretchr/testify`(已存在的项目用法,见 `internal/results/discovery_test.go` 的 mock 模式)

**前置条件:** 无。本计划完全在 `ScopeSentry-Scan` 仓内,不需要中心端配合。

---

## File Structure

| 文件 | 责任 |
|------|------|
| `internal/node/budget/types.go` (新) | 配置结构、采样点结构、状态枚举的纯数据定义 |
| `internal/node/budget/ringbuf.go` (新) | 定长环形 buffer + 平均/最大值统计,无业务逻辑 |
| `internal/node/budget/ringbuf_test.go` (新) | 环形 buffer 单元测试 |
| `internal/node/budget/sampler.go` (新) | 调用 gopsutil 采样 CPU/Mem/磁盘,写到三个 ring buffer |
| `internal/node/budget/sampler_test.go` (新) | 用注入的 fakeProbe 测试采样逻辑 |
| `internal/node/budget/gate.go` (新) | 滞后状态机 + cooldown 调度,提供 `Decision()` 给任务循环 |
| `internal/node/budget/gate_test.go` (新) | 状态机测试(各阈值穿越 + cooldown 占空比) |
| `internal/node/budget/budget.go` (新) | `Budget` 单例,绑定 sampler+gate,暴露 `Start/Stop/Snapshot/Decision` |
| `internal/node/budget/budget_test.go` (新) | 集成测试 |
| `internal/global/type.go` (改) | 加 `BudgetConfig` 子结构到 `Config` |
| `internal/config/config.go` (改) | 从 env 读 budget 配置 + 默认值 |
| `internal/node/node.go` (改) | 心跳 hash 多上报 budget 字段 |
| `internal/task/task.go` (改) | `RunRedisTask` 循环开头查 gate;每次 pop 之前查决策 |
| `cmd/ScopeSentry/main.go` (改) | 启动 budget 单例 |

**为什么这样切分:** Ring buffer 是纯数据结构(独立测试)→ Sampler 是 IO 边界(注入 fake)→ Gate 是纯状态机(注入时间)→ Budget 是组装层。每层职责单一,便于 TDD。**按职责切分,不按层切分**。

---

## Task 1: 数据结构 + 配置类型(纯定义,先打地基)

**Files:**
- Create: `ScopeSentry-Scan/internal/node/budget/types.go`
- Modify: `ScopeSentry-Scan/internal/global/type.go`

- [ ] **Step 1.1: 创建 types.go**

```go
// Package budget tracks rolling CPU/memory/disk usage and decides whether
// a scanner node should accept new tasks. All decisions are local; budget
// telemetry is reported to the central plane via the existing heartbeat.
package budget

import "time"

// Sample is one resource snapshot taken by Sampler.
type Sample struct {
	At        time.Time
	CPUPct    float64 // 0..100, instantaneous (or short-window per gopsutil)
	MemPct    float64 // 0..100 of RAM
	DiskFreeB int64   // bytes free on the data partition
	LoadAvg1  float64 // 1-minute load average (Linux)
}

// Stats summarises a window.
type Stats struct {
	Count    int
	CPUMean  float64
	CPUMax   float64
	MemMean  float64
	MemMax   float64
	Load1Max float64
}

// State is the throttle state.
type State int

const (
	StateOpen              State = iota // accept tasks, full concurrency
	StateThrottled                      // accept tasks, reduced concurrency
	StatePaused                         // do NOT accept new tasks; finish in-flight
	StateEmergencyCooldown              // forced idle window injected to protect long-window budget
)

func (s State) String() string {
	switch s {
	case StateOpen:
		return "open"
	case StateThrottled:
		return "throttled"
	case StatePaused:
		return "paused"
	case StateEmergencyCooldown:
		return "emergency_cooldown"
	default:
		return "unknown"
	}
}

// Decision is what the gate tells the task loop right now.
type Decision struct {
	State              State
	MaxConcurrency     int     // 0 = pause; the task loop should not pop new tasks
	NextEvaluationIn   time.Duration
	Reason             string  // human-readable, surfaced to logs and heartbeat
}

// Config is loaded from env / yaml. All durations in seconds for ergonomics.
type Config struct {
	Enabled bool `yaml:"enabled"`

	// Sampling
	SampleIntervalSec int `yaml:"sampleIntervalSec"` // default 5

	// Window sizes
	ShortWindowSec  int `yaml:"shortWindowSec"`  // default 30
	MediumWindowSec int `yaml:"mediumWindowSec"` // default 3600
	LongWindowSec   int `yaml:"longWindowSec"`   // default 43200 (12h)

	// Thresholds (percent 0..100). Hysteresis: high triggers, low recovers.
	CPUHighShort  float64 `yaml:"cpuHighShort"`  // 85
	CPULowShort   float64 `yaml:"cpuLowShort"`   // 65
	CPUHighMedium float64 `yaml:"cpuHighMedium"` // 70
	CPULowMedium  float64 `yaml:"cpuLowMedium"`  // 50
	CPUHighLong   float64 `yaml:"cpuHighLong"`   // 60
	CPULowLong    float64 `yaml:"cpuLowLong"`    // 45
	MemHigh       float64 `yaml:"memHigh"`       // 85
	MemLow        float64 `yaml:"memLow"`        // 70

	// Disk hard floor in MB; below this all tasks paused.
	DiskMinFreeMB int64 `yaml:"diskMinFreeMB"` // 5120 (5 GB)

	// Hysteresis dwell times: how long thresholds must be exceeded.
	HighDwellSec int `yaml:"highDwellSec"` // 30
	LowDwellSec  int `yaml:"lowDwellSec"`  // 60

	// Cooldown injection
	CooldownEnabled    bool `yaml:"cooldownEnabled"`    // true
	WorkPeriodMin      int  `yaml:"workPeriodMin"`      // 50 (work for 50min)
	CooldownPeriodMin  int  `yaml:"cooldownPeriodMin"`  // 10 (rest for 10min)
	CooldownTriggerMed float64 `yaml:"cooldownTriggerMed"` // 65 (medium-window CPU above which to enable cooldown loop)

	// Concurrency tiers (CPU-based scaling factor for MaxGoroutineCount)
	TierA float64 `yaml:"tierA"` // 50, below: 1.0x
	TierB float64 `yaml:"tierB"` // 70, below: 1.0x; above: 0.5x
	TierC float64 `yaml:"tierC"` // 85, above: 0.0x (pause)

	// Disk path to monitor (default: scanner data dir)
	DiskMountPath string `yaml:"diskMountPath"` // ""=auto-detect (use AbsolutePath)
}

// DefaultConfig returns conservative defaults proven safe on a 12h-100%-shutdown VPS.
func DefaultConfig() Config {
	return Config{
		Enabled:            true,
		SampleIntervalSec:  5,
		ShortWindowSec:     30,
		MediumWindowSec:    3600,
		LongWindowSec:      43200,
		CPUHighShort:       85,
		CPULowShort:        65,
		CPUHighMedium:      70,
		CPULowMedium:       50,
		CPUHighLong:        60,
		CPULowLong:         45,
		MemHigh:            85,
		MemLow:             70,
		DiskMinFreeMB:      5120,
		HighDwellSec:       30,
		LowDwellSec:        60,
		CooldownEnabled:    true,
		WorkPeriodMin:      50,
		CooldownPeriodMin:  10,
		CooldownTriggerMed: 65,
		TierA:              50,
		TierB:              70,
		TierC:              85,
		DiskMountPath:      "",
	}
}
```

- [ ] **Step 1.2: 在 global/type.go 加 BudgetConfig 字段**

修改 `internal/global/type.go` 第 11 行附近的 `Config` struct,添加最后一个字段:

```go
type Config struct {
	NodeName     string           `yaml:"NodeName"`
	State        int              `yaml:"state"`
	TimeZoneName string           `yaml:"TimeZoneName"`
	Debug        bool             `yaml:"debug"`
	MongoDB      MongoDBConfig    `yaml:"mongodb"`
	Redis        RedisConfig      `yaml:"redis"`
	Interactsh   InteractshConfig `yaml:"interactsh"`
	Budget       BudgetConfig     `yaml:"budget"` // NEW
}

// BudgetConfig is a thin re-export so global package can import without
// pulling in budget package (which depends on time/types).
// The full config is loaded in internal/config/config.go and translated
// to the budget.Config used at runtime.
type BudgetConfig struct {
	Enabled            bool    `yaml:"enabled"`
	SampleIntervalSec  int     `yaml:"sampleIntervalSec"`
	ShortWindowSec     int     `yaml:"shortWindowSec"`
	MediumWindowSec    int     `yaml:"mediumWindowSec"`
	LongWindowSec      int     `yaml:"longWindowSec"`
	CPUHighShort       float64 `yaml:"cpuHighShort"`
	CPULowShort        float64 `yaml:"cpuLowShort"`
	CPUHighMedium      float64 `yaml:"cpuHighMedium"`
	CPULowMedium       float64 `yaml:"cpuLowMedium"`
	CPUHighLong        float64 `yaml:"cpuHighLong"`
	CPULowLong         float64 `yaml:"cpuLowLong"`
	MemHigh            float64 `yaml:"memHigh"`
	MemLow             float64 `yaml:"memLow"`
	DiskMinFreeMB      int64   `yaml:"diskMinFreeMB"`
	HighDwellSec       int     `yaml:"highDwellSec"`
	LowDwellSec        int     `yaml:"lowDwellSec"`
	CooldownEnabled    bool    `yaml:"cooldownEnabled"`
	WorkPeriodMin      int     `yaml:"workPeriodMin"`
	CooldownPeriodMin  int     `yaml:"cooldownPeriodMin"`
	CooldownTriggerMed float64 `yaml:"cooldownTriggerMed"`
	TierA              float64 `yaml:"tierA"`
	TierB              float64 `yaml:"tierB"`
	TierC              float64 `yaml:"tierC"`
	DiskMountPath      string  `yaml:"diskMountPath"`
}
```

- [ ] **Step 1.3: 编译通过**

```bash
cd ScopeSentry-Scan
go build ./...
```

Expected: 无报错(目前还没有任何代码引用,只是新增类型定义)。

- [ ] **Step 1.4: Commit**

```bash
git add ScopeSentry-Scan/internal/node/budget/types.go \
        ScopeSentry-Scan/internal/global/type.go
git commit -m "feat(budget): add types and config struct skeleton"
```

---

## Task 2: 环形 buffer(纯数据结构,TDD 跑通)

**Files:**
- Create: `ScopeSentry-Scan/internal/node/budget/ringbuf.go`
- Test:   `ScopeSentry-Scan/internal/node/budget/ringbuf_test.go`

- [ ] **Step 2.1: 写 ringbuf_test.go(先失败)**

```go
package budget

import (
	"testing"
	"time"
)

func TestRingBuf_PushOverwritesOldest(t *testing.T) {
	rb := newRingBuf(3)
	rb.push(Sample{At: tsec(1), CPUPct: 10})
	rb.push(Sample{At: tsec(2), CPUPct: 20})
	rb.push(Sample{At: tsec(3), CPUPct: 30})
	rb.push(Sample{At: tsec(4), CPUPct: 40}) // overwrites oldest

	got := rb.snapshot()
	if len(got) != 3 {
		t.Fatalf("len=%d, want 3", len(got))
	}
	if got[0].CPUPct != 20 || got[2].CPUPct != 40 {
		t.Errorf("oldest-first order broken: %+v", got)
	}
}

func TestRingBuf_StatsEmpty(t *testing.T) {
	rb := newRingBuf(5)
	st := rb.stats()
	if st.Count != 0 {
		t.Errorf("empty count=%d", st.Count)
	}
}

func TestRingBuf_StatsMeansAndMax(t *testing.T) {
	rb := newRingBuf(4)
	rb.push(Sample{At: tsec(1), CPUPct: 10, MemPct: 20, LoadAvg1: 0.5})
	rb.push(Sample{At: tsec(2), CPUPct: 30, MemPct: 40, LoadAvg1: 1.5})
	rb.push(Sample{At: tsec(3), CPUPct: 50, MemPct: 60, LoadAvg1: 2.5})

	st := rb.stats()
	if st.Count != 3 {
		t.Fatalf("count=%d", st.Count)
	}
	if st.CPUMean != 30 {
		t.Errorf("cpu mean=%v, want 30", st.CPUMean)
	}
	if st.CPUMax != 50 {
		t.Errorf("cpu max=%v, want 50", st.CPUMax)
	}
	if st.MemMean != 40 {
		t.Errorf("mem mean=%v, want 40", st.MemMean)
	}
	if st.Load1Max != 2.5 {
		t.Errorf("load max=%v", st.Load1Max)
	}
}

func TestRingBuf_StatsAfterWrap(t *testing.T) {
	rb := newRingBuf(2)
	rb.push(Sample{At: tsec(1), CPUPct: 100})
	rb.push(Sample{At: tsec(2), CPUPct: 100})
	rb.push(Sample{At: tsec(3), CPUPct: 0}) // wraps
	st := rb.stats()
	if st.Count != 2 {
		t.Fatalf("count=%d", st.Count)
	}
	if st.CPUMean != 50 {
		t.Errorf("mean after wrap=%v want 50", st.CPUMean)
	}
}

// Helper: epoch + n seconds
func tsec(n int) time.Time {
	return time.Unix(int64(n), 0)
}
```

- [ ] **Step 2.2: 跑测试,确认失败**

```bash
cd ScopeSentry-Scan
go test ./internal/node/budget/ -run RingBuf -v
```

Expected: 编译失败 `undefined: newRingBuf`。

- [ ] **Step 2.3: 写 ringbuf.go 让测试通过**

```go
package budget

import "sync"

// ringBuf is a fixed-capacity oldest-out FIFO of Samples.
// Goroutine-safe.
type ringBuf struct {
	mu    sync.RWMutex
	cap   int
	data  []Sample
	head  int  // next write index
	full  bool
}

func newRingBuf(capacity int) *ringBuf {
	if capacity < 1 {
		capacity = 1
	}
	return &ringBuf{
		cap:  capacity,
		data: make([]Sample, capacity),
	}
}

func (r *ringBuf) push(s Sample) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.data[r.head] = s
	r.head = (r.head + 1) % r.cap
	if r.head == 0 {
		r.full = true
	}
}

// snapshot returns samples in chronological (oldest-first) order.
func (r *ringBuf) snapshot() []Sample {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if !r.full {
		out := make([]Sample, r.head)
		copy(out, r.data[:r.head])
		return out
	}
	out := make([]Sample, r.cap)
	copy(out, r.data[r.head:])
	copy(out[r.cap-r.head:], r.data[:r.head])
	return out
}

func (r *ringBuf) stats() Stats {
	samples := r.snapshot()
	if len(samples) == 0 {
		return Stats{}
	}
	var sumCPU, sumMem, maxCPU, maxMem, maxLoad float64
	for _, s := range samples {
		sumCPU += s.CPUPct
		sumMem += s.MemPct
		if s.CPUPct > maxCPU {
			maxCPU = s.CPUPct
		}
		if s.MemPct > maxMem {
			maxMem = s.MemPct
		}
		if s.LoadAvg1 > maxLoad {
			maxLoad = s.LoadAvg1
		}
	}
	n := float64(len(samples))
	return Stats{
		Count:    len(samples),
		CPUMean:  sumCPU / n,
		CPUMax:   maxCPU,
		MemMean:  sumMem / n,
		MemMax:   maxMem,
		Load1Max: maxLoad,
	}
}
```

- [ ] **Step 2.4: 跑测试,确认通过**

```bash
go test ./internal/node/budget/ -run RingBuf -v
```

Expected: 4 个 PASS。

- [ ] **Step 2.5: Commit**

```bash
git add ScopeSentry-Scan/internal/node/budget/ringbuf.go \
        ScopeSentry-Scan/internal/node/budget/ringbuf_test.go
git commit -m "feat(budget): add thread-safe ring buffer with rolling stats"
```

---

## Task 3: Sampler(系统采样,IO 边界注入)

**Files:**
- Create: `ScopeSentry-Scan/internal/node/budget/sampler.go`
- Test:   `ScopeSentry-Scan/internal/node/budget/sampler_test.go`

- [ ] **Step 3.1: 写测试 sampler_test.go**

```go
package budget

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestSampler_PushesIntoAllThreeWindows(t *testing.T) {
	cfg := DefaultConfig()
	cfg.SampleIntervalSec = 1 // fast tick for tests
	cfg.ShortWindowSec = 2
	cfg.MediumWindowSec = 4
	cfg.LongWindowSec = 8

	probe := &fakeProbe{cpu: 50, mem: 30, free: 100 << 30, load1: 1.0}
	s := newSampler(cfg, probe)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.run(ctx)

	// Wait for ~3 ticks
	time.Sleep(3500 * time.Millisecond)
	cancel()

	short := s.shortStats()
	med := s.mediumStats()
	long := s.longStats()

	if short.Count == 0 || med.Count == 0 || long.Count == 0 {
		t.Fatalf("counts: short=%d med=%d long=%d", short.Count, med.Count, long.Count)
	}
	if short.CPUMean < 49 || short.CPUMean > 51 {
		t.Errorf("cpu mean drifted: %v", short.CPUMean)
	}
	if probe.calls.Load() < 3 {
		t.Errorf("probe called %d times, expected ≥ 3", probe.calls.Load())
	}
}

func TestSampler_StopsOnContextCancel(t *testing.T) {
	cfg := DefaultConfig()
	cfg.SampleIntervalSec = 1
	probe := &fakeProbe{cpu: 0}
	s := newSampler(cfg, probe)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { s.run(ctx); close(done) }()
	cancel()

	select {
	case <-done:
		// ok
	case <-time.After(2 * time.Second):
		t.Fatal("sampler did not stop within 2s of cancel")
	}
}

// fakeProbe is a deterministic probe used in tests.
type fakeProbe struct {
	cpu, mem, load1 float64
	free            int64
	calls           atomic.Int64
}

func (p *fakeProbe) Sample() (Sample, error) {
	p.calls.Add(1)
	return Sample{
		At:        time.Now(),
		CPUPct:    p.cpu,
		MemPct:    p.mem,
		DiskFreeB: p.free,
		LoadAvg1:  p.load1,
	}, nil
}
```

- [ ] **Step 3.2: 跑测试,确认失败**

```bash
go test ./internal/node/budget/ -run Sampler -v
```

Expected: `undefined: newSampler` 等。

- [ ] **Step 3.3: 写 sampler.go**

```go
package budget

import (
	"context"
	"sync"
	"time"
)

// probe is the IO-shaped boundary for sampling system metrics.
// Production implementation is gopsutilProbe; tests inject a fake.
type probe interface {
	Sample() (Sample, error)
}

type sampler struct {
	cfg    Config
	probe  probe
	short  *ringBuf
	medium *ringBuf
	long   *ringBuf
	mu     sync.RWMutex
	last   Sample // most recent sample
}

func newSampler(cfg Config, p probe) *sampler {
	short := max1(cfg.ShortWindowSec / max1(cfg.SampleIntervalSec))
	medium := max1(cfg.MediumWindowSec / max1(cfg.SampleIntervalSec))
	long := max1(cfg.LongWindowSec / max1(cfg.SampleIntervalSec))
	return &sampler{
		cfg:    cfg,
		probe:  p,
		short:  newRingBuf(short),
		medium: newRingBuf(medium),
		long:   newRingBuf(long),
	}
}

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

// run blocks until ctx is cancelled. Should be called in a goroutine.
func (s *sampler) run(ctx context.Context) {
	interval := time.Duration(s.cfg.SampleIntervalSec) * time.Second
	if interval <= 0 {
		interval = 5 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()

	// Take one sample immediately so windows aren't empty for the first tick.
	s.tick()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.tick()
		}
	}
}

func (s *sampler) tick() {
	smp, err := s.probe.Sample()
	if err != nil {
		// Don't poison the windows with bogus zeros; just skip this sample.
		return
	}
	s.short.push(smp)
	s.medium.push(smp)
	s.long.push(smp)
	s.mu.Lock()
	s.last = smp
	s.mu.Unlock()
}

func (s *sampler) shortStats() Stats  { return s.short.stats() }
func (s *sampler) mediumStats() Stats { return s.medium.stats() }
func (s *sampler) longStats() Stats   { return s.long.stats() }

func (s *sampler) latest() Sample {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.last
}
```

- [ ] **Step 3.4: 跑测试,确认通过**

```bash
go test ./internal/node/budget/ -run Sampler -v -timeout 30s
```

Expected: 2 个 PASS。

- [ ] **Step 3.5: 写 gopsutil 实现(生产 probe,简单代码不写测试)**

在 `sampler.go` 末尾追加:

```go
// --- production probe ---

// gopsutilProbe samples the live system. Mirrors pkg/utils/utils.go::GetSystemUsage
// but adds disk and load average. Wrapped behind probe interface so tests don't
// hit the real OS.
type gopsutilProbe struct {
	diskPath string
}

// newGopsutilProbe returns a probe configured for diskPath. Empty diskPath falls
// back to root "/" — caller should pass scanner data dir.
func newGopsutilProbe(diskPath string) *gopsutilProbe {
	if diskPath == "" {
		diskPath = "/"
	}
	return &gopsutilProbe{diskPath: diskPath}
}
```

新建 `internal/node/budget/probe_gopsutil.go`(隔离 IO 依赖,易于将来替换):

```go
package budget

import (
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/load"
	"github.com/shirou/gopsutil/v3/mem"
)

func (p *gopsutilProbe) Sample() (Sample, error) {
	// 1s blocking CPU sample. gopsutil returns 0 if interval is 0 (cached).
	// 1s is a tradeoff: longer = smoother but blocks tick longer.
	cpuPct, err := cpu.Percent(time.Second, false)
	if err != nil {
		return Sample{}, err
	}
	var cpuVal float64
	if len(cpuPct) > 0 {
		cpuVal = cpuPct[0]
	}

	memInfo, err := mem.VirtualMemory()
	if err != nil {
		return Sample{}, err
	}

	var freeB int64
	if du, err := disk.Usage(p.diskPath); err == nil {
		freeB = int64(du.Free)
	}

	var load1 float64
	if la, err := load.Avg(); err == nil {
		load1 = la.Load1
	}

	return Sample{
		At:        time.Now(),
		CPUPct:    cpuVal,
		MemPct:    memInfo.UsedPercent,
		DiskFreeB: freeB,
		LoadAvg1:  load1,
	}, nil
}
```

- [ ] **Step 3.6: 编译 + 全量测试**

```bash
go build ./...
go test ./internal/node/budget/ -v -timeout 30s
```

Expected: 所有测试 PASS,包括之前的 RingBuf 测试。

- [ ] **Step 3.7: Commit**

```bash
git add ScopeSentry-Scan/internal/node/budget/sampler.go \
        ScopeSentry-Scan/internal/node/budget/sampler_test.go \
        ScopeSentry-Scan/internal/node/budget/probe_gopsutil.go
git commit -m "feat(budget): add multi-window sampler with gopsutil probe"
```

---

## Task 4: Gate(滞后状态机,TDD 重头戏)

**Files:**
- Create: `ScopeSentry-Scan/internal/node/budget/gate.go`
- Test:   `ScopeSentry-Scan/internal/node/budget/gate_test.go`

- [ ] **Step 4.1: 写 gate_test.go(覆盖所有阈值穿越场景)**

```go
package budget

import (
	"testing"
	"time"
)

// statsProvider lets gate tests inject pre-computed stats without a sampler.
type stubStats struct {
	short, medium, long Stats
	latest              Sample
}

func (s *stubStats) shortStats() Stats  { return s.short }
func (s *stubStats) mediumStats() Stats { return s.medium }
func (s *stubStats) longStats() Stats   { return s.long }
func (s *stubStats) latest() Sample     { return s.latest }

func TestGate_StartsOpen(t *testing.T) {
	g := newGate(DefaultConfig(), fixedClock(0))
	d := g.evaluate(&stubStats{})
	if d.State != StateOpen {
		t.Errorf("state=%v want open", d.State)
	}
	if d.MaxConcurrency <= 0 {
		t.Errorf("concurrency=%d, want positive", d.MaxConcurrency)
	}
}

func TestGate_HighCPUShortWindow_TransitionsAfterDwell(t *testing.T) {
	cfg := DefaultConfig()
	cfg.HighDwellSec = 30
	clk := fixedClock(0)
	g := newGate(cfg, clk)

	// CPU at 90% (above CPUHighShort=85)
	stats := &stubStats{short: Stats{Count: 30, CPUMean: 90}}

	// First eval: high observed, but dwell not yet satisfied
	clk.set(0)
	d := g.evaluate(stats)
	if d.State == StatePaused {
		t.Errorf("paused too early without dwell")
	}

	// Still high after 20s — still under dwell of 30s
	clk.set(20 * time.Second)
	d = g.evaluate(stats)
	if d.State == StatePaused {
		t.Errorf("paused at t=20s, dwell=30s")
	}

	// 30s+ later -> should have transitioned.
	clk.set(35 * time.Second)
	d = g.evaluate(stats)
	if d.State != StatePaused {
		t.Errorf("state=%v want paused after dwell", d.State)
	}
}

func TestGate_LowCPURecoversAfterDwell(t *testing.T) {
	cfg := DefaultConfig()
	cfg.HighDwellSec = 5
	cfg.LowDwellSec = 10
	clk := fixedClock(0)
	g := newGate(cfg, clk)

	// Push to paused
	highStats := &stubStats{short: Stats{Count: 30, CPUMean: 95}}
	clk.set(0)
	g.evaluate(highStats)
	clk.set(6 * time.Second)
	g.evaluate(highStats)
	if got := g.evaluate(highStats); got.State != StatePaused {
		t.Fatalf("setup: expected paused, got %v", got.State)
	}

	// Drop CPU to 50% (below CPULowShort=65)
	lowStats := &stubStats{short: Stats{Count: 30, CPUMean: 50}}
	clk.set(8 * time.Second)
	d := g.evaluate(lowStats)
	if d.State != StatePaused {
		t.Errorf("recovered too early at t=8s without low dwell")
	}

	clk.set(20 * time.Second) // 12s of low: > LowDwellSec=10
	d = g.evaluate(lowStats)
	if d.State == StatePaused {
		t.Errorf("still paused after low dwell satisfied: %v", d.State)
	}
}

func TestGate_TierThrottle_ReducesConcurrency(t *testing.T) {
	cfg := DefaultConfig()
	cfg.TierA, cfg.TierB, cfg.TierC = 50, 70, 85
	clk := fixedClock(0)
	g := newGate(cfg, clk)

	// CPU=60: above TierA (50), below TierB (70) -> tier B band, 1.0x concurrency
	d := g.evaluate(&stubStats{short: Stats{Count: 10, CPUMean: 60}})
	if d.MaxConcurrency != cfg.baseConcurrency() {
		t.Errorf("60%% cpu: concurrency=%d, want full %d", d.MaxConcurrency, cfg.baseConcurrency())
	}

	// CPU=75: above TierB (70), below TierC (85) -> 0.5x
	d = g.evaluate(&stubStats{short: Stats{Count: 10, CPUMean: 75}})
	want := cfg.baseConcurrency() / 2
	if d.MaxConcurrency != want {
		t.Errorf("75%% cpu: concurrency=%d, want %d", d.MaxConcurrency, want)
	}

	// CPU=90: above TierC (85) -> 0 (paused via tier path or dwell path)
	d = g.evaluate(&stubStats{short: Stats{Count: 10, CPUMean: 90}})
	if d.MaxConcurrency != 0 {
		t.Errorf("90%% cpu: concurrency=%d, want 0", d.MaxConcurrency)
	}
}

func TestGate_DiskBelowMinFree_PausesImmediately(t *testing.T) {
	cfg := DefaultConfig()
	cfg.DiskMinFreeMB = 5120
	clk := fixedClock(0)
	g := newGate(cfg, clk)

	stats := &stubStats{
		short:  Stats{Count: 5, CPUMean: 10},
		latest: Sample{DiskFreeB: 100 * 1024 * 1024}, // 100MB, way below 5GB
	}
	d := g.evaluate(stats)
	if d.State != StatePaused {
		t.Errorf("disk-low: state=%v want paused", d.State)
	}
	if d.Reason == "" || !contains(d.Reason, "disk") {
		t.Errorf("reason should mention disk: %q", d.Reason)
	}
}

func TestGate_LongWindowAboveCeiling_EnablesEmergencyCooldown(t *testing.T) {
	cfg := DefaultConfig()
	cfg.CPUHighLong = 60
	cfg.HighDwellSec = 1
	clk := fixedClock(0)
	g := newGate(cfg, clk)

	// long window mean 70% > CPUHighLong=60 should escalate
	stats := &stubStats{
		short:  Stats{Count: 30, CPUMean: 50},
		medium: Stats{Count: 120, CPUMean: 55},
		long:   Stats{Count: 720, CPUMean: 70},
	}
	clk.set(0)
	g.evaluate(stats)
	clk.set(2 * time.Second)
	d := g.evaluate(stats)
	if d.State != StateEmergencyCooldown {
		t.Errorf("state=%v want emergency_cooldown when long-window over ceiling", d.State)
	}
}

func TestGate_CooldownInjection_DutyCycle(t *testing.T) {
	cfg := DefaultConfig()
	cfg.CooldownEnabled = true
	cfg.CooldownTriggerMed = 60
	cfg.WorkPeriodMin = 50
	cfg.CooldownPeriodMin = 10
	clk := fixedClock(0)
	g := newGate(cfg, clk)

	stats := &stubStats{
		short:  Stats{Count: 30, CPUMean: 40},
		medium: Stats{Count: 120, CPUMean: 65}, // above trigger
	}

	// At t=0..50min: working
	clk.set(0)
	d := g.evaluate(stats)
	if d.State == StateEmergencyCooldown {
		t.Errorf("inside work window, should not be in cooldown")
	}

	// At t=51min: should have entered cooldown phase
	clk.set(51 * time.Minute)
	d = g.evaluate(stats)
	if d.State != StateEmergencyCooldown {
		t.Errorf("at 51m of duty cycle: state=%v want emergency_cooldown", d.State)
	}

	// At t=61min: cooldown ended, should be working again
	clk.set(61 * time.Minute)
	d = g.evaluate(stats)
	if d.State == StateEmergencyCooldown {
		t.Errorf("at 61m: should have exited cooldown")
	}
}

// --- helpers ---

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

type fixedClockImpl struct{ t time.Time }

func fixedClock(offsetSec int64) *fixedClockImpl {
	return &fixedClockImpl{t: time.Unix(1700000000, 0).Add(time.Duration(offsetSec) * time.Second)}
}

func (c *fixedClockImpl) Now() time.Time             { return c.t }
func (c *fixedClockImpl) set(d time.Duration)        { c.t = time.Unix(1700000000, 0).Add(d) }
```

- [ ] **Step 4.2: 跑测试,确认失败**

```bash
go test ./internal/node/budget/ -run Gate -v
```

Expected: 各种 `undefined`。

- [ ] **Step 4.3: 写 gate.go**

```go
package budget

import (
	"fmt"
	"time"
)

// clock interface allows injecting a fake clock in tests.
type clock interface {
	Now() time.Time
}

type realClock struct{}

func (realClock) Now() time.Time { return time.Now() }

// statsProvider is the read interface gate needs from sampler.
// Defined locally so tests can stub without depending on sampler.
type statsProvider interface {
	shortStats() Stats
	mediumStats() Stats
	longStats() Stats
	latest() Sample
}

// gate is a hysteretic state machine + cooldown injector.
// All decisions live here; sampler only collects data.
type gate struct {
	cfg Config
	clk clock

	// last transition timestamps (for dwell logic)
	highSince time.Time // when we first observed "high"; zero if not currently observing
	lowSince  time.Time // when we first observed "low"; zero if not currently observing

	// current state (sticky until state-machine transitions)
	current State

	// duty-cycle baseline: we anchor the work/cooldown cycle to this start time
	dutyAnchor time.Time
}

func newGate(cfg Config, clk clock) *gate {
	if clk == nil {
		clk = realClock{}
	}
	now := clk.Now()
	return &gate{
		cfg:        cfg,
		clk:        clk,
		current:    StateOpen,
		dutyAnchor: now,
	}
}

// baseConcurrency derives the "1.0x" concurrency from MaxGoroutineCount.
// We don't import config to avoid cycles; instead the caller (Budget)
// injects this via a setter. For pure-unit tests we use a default of 8.
func (c Config) baseConcurrency() int {
	// placeholder; real value comes from Budget at runtime via Config.tunedBase
	if c.tunedBase > 0 {
		return c.tunedBase
	}
	return 8
}

// We add a private hidden field via a sibling struct because Go yaml struct tags
// must stay clean. Keep tunedBase out of yaml.
// (Implemented as an embedded helper to avoid altering Config layout.)

// --- evaluate is the heart of the state machine ---

func (g *gate) evaluate(p statsProvider) Decision {
	now := g.clk.Now()
	short := p.shortStats()
	medium := p.mediumStats()
	long := p.longStats()
	latest := p.latest()

	// 1) Hard rule: disk free below floor → pause immediately, no dwell.
	if g.cfg.DiskMinFreeMB > 0 && latest.DiskFreeB > 0 {
		freeMB := latest.DiskFreeB / (1024 * 1024)
		if freeMB < g.cfg.DiskMinFreeMB {
			g.current = StatePaused
			return Decision{
				State:            StatePaused,
				MaxConcurrency:   0,
				NextEvaluationIn: 30 * time.Second,
				Reason:           fmt.Sprintf("disk free %dMB < floor %dMB", freeMB, g.cfg.DiskMinFreeMB),
			}
		}
	}

	// 2) Long-window guardrail: if 12h-mean exceeds ceiling, force emergency cooldown.
	if long.Count > 10 && long.CPUMean > g.cfg.CPUHighLong {
		// require dwell to avoid flap
		if g.highSince.IsZero() {
			g.highSince = now
		}
		if now.Sub(g.highSince) >= time.Duration(g.cfg.HighDwellSec)*time.Second {
			g.current = StateEmergencyCooldown
			return Decision{
				State:            StateEmergencyCooldown,
				MaxConcurrency:   0,
				NextEvaluationIn: 60 * time.Second,
				Reason: fmt.Sprintf("long-window CPU %.1f%% > ceiling %.1f%%, forced cooldown",
					long.CPUMean, g.cfg.CPUHighLong),
			}
		}
	}

	// 3) Cooldown duty-cycle: if medium-window mean above trigger, run work/rest cycle.
	if g.cfg.CooldownEnabled && medium.Count > 5 && medium.CPUMean > g.cfg.CooldownTriggerMed {
		cycleLen := time.Duration(g.cfg.WorkPeriodMin+g.cfg.CooldownPeriodMin) * time.Minute
		if cycleLen > 0 {
			into := now.Sub(g.dutyAnchor) % cycleLen
			workDur := time.Duration(g.cfg.WorkPeriodMin) * time.Minute
			if into >= workDur {
				return Decision{
					State:            StateEmergencyCooldown,
					MaxConcurrency:   0,
					NextEvaluationIn: cycleLen - into,
					Reason: fmt.Sprintf("duty-cycle cooldown (medium CPU %.1f%% > trigger %.1f%%)",
						medium.CPUMean, g.cfg.CooldownTriggerMed),
				}
			}
		}
	}

	// 4) Tier-based throttle on short-window mean (the main runtime knob).
	cpu := short.CPUMean
	mem := short.MemMean

	// memory hard pause
	if mem > g.cfg.MemHigh {
		if g.highSince.IsZero() {
			g.highSince = now
		}
		if now.Sub(g.highSince) >= time.Duration(g.cfg.HighDwellSec)*time.Second {
			g.current = StatePaused
			return Decision{
				State: StatePaused, MaxConcurrency: 0,
				NextEvaluationIn: 15 * time.Second,
				Reason:           fmt.Sprintf("memory %.1f%% > high %.1f%%", mem, g.cfg.MemHigh),
			}
		}
	}

	// CPU short-window pause threshold
	if cpu >= g.cfg.TierC {
		if g.highSince.IsZero() {
			g.highSince = now
		}
		if now.Sub(g.highSince) >= time.Duration(g.cfg.HighDwellSec)*time.Second {
			g.current = StatePaused
			return Decision{
				State: StatePaused, MaxConcurrency: 0,
				NextEvaluationIn: 10 * time.Second,
				Reason:           fmt.Sprintf("CPU %.1f%% ≥ tier-C %.1f%%", cpu, g.cfg.TierC),
			}
		}
	}

	// If currently paused, require low-dwell to recover.
	if g.current == StatePaused {
		recovering := cpu < g.cfg.CPULowShort && mem < g.cfg.MemLow
		if recovering {
			if g.lowSince.IsZero() {
				g.lowSince = now
			}
			if now.Sub(g.lowSince) >= time.Duration(g.cfg.LowDwellSec)*time.Second {
				g.current = StateOpen
				g.highSince = time.Time{}
				g.lowSince = time.Time{}
				// fall through to tier eval
			} else {
				return Decision{
					State: StatePaused, MaxConcurrency: 0,
					NextEvaluationIn: 5 * time.Second,
					Reason:           fmt.Sprintf("low-dwell %s/%s", now.Sub(g.lowSince), time.Duration(g.cfg.LowDwellSec)*time.Second),
				}
			}
		} else {
			g.lowSince = time.Time{}
			return Decision{
				State: StatePaused, MaxConcurrency: 0,
				NextEvaluationIn: 5 * time.Second,
				Reason:           "still above recovery threshold",
			}
		}
	}

	// reset highSince if we're back to OK
	if cpu < g.cfg.CPULowShort && mem < g.cfg.MemLow {
		g.highSince = time.Time{}
	}

	// Map cpu to tier-derived concurrency factor.
	factor := 1.0
	state := StateOpen
	switch {
	case cpu >= g.cfg.TierC:
		factor = 0
		state = StatePaused
	case cpu >= g.cfg.TierB:
		factor = 0.5
		state = StateThrottled
	case cpu >= g.cfg.TierA:
		factor = 1.0
		state = StateOpen
	default:
		factor = 1.0
		state = StateOpen
	}
	conc := int(float64(g.cfg.baseConcurrency()) * factor)
	if conc < 0 {
		conc = 0
	}
	g.current = state
	return Decision{
		State:            state,
		MaxConcurrency:   conc,
		NextEvaluationIn: 5 * time.Second,
		Reason:           fmt.Sprintf("cpu=%.1f%% mem=%.1f%% tier=%v", cpu, mem, state),
	}
}
```

⚠️ 注意: 上面的 `Config.baseConcurrency()` 引用了 `tunedBase`,但 Step 1.1 的 Config 里**没有**这个字段(yaml 不该有)。修复:在 `types.go` 末尾追加未导出字段:

```go
// internal: not loaded from yaml; injected by Budget at runtime.
// Sits at the end so the yaml struct tags above remain compact.
type configInternal = Config // placeholder type alias to attach methods

// We can't easily add an unexported field to Config without breaking yaml round-trip.
// Instead, store tunedBase on the Budget object and pass it in via a closure.
```

**修订决定:** 把 `baseConcurrency()` 改成接受参数,gate 通过外部注入:

修改 `gate.go` 的 evaluate 函数,把 `g.cfg.baseConcurrency()` 替换为字段 `g.baseConc int`,并在 `gate` struct 上加 `baseConc int` 字段 + `setBase(n int)` 方法。在 `newGate` 第二个参数后加可选的 base。

具体修改 gate.go 头部:

```go
type gate struct {
	cfg Config
	clk clock

	highSince  time.Time
	lowSince   time.Time
	current    State
	dutyAnchor time.Time

	baseConc int // injected by Budget; default 8
}

func newGate(cfg Config, clk clock) *gate {
	if clk == nil {
		clk = realClock{}
	}
	return &gate{
		cfg:        cfg,
		clk:        clk,
		current:    StateOpen,
		dutyAnchor: clk.Now(),
		baseConc:   8,
	}
}

func (g *gate) setBaseConcurrency(n int) {
	if n > 0 {
		g.baseConc = n
	}
}
```

并把 evaluate 中的 `g.cfg.baseConcurrency()` 替换为 `g.baseConc`。删掉 types.go 里多余的占位代码(`tunedBase`/`configInternal`)。

- [ ] **Step 4.4: 跑测试,确认通过**

```bash
go test ./internal/node/budget/ -run Gate -v
```

Expected: 7 个 PASS。

- [ ] **Step 4.5: Commit**

```bash
git add ScopeSentry-Scan/internal/node/budget/gate.go \
        ScopeSentry-Scan/internal/node/budget/gate_test.go
git commit -m "feat(budget): add hysteretic gate with cooldown duty-cycle"
```

---

## Task 5: Budget 单例(组装层 + 集成测试)

**Files:**
- Create: `ScopeSentry-Scan/internal/node/budget/budget.go`
- Test:   `ScopeSentry-Scan/internal/node/budget/budget_test.go`

- [ ] **Step 5.1: 写测试**

```go
package budget

import (
	"context"
	"testing"
	"time"
)

func TestBudget_StartAndDecisionFlow(t *testing.T) {
	cfg := DefaultConfig()
	cfg.SampleIntervalSec = 1
	cfg.ShortWindowSec = 2
	cfg.HighDwellSec = 1

	probe := &fakeProbe{cpu: 30, mem: 20, free: 100 << 30, load1: 0.5}
	b := NewBudget(cfg, WithProbe(probe), WithBaseConcurrency(10))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b.Start(ctx)

	// Wait for some samples
	time.Sleep(2500 * time.Millisecond)

	d := b.Decision()
	if d.State != StateOpen {
		t.Errorf("low-load state=%v want open", d.State)
	}
	if d.MaxConcurrency != 10 {
		t.Errorf("low-load conc=%d want 10", d.MaxConcurrency)
	}

	// Crank CPU up
	probe.cpu = 95
	time.Sleep(2500 * time.Millisecond)
	d = b.Decision()
	if d.MaxConcurrency != 0 {
		t.Errorf("high-load conc=%d want 0", d.MaxConcurrency)
	}
	if d.State != StatePaused {
		t.Errorf("high-load state=%v want paused", d.State)
	}
}

func TestBudget_SnapshotIncludesAllWindows(t *testing.T) {
	cfg := DefaultConfig()
	cfg.SampleIntervalSec = 1
	probe := &fakeProbe{cpu: 50, mem: 40}
	b := NewBudget(cfg, WithProbe(probe), WithBaseConcurrency(4))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b.Start(ctx)
	time.Sleep(1500 * time.Millisecond)

	snap := b.Snapshot()
	if snap.Short.Count == 0 {
		t.Errorf("short empty")
	}
	if snap.Decision.MaxConcurrency != 4 {
		t.Errorf("conc=%d", snap.Decision.MaxConcurrency)
	}
}
```

- [ ] **Step 5.2: 跑测试,确认失败**

```bash
go test ./internal/node/budget/ -run Budget -v
```

Expected: undefined NewBudget, WithProbe, WithBaseConcurrency.

- [ ] **Step 5.3: 写 budget.go**

```go
package budget

import (
	"context"
	"sync"
)

// Snapshot is what we report up to the heartbeat / control plane.
type Snapshot struct {
	Short    Stats    `json:"short"`
	Medium   Stats    `json:"medium"`
	Long     Stats    `json:"long"`
	Latest   Sample   `json:"latest"`
	Decision Decision `json:"decision"`
}

// Budget is the public face of this package. Wire it in once at startup.
type Budget struct {
	cfg     Config
	sampler *sampler
	gate    *gate

	mu       sync.RWMutex
	last     Decision
	cancel   context.CancelFunc
	probe    probe
}

// Option mutates a Budget at construction.
type Option func(*Budget)

// WithProbe replaces the default gopsutilProbe — used by tests.
func WithProbe(p probe) Option {
	return func(b *Budget) { b.probe = p }
}

// WithBaseConcurrency sets the 1.0x concurrency target.
func WithBaseConcurrency(n int) Option {
	return func(b *Budget) { b.gate.setBaseConcurrency(n) }
}

// NewBudget constructs (but does not start) a Budget.
func NewBudget(cfg Config, opts ...Option) *Budget {
	b := &Budget{
		cfg:  cfg,
		gate: newGate(cfg, realClock{}),
	}
	for _, o := range opts {
		o(b)
	}
	if b.probe == nil {
		b.probe = newGopsutilProbe(cfg.DiskMountPath)
	}
	b.sampler = newSampler(cfg, b.probe)
	return b
}

// Start launches the sampler + decision loop. Returns immediately.
func (b *Budget) Start(parent context.Context) {
	if !b.cfg.Enabled {
		return
	}
	ctx, cancel := context.WithCancel(parent)
	b.cancel = cancel

	go b.sampler.run(ctx)
	go b.decisionLoop(ctx)
}

// Stop is safe to call even if Start was never called.
func (b *Budget) Stop() {
	if b.cancel != nil {
		b.cancel()
	}
}

func (b *Budget) decisionLoop(ctx context.Context) {
	// Re-evaluate every short-window/2 to keep latency low without churn.
	import_time_dummy := 0
	_ = import_time_dummy

	delay := b.cfg.SampleIntervalSec
	if delay < 1 {
		delay = 5
	}

	t := tickerFromSeconds(delay)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			d := b.gate.evaluate(b.sampler)
			b.mu.Lock()
			b.last = d
			b.mu.Unlock()
		}
	}
}

// Decision returns the latest evaluation. If Budget is disabled, it returns
// an "always open" decision with the configured base concurrency.
func (b *Budget) Decision() Decision {
	if !b.cfg.Enabled {
		return Decision{
			State:          StateOpen,
			MaxConcurrency: b.gate.baseConc,
			Reason:         "budget disabled",
		}
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.last.MaxConcurrency == 0 && b.last.State == StateOpen {
		// haven't run yet; pretend open with base concurrency
		return Decision{
			State:          StateOpen,
			MaxConcurrency: b.gate.baseConc,
			Reason:         "warming up",
		}
	}
	return b.last
}

// Snapshot returns a full report for telemetry/heartbeat.
func (b *Budget) Snapshot() Snapshot {
	return Snapshot{
		Short:    b.sampler.shortStats(),
		Medium:   b.sampler.mediumStats(),
		Long:     b.sampler.longStats(),
		Latest:   b.sampler.latest(),
		Decision: b.Decision(),
	}
}
```

新建 `internal/node/budget/ticker.go`(把时间相关包装起来,方便将来注入 fake):

```go
package budget

import "time"

type ticker struct {
	t *time.Ticker
	C <-chan time.Time
}

func tickerFromSeconds(sec int) *ticker {
	if sec < 1 {
		sec = 1
	}
	tk := time.NewTicker(time.Duration(sec) * time.Second)
	return &ticker{t: tk, C: tk.C}
}

func (k *ticker) Stop() { k.t.Stop() }
```

⚠️ 删掉 budget.go 里多余的 `import_time_dummy` 占位行(草稿残留)。

- [ ] **Step 5.4: 跑测试,确认通过**

```bash
go build ./...
go test ./internal/node/budget/ -v -timeout 30s
```

Expected: 全部 PASS。

- [ ] **Step 5.5: Commit**

```bash
git add ScopeSentry-Scan/internal/node/budget/budget.go \
        ScopeSentry-Scan/internal/node/budget/budget_test.go \
        ScopeSentry-Scan/internal/node/budget/ticker.go
git commit -m "feat(budget): add Budget facade with options pattern"
```

---

## Task 6: 配置加载(从 env 读 BudgetConfig + 默认值兜底)

**Files:**
- Modify: `ScopeSentry-Scan/internal/config/config.go`

- [ ] **Step 6.1: 在 LoadConfig() 的 env 分支补 budget 字段**

修改 `internal/config/config.go` 的 `LoadConfig` 函数,在 `Interactsh` 块之后追加:

```go
			Interactsh: global.InteractshConfig{
				URL:   getEnv("INTERACTSH_URL", ""),
				Token: getEnv("INTERACTSH_TOKEN", ""),
			},
			Budget: global.BudgetConfig{
				Enabled:            getEnvBool("BUDGET_ENABLED", true),
				SampleIntervalSec:  getEnvInt("BUDGET_SAMPLE_SEC", 5),
				ShortWindowSec:     getEnvInt("BUDGET_SHORT_SEC", 30),
				MediumWindowSec:    getEnvInt("BUDGET_MEDIUM_SEC", 3600),
				LongWindowSec:      getEnvInt("BUDGET_LONG_SEC", 43200),
				CPUHighShort:       getEnvFloat("CPU_HIGH_SHORT", 85),
				CPULowShort:        getEnvFloat("CPU_LOW_SHORT", 65),
				CPUHighMedium:      getEnvFloat("CPU_HIGH_MEDIUM", 70),
				CPULowMedium:       getEnvFloat("CPU_LOW_MEDIUM", 50),
				CPUHighLong:        getEnvFloat("CPU_HIGH_LONG", 60),
				CPULowLong:         getEnvFloat("CPU_LOW_LONG", 45),
				MemHigh:            getEnvFloat("MEM_HIGH", 85),
				MemLow:             getEnvFloat("MEM_LOW", 70),
				DiskMinFreeMB:      int64(getEnvInt("DISK_MIN_FREE_MB", 5120)),
				HighDwellSec:       getEnvInt("BUDGET_HIGH_DWELL_SEC", 30),
				LowDwellSec:        getEnvInt("BUDGET_LOW_DWELL_SEC", 60),
				CooldownEnabled:    getEnvBool("COOLDOWN_ENABLED", true),
				WorkPeriodMin:      getEnvInt("WORK_PERIOD_MIN", 50),
				CooldownPeriodMin:  getEnvInt("COOLDOWN_PERIOD_MIN", 10),
				CooldownTriggerMed: getEnvFloat("COOLDOWN_TRIGGER_MED", 65),
				TierA:              getEnvFloat("TIER_A", 50),
				TierB:              getEnvFloat("TIER_B", 70),
				TierC:              getEnvFloat("TIER_C", 85),
				DiskMountPath:      getEnv("DISK_MOUNT_PATH", ""),
			},
		}
```

并在文件末尾追加辅助函数:

```go
func getEnvInt(key string, def int) int {
	v, ok := os.LookupEnv(key)
	if !ok {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func getEnvFloat(key string, def float64) float64 {
	v, ok := os.LookupEnv(key)
	if !ok {
		return def
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return def
	}
	return f
}

func getEnvBool(key string, def bool) bool {
	v, ok := os.LookupEnv(key)
	if !ok {
		return def
	}
	switch v {
	case "1", "true", "TRUE", "True", "yes":
		return true
	case "0", "false", "FALSE", "False", "no":
		return false
	default:
		return def
	}
}
```

并在 import 块加 `"strconv"`。

- [ ] **Step 6.2: 处理 yaml 模式的兜底**

`LoadConfig` 当读到现有 yaml 时,直接用 yaml 里的 budget(缺字段=零值)。零值 `Enabled=false` 会让 budget 整体禁用,但旧的 yaml 没这字段就会变零值——这违反"默认安全"原则。

解决: 在 yaml 路径之后立即填默认值兜底。在 `LoadConfig` 函数里,yaml 分支(`global.FirstRun = false` 那一支)的 `ReadYAMLFile` 之后追加:

```go
		if err := utils.Tools.ReadYAMLFile(global.ConfigPath, &global.AppConfig); err != nil {
			return err
		}
		// Backfill budget defaults if absent — safer than running unbounded.
		applyBudgetDefaults(&global.AppConfig.Budget)
```

并新增函数:

```go
func applyBudgetDefaults(b *global.BudgetConfig) {
	if b.SampleIntervalSec == 0 {
		b.Enabled = true
		b.SampleIntervalSec = 5
		b.ShortWindowSec = 30
		b.MediumWindowSec = 3600
		b.LongWindowSec = 43200
		b.CPUHighShort = 85
		b.CPULowShort = 65
		b.CPUHighMedium = 70
		b.CPULowMedium = 50
		b.CPUHighLong = 60
		b.CPULowLong = 45
		b.MemHigh = 85
		b.MemLow = 70
		b.DiskMinFreeMB = 5120
		b.HighDwellSec = 30
		b.LowDwellSec = 60
		b.CooldownEnabled = true
		b.WorkPeriodMin = 50
		b.CooldownPeriodMin = 10
		b.CooldownTriggerMed = 65
		b.TierA = 50
		b.TierB = 70
		b.TierC = 85
	}
}
```

- [ ] **Step 6.3: 编译**

```bash
cd ScopeSentry-Scan && go build ./...
```

Expected: 无错误。

- [ ] **Step 6.4: Commit**

```bash
git add ScopeSentry-Scan/internal/config/config.go
git commit -m "feat(budget): load BudgetConfig from env with safe defaults"
```

---

## Task 7: 启动 Budget 单例 + 心跳上报

**Files:**
- Modify: `ScopeSentry-Scan/internal/node/node.go`
- Modify: `ScopeSentry-Scan/cmd/ScopeSentry/main.go`
- Create: `ScopeSentry-Scan/internal/node/node_budget.go`(新文件,只暴露 Budget 单例)

- [ ] **Step 7.1: 创建 node_budget.go**

```go
package node

import (
	"context"
	"github.com/Autumn-27/ScopeSentry-Scan/internal/config"
	"github.com/Autumn-27/ScopeSentry-Scan/internal/global"
	"github.com/Autumn-27/ScopeSentry-Scan/internal/node/budget"
)

// CurrentBudget is the global budget tracker. Initialized in StartBudget()
// from main(). nil before StartBudget runs — callers must check.
var CurrentBudget *budget.Budget

// StartBudget translates the yaml-shaped BudgetConfig into runtime config
// and starts the tracker.
func StartBudget(ctx context.Context) {
	cfg := budget.Config{
		Enabled:            global.AppConfig.Budget.Enabled,
		SampleIntervalSec:  global.AppConfig.Budget.SampleIntervalSec,
		ShortWindowSec:     global.AppConfig.Budget.ShortWindowSec,
		MediumWindowSec:    global.AppConfig.Budget.MediumWindowSec,
		LongWindowSec:      global.AppConfig.Budget.LongWindowSec,
		CPUHighShort:       global.AppConfig.Budget.CPUHighShort,
		CPULowShort:        global.AppConfig.Budget.CPULowShort,
		CPUHighMedium:      global.AppConfig.Budget.CPUHighMedium,
		CPULowMedium:       global.AppConfig.Budget.CPULowMedium,
		CPUHighLong:        global.AppConfig.Budget.CPUHighLong,
		CPULowLong:         global.AppConfig.Budget.CPULowLong,
		MemHigh:            global.AppConfig.Budget.MemHigh,
		MemLow:             global.AppConfig.Budget.MemLow,
		DiskMinFreeMB:      global.AppConfig.Budget.DiskMinFreeMB,
		HighDwellSec:       global.AppConfig.Budget.HighDwellSec,
		LowDwellSec:        global.AppConfig.Budget.LowDwellSec,
		CooldownEnabled:    global.AppConfig.Budget.CooldownEnabled,
		WorkPeriodMin:      global.AppConfig.Budget.WorkPeriodMin,
		CooldownPeriodMin:  global.AppConfig.Budget.CooldownPeriodMin,
		CooldownTriggerMed: global.AppConfig.Budget.CooldownTriggerMed,
		TierA:              global.AppConfig.Budget.TierA,
		TierB:              global.AppConfig.Budget.TierB,
		TierC:              global.AppConfig.Budget.TierC,
		DiskMountPath:      pickDiskPath(),
	}

	base := config.ModulesConfig.MaxGoroutineCount
	if base <= 0 {
		base = 8
	}
	CurrentBudget = budget.NewBudget(cfg, budget.WithBaseConcurrency(base))
	CurrentBudget.Start(ctx)
}

func pickDiskPath() string {
	if p := global.AppConfig.Budget.DiskMountPath; p != "" {
		return p
	}
	return global.AbsolutePath
}
```

- [ ] **Step 7.2: 修改 main.go,在 BootstrapNodeRuntime 之前启动 budget**

修改 `cmd/ScopeSentry/main.go` 第 110 行附近:

```go
	// 启动资源预算追踪 (P-1 节点保命)
	budgetCtx, budgetCancel := context.WithCancel(context.Background())
	defer budgetCancel()
	node.StartBudget(budgetCtx)

	err = startup.BootstrapNodeRuntime(node.RegisterOnce, func(started chan<- struct{}) {
		close(started)
		node.Heartbeat()
	}, ...)
```

并在 import 块加 `"context"`(如果没有的话)。

- [ ] **Step 7.3: 修改 node.go 的 updateHeartbeat 函数,加 budget 字段**

修改 `internal/node/node.go::updateHeartbeat`:

```go
func updateHeartbeat() error {
	key := "node:" + global.AppConfig.NodeName
	cpuNum, memNum := utils.Tools.GetSystemUsage()
	run, fin := handler.TaskHandle.GetRunFin()
	nodeInfo := map[string]interface{}{
		"updateTime": utils.Tools.GetTimeNow(),
		"cpuNum":     cpuNum,
		"memNum":     memNum,
		"maxTaskNum": config.ModulesConfig.MaxGoroutineCount,
		"running":    run,
		"finished":   fin,
		"state":      global.AppConfig.State,
		"version":    global.VERSION,
	}

	// Budget telemetry (only if tracker started)
	if CurrentBudget != nil {
		snap := CurrentBudget.Snapshot()
		nodeInfo["budgetState"] = snap.Decision.State.String()
		nodeInfo["budgetReason"] = snap.Decision.Reason
		nodeInfo["budgetMaxConc"] = snap.Decision.MaxConcurrency
		nodeInfo["cpuMeanShort"] = snap.Short.CPUMean
		nodeInfo["cpuMeanMed"] = snap.Medium.CPUMean
		nodeInfo["cpuMeanLong"] = snap.Long.CPUMean
		nodeInfo["memMeanShort"] = snap.Short.MemMean
		nodeInfo["diskFreeMB"] = snap.Latest.DiskFreeB / (1024 * 1024)
	}

	return redis.RedisClient.HMSet(context.Background(), key, nodeInfo)
}
```

- [ ] **Step 7.4: 编译**

```bash
cd ScopeSentry-Scan && go build ./...
```

Expected: 无错误。

- [ ] **Step 7.5: Commit**

```bash
git add ScopeSentry-Scan/internal/node/node_budget.go \
        ScopeSentry-Scan/internal/node/node.go \
        ScopeSentry-Scan/cmd/ScopeSentry/main.go
git commit -m "feat(budget): wire Budget tracker into startup and heartbeat"
```

---

## Task 8: 任务循环消费 Decision(关键闭环!)

**Files:**
- Modify: `ScopeSentry-Scan/internal/task/task.go`

- [ ] **Step 8.1: 在 RunRedisTask 循环开头加 gate check**

修改 `internal/task/task.go::RunRedisTask`,把现有的 ticker 逻辑改成:

```go
// RunRedisTask 从redis中获取任务
func RunRedisTask() {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		// Resource gate: skip pickup if budget says don't.
		if node.CurrentBudget != nil {
			d := node.CurrentBudget.Decision()
			if d.MaxConcurrency == 0 {
				logger.SlogInfoLocal(fmt.Sprintf("[budget] skip pickup: %s (%s)", d.State, d.Reason))
				continue
			}
			// Limit how many tasks we pop in this tick (basic backpressure).
			// Existing logic doesn't batch — but if it did, we'd cap to d.MaxConcurrency.
		}

		TaskNodeName := "NodeTask:" + global.AppConfig.NodeName
		exists, err := redis.RedisClient.Exists(context.Background(), TaskNodeName)
		if err != nil {
			logger.SlogError(fmt.Sprintf("PopTaskId GetTask info error: %v", err))
			continue
		}
		if !exists {
			continue
		}
		// ... existing body unchanged from here ...
	}
}
```

⚠️ 注意: 因为 task 包要 import node 包,而 node 包目前不 import task 包,所以这个方向 OK。但要确认无循环依赖:

```bash
cd ScopeSentry-Scan
go list -deps ./internal/node/... | grep "internal/task" || echo "no cycle"
```

Expected: `no cycle`。

如果存在循环(node 已经依赖 task),则把 Decision 通过中介包暴露:新建 `internal/node/budget/access.go` 提供 `GetDecisionFn func() Decision`,task 包直接 import budget 包(更简单)。

修订: 让 task.go 直接 import `internal/node/budget` + `internal/node`,**只取决于哪个包有 budget 实例**。最干净的方式:

- `internal/node/budget` 是纯逻辑包,谁都可以 import
- `internal/node/node_budget.go` 持有 `CurrentBudget`,task 包 import `internal/node` 拿
- 只要 node 不 import task(确认了不依赖),就没循环

确认:

```bash
grep -rn "Autumn-27/ScopeSentry-Scan/internal/task" /Users/york/ai-proctet/info-scan/ScopeSentry-Scan/internal/node/
```

如果输出空,继续。如果有,把 `CurrentBudget` 暴露移到第三个包(如 `internal/budgetref/budgetref.go`),让 node + task 都 import 它。

- [ ] **Step 8.2: 编译**

```bash
go build ./...
```

Expected: 无错误。

- [ ] **Step 8.3: 写集成测试(模拟 budget 关闸 → task 跳过)**

`internal/task/task_test.go` 暂时只测构造,真正端到端测试在 Task 9。这步只确认 import + 编译通过。

- [ ] **Step 8.4: Commit**

```bash
git add ScopeSentry-Scan/internal/task/task.go
git commit -m "feat(budget): task loop honors budget decision before pickup"
```

---

## Task 9: 端到端验证(本机 stress 测试)

**Files:**
- Create: `ScopeSentry-Scan/scripts/test-budget-stress.sh`

- [ ] **Step 9.1: 写 stress 测试脚本**

```bash
#!/usr/bin/env bash
# scripts/test-budget-stress.sh
# Manual smoke test: run scanner, push it via stress-ng, watch budget state in Redis.
set -euo pipefail

if ! command -v stress-ng >/dev/null; then
	echo "Install stress-ng first: apt install stress-ng / brew install stress-ng"
	exit 1
fi

NODE_NAME="${NODE_NAME:-budget-test-$(hostname)}"
echo "==> starting scanner with NodeName=$NODE_NAME"
echo "    Budget envs: BUDGET_SHORT_SEC=15 CPU_HIGH_SHORT=70 BUDGET_HIGH_DWELL_SEC=10"
echo

# Watch loop in another terminal:
echo "In another terminal, run:"
echo "  watch -n 2 'redis-cli -a \"\$REDIS_PASSWORD\" HGETALL node:$NODE_NAME | grep -E \"budget|cpu|mem\"'"
echo
echo "==> Step 1: baseline (no load)"
sleep 60

echo "==> Step 2: stress 4 cores at 100% for 90s"
stress-ng --cpu 4 --timeout 90s &
STRESS_PID=$!
sleep 90
wait $STRESS_PID

echo "==> Step 3: cooldown observation (45s)"
sleep 45

echo "==> Verify in Redis:"
echo "    expect budgetState transitions: open → throttled → paused → open"
```

```bash
chmod +x ScopeSentry-Scan/scripts/test-budget-stress.sh
```

- [ ] **Step 9.2: 走通本地最小验证(无需 docker,直接跑二进制)**

```bash
cd ScopeSentry-Scan
go build -o /tmp/scopesentry-scan ./cmd/ScopeSentry/

# 准备好 mongo + redis 已经跑着, 然后:
NodeName=budget-local \
MONGODB_IP=127.0.0.1 MONGODB_USER=root MONGODB_PASSWORD=xxx \
REDIS_IP=127.0.0.1 REDIS_PASSWORD=xxx \
BUDGET_SAMPLE_SEC=2 BUDGET_SHORT_SEC=10 BUDGET_HIGH_DWELL_SEC=5 \
CPU_HIGH_SHORT=50 \
/tmp/scopesentry-scan
```

在另一个终端:

```bash
# 跑空的扫描器, 查 redis 心跳
watch -n 2 "redis-cli -a xxx HMGET node:budget-local budgetState budgetMaxConc cpuMeanShort"
```

阈值故意设低(50%),节点空跑也会被偶发瞬时 CPU 波动触发 throttled 状态。再用 `stress-ng --cpu 2 --timeout 60s` 压一下,应该看到状态变化。

预期看到的状态序列:
1. 启动 0~10s: `budgetState=open` (warming up)
2. 启动 10s+: `budgetState=open` `cpuMeanShort=` 实际值
3. stress 期间: `cpuMeanShort` 上升到 ~80-100%
4. dwell 5s 后: `budgetState=throttled` 或 `paused`,`budgetMaxConc=4 → 0`
5. stress 结束 60s 后: `budgetState=open`

- [ ] **Step 9.3: 记录证据(截图或 log)放到 PR 描述**

```bash
# 把状态变化用 redis-cli 抓下来
redis-cli -a xxx --json HGETALL node:budget-local > /tmp/budget-evidence-$(date +%s).json
```

- [ ] **Step 9.4: Commit**

```bash
git add ScopeSentry-Scan/scripts/test-budget-stress.sh
git commit -m "test(budget): add stress smoke script"
```

---

## Task 10: 上线 + 观察

**Files:** 无代码修改,纯部署 + 观察。

- [ ] **Step 10.1: 灰度部署到一台 VPS**

选最不重要的那台 VPS(或者就是你现在被频繁关机的那台):

```bash
# SSH 上去
ssh root@vps-1

# 拉新镜像 (需要先 push 到 Dockerhub: docker push autumn27/scopesentry-scan:budget)
docker pull autumn27/scopesentry-scan:budget

# 替换运行
docker stop scopesentry-scan
docker rm scopesentry-scan
docker run -d --name scopesentry-scan \
  --network host --restart always \
  --env-file /opt/scopesentry-node/.env \
  -e BUDGET_ENABLED=true \
  -e CPU_HIGH_LONG=55 \
  -e WORK_PERIOD_MIN=45 \
  -e COOLDOWN_PERIOD_MIN=15 \
  autumn27/scopesentry-scan:budget
```

`CPU_HIGH_LONG=55` + `WORK_PERIOD_MIN=45 / COOLDOWN_PERIOD_MIN=15`(占空比 75%)是**比默认更保守**的配置,确保不踩 12h 关机线。

- [ ] **Step 10.2: 在控制台 redis 看 24 小时数据**

```bash
# 在中心端 redis 上
while true; do
  redis-cli -a xxx HMGET node:vps-1 budgetState cpuMeanLong budgetMaxConc \
    | xargs -L 1 echo "$(date '+%H:%M:%S') -"
  sleep 60
done | tee /tmp/vps-1-24h.log
```

**验收标准:**
1. 节点在过去 24 小时内**没有被 VPS 强制关机**
2. `cpuMeanLong` 始终 < `CPU_HIGH_LONG` (55%)
3. `budgetState` 在 `open` ↔ `throttled` ↔ `emergency_cooldown` 之间合理切换,无死锁
4. 任务总数(`finished` 字段)在每天的 cooldown 窗口期内不增长,在工作期增长

如果上述都满足 → 上线到所有节点。

- [ ] **Step 10.3: 改默认配置,推到所有节点**

更新 control plane 上的"节点新增"默认 env 模板,把 budget 默认值固化。

---

## 验收

✅ **Task 1-2:** Ring buffer 单元测试 4 个 PASS
✅ **Task 3:** Sampler 单元测试 2 个 PASS
✅ **Task 4:** Gate 状态机测试 7 个 PASS(覆盖所有阈值穿越 + cooldown 注入)
✅ **Task 5:** Budget 集成测试 2 个 PASS
✅ **Task 6-7:** `go build ./...` 通过,启动后 redis 心跳能看到 `budgetState/cpuMeanShort/...` 字段
✅ **Task 8:** stress-ng 压测时,任务循环停止 pickup,日志有 `[budget] skip pickup` 记录
✅ **Task 9:** 单机端到端验证脚本通过
✅ **Task 10:** 灰度 24 小时不被 VPS 关机

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| gopsutil 在某些 VPS 内核版本上 `cpu.Percent(1s, false)` 卡死 | sampler 用 `time.NewTicker` 而非阻塞 sleep;采样错误返回时跳过该 tick 不污染窗口 |
| 长窗口在节点重启后丢失 → 刚启动就过激 | 用 medium 窗口 cooldown 触发 + tier 阶梯,不依赖 long 窗口的精确性 |
| 12h ring buffer 占内存(720 个 Sample × ~80 字节 ≈ 56KB) | 可接受,不优化 |
| `MaxGoroutineCount` 是全局静态值,gate 动态调它会冲突 | 本计划中 gate 只**对外报告**期望并发,不直接改 `MaxGoroutineCount`;task 循环只用它做"pop / 不 pop"决策,真正的 module-level 并发还由原有的 pool 机制管 |
| 同一节点重启后 dutyAnchor 重置 → 占空比重新计算 | 接受;反而是好事(重启意味着已经"被迫休息"过了) |
| Budget 关闸期间任务积压在 `NodeTask:{NodeName}` 队列 → 节点恢复后一次性吃下 | P1 改 pull 模型后自动消失;P-1 期暂时容忍,日志监控积压长度 |

---

## 与后续 Plans 的衔接

- **Plan 2 (HTTP 一键上线)**:`enroll` 接口返回的 `budget` 配置直接写到 `.env`,节点首次启动即按预算限流 → P0 落地后,**新节点天生自带保命**。
- **Plan 3 (Pull + Lease)**:Budget.Decision() 直接控制 XREADGROUP 的 COUNT 参数(高水位时 COUNT=0),消除 push 模式的竞态。

---

## Self-Review

**Spec coverage:**
- 多窗口预算 → Task 2-3 ✅
- 滞后窗 → Task 4 (HighDwellSec/LowDwellSec) ✅
- 渐进退避(tier) → Task 4 (TierA/B/C) ✅
- Cooldown 注入 → Task 4 (TestGate_CooldownInjection_DutyCycle) ✅
- 多维度(CPU+Mem+磁盘+Load) → Task 4 (DiskMinFreeMB/MemHigh) ✅
- 长窗口保命 → Task 4 (TestGate_LongWindowAboveCeiling) ✅
- 心跳上报 → Task 7 ✅
- 任务循环闭环 → Task 8 ✅
- 真实 VPS 验收 → Task 10 ✅

**Placeholder scan:** 无 TBD/TODO,代码块完整。Step 5.3 中的 `import_time_dummy` 残留已在同步备注中要求删除。

**Type consistency:** `Decision.MaxConcurrency` 在所有任务中一致;`State` 枚举在 types.go 单点定义;`Stats` 在 ringbuf.go / sampler.go / gate.go 都引用同一定义。

---

## 下一步

完成 Plan 1 上线 + 24 小时验证后,进入 **Plan 2 (HTTP 一键上线)**。
