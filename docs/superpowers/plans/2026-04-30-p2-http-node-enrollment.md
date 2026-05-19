# P0+C3+Enrollment HTTP 一键上线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在中心控制端实现"管理员点一下生成命令 → SSH 到任意 Linux VPS 粘贴一行 curl → 节点 60 秒内自动上线"的部署体验。同时把扫描节点的能力声明(只跑哪些 module)、per-node 数据库凭据(MongoDB user + Redis ACL)、enrollment token(15 分钟一次性 + IP 绑定)三件事一次性做完。

**Architecture:** 中心端加 4 个 REST 接口(token 生成、token 列表、enroll、install-node.sh 静态分发)+ 2 个服务层(MongoDB user provisioner、Redis ACL provisioner)+ 1 个 dispatcher 过滤器(只把节点能力范围内的任务推给该节点)。前端在节点页加"添加节点"按钮 + 弹窗。扫描器侧加 capability 上报。安装脚本走 HTTPS,不带凭据,**所有敏感信息只在 token-换-凭据这一跳传输**。

**Tech Stack:** 服务端 Go 1.21+ / Gin / mongo-go-driver / go-redis v9 / 前端 Vue 3 + Element Plus(已有)+ TypeScript / Bash 5+ / curl + jq(脚本依赖)

**前置条件:** Plan 1 (P-1 资源预算) 已经合并;扫描器支持 `BUDGET_*` 环境变量。

---

## File Structure

### 中心端 (ScopeSentry)

| 文件 | 责任 |
|------|------|
| `internal/models/enroll_token.go` (新) | EnrollToken 结构 + collection 名 + 索引定义 |
| `internal/models/node_capabilities.go` (新) | Capability 枚举 + NodeBudgetTemplate |
| `internal/services/credentials/mongo_user.go` (新) | MongoDB createUser/dropUser,角色限定到 ScopeSentry DB |
| `internal/services/credentials/mongo_user_test.go` (新) | mocked mongo.Database 测试 |
| `internal/services/credentials/redis_acl.go` (新) | Redis ACL SETUSER / DELUSER,key 前缀 + 命令白名单 |
| `internal/services/credentials/redis_acl_test.go` (新) | 真 redis 集成测试(可选,可用 miniredis) |
| `internal/services/dispatcher/capability_filter.go` (新) | 给定 task module + 节点能力,返回是否可派 |
| `internal/services/dispatcher/capability_filter_test.go` (新) | 单元测试 |
| `internal/api/handlers/node/enroll.go` (新) | 4 个 handler: GenerateToken, ListTokens, Revoke, Enroll |
| `internal/api/handlers/node/enroll_test.go` (新) | handler 单元测试 |
| `internal/api/routes/node/node.go` (改) | 注册新路由 |
| `internal/api/routes/routes.go` (改) | 在 api group 之外注册 `GET /install-node.sh` 公开路由 |
| `assets/install-node.sh` (新) | 安装脚本(go embed 进二进制) |
| `internal/api/handlers/installer/installer.go` (新) | 服务 install-node.sh,替换占位符 `__CTRL_URL__` |
| `internal/api/handlers/installer/installer_test.go` (新) | 测试占位替换 + 缓存头 |

### 前端 (ScopeSentry-UI)

| 文件 | 责任 |
|------|------|
| `src/api/node/types.ts` (改) | 新增 EnrollToken / Capability / EnrollResponse 类型 |
| `src/api/node/index.ts` (改) | 新增 generateToken / listTokens / revokeToken API client |
| `src/views/Node/components/EnrollDialog.vue` (新) | "添加节点"弹窗 |
| `src/views/Node/components/CapabilityEditor.vue` (新) | 能力 checkbox 列表组件 |
| `src/views/Node/components/InstallCommandBox.vue` (新) | 命令复制框 + 倒计时 |
| `src/views/Node/Node.vue` (改) | 加按钮 + 集成弹窗 |

### 扫描器 (ScopeSentry-Scan)

| 文件 | 责任 |
|------|------|
| `internal/global/type.go` (改) | Config 加 Capabilities []string 字段 |
| `internal/config/config.go` (改) | 从 env `CAPABILITIES` 读(逗号分隔) |
| `internal/node/node.go` (改) | RegisterOnce 写 capabilities 到 hash |

---

## Task 1: EnrollToken 数据模型

**Files:**
- Create: `ScopeSentry/internal/models/enroll_token.go`
- Create: `ScopeSentry/internal/models/node_capabilities.go`

- [ ] **Step 1.1: 写 enroll_token.go**

```go
// Package models — EnrollToken is a one-shot, time-bound credential that lets
// a fresh VPS exchange itself for per-node DB credentials. Stored in the
// `node_enroll_tokens` collection. TTL index on ExpiresAt auto-cleans.
package models

import (
	"time"

	"go.mongodb.org/mongo-driver/bson/primitive"
)

const EnrollTokensCollection = "node_enroll_tokens"

// EnrollToken lifecycle:
//   1. Admin generates -> ConsumedAt is nil, ExpiresAt = now+15min
//   2. install-node.sh POSTs token -> server validates and atomically marks
//      ConsumedAt + ConsumedByIP, then issues credentials.
//   3. Once consumed (or expired), enrollment must use a fresh token.
type EnrollToken struct {
	ID            string             `bson:"_id"               json:"id"`
	CreatedAt     time.Time          `bson:"created_at"        json:"created_at"`
	ExpiresAt    time.Time          `bson:"expires_at"        json:"expires_at"`
	ConsumedAt    *time.Time         `bson:"consumed_at,omitempty" json:"consumed_at,omitempty"`
	ConsumedByIP  string             `bson:"consumed_by_ip,omitempty" json:"consumed_by_ip,omitempty"`
	BoundIP       string             `bson:"bound_ip,omitempty" json:"bound_ip,omitempty"` // optional pre-binding
	IntendedName  string             `bson:"intended_name"      json:"intended_name"`        // hint, can be overridden
	Capabilities  []string           `bson:"capabilities"       json:"capabilities"`
	BudgetTemplate string             `bson:"budget_template"   json:"budget_template"` // "default"|"conservative"|"aggressive"
	CreatedByUser primitive.ObjectID `bson:"created_by_user"   json:"created_by_user"`
	IssuedNodeID  string             `bson:"issued_node_id,omitempty" json:"issued_node_id,omitempty"` // set after consume
}

// IsValid checks expiry and consumption. Does NOT check IP binding (caller does).
func (t *EnrollToken) IsValid(now time.Time) bool {
	if t.ConsumedAt != nil {
		return false
	}
	if !t.ExpiresAt.IsZero() && now.After(t.ExpiresAt) {
		return false
	}
	return true
}
```

- [ ] **Step 1.2: 写 node_capabilities.go**

```go
package models

// Capability is a stable string id for a scanner module.
// Keep in sync with scanner's plugin Module ids — see ScopeSentry-Scan
// internal/plugins/plugins.go::RegisterPlugin calls.
type Capability string

const (
	CapSubdomainScan    Capability = "SubdomainScan"
	CapSubdomainTakeover Capability = "SubdomainTakeover"
	CapSkipCDN          Capability = "SkipCDN"
	CapPortScan         Capability = "PortScan"
	CapAssetMapping     Capability = "AssetMapping"
	CapWebFingerprint   Capability = "WebFingerprint"
	CapURLScan          Capability = "URLScan"
	CapWebCrawler       Capability = "WebCrawler"
	CapDirScan          Capability = "DirScan"
	CapVulScan          Capability = "VulScan"
	CapPassiveScan      Capability = "PassiveScan"
	CapPageMonitoring   Capability = "PageMonitoring"
)

// AllCapabilities returns every supported capability.
// Used by the UI to render the checkbox list.
func AllCapabilities() []Capability {
	return []Capability{
		CapSubdomainScan, CapSubdomainTakeover, CapSkipCDN,
		CapPortScan, CapAssetMapping,
		CapWebFingerprint, CapURLScan, CapWebCrawler, CapDirScan,
		CapVulScan, CapPassiveScan, CapPageMonitoring,
	}
}

// BudgetTemplate maps to env vars passed to the scanner.
type BudgetTemplate string

const (
	BudgetDefault      BudgetTemplate = "default"
	BudgetConservative BudgetTemplate = "conservative"
	BudgetAggressive   BudgetTemplate = "aggressive"
)

// EnvOverrides returns env vars to merge into the scanner container env.
// Conservative ≈ 12h-shutdown VPS safe.
func (b BudgetTemplate) EnvOverrides() map[string]string {
	switch b {
	case BudgetConservative:
		return map[string]string{
			"CPU_HIGH_LONG":      "55",
			"CPU_HIGH_MEDIUM":    "60",
			"CPU_HIGH_SHORT":     "75",
			"WORK_PERIOD_MIN":    "45",
			"COOLDOWN_PERIOD_MIN": "15",
		}
	case BudgetAggressive:
		return map[string]string{
			"CPU_HIGH_LONG":      "70",
			"CPU_HIGH_MEDIUM":    "80",
			"CPU_HIGH_SHORT":     "92",
			"WORK_PERIOD_MIN":    "55",
			"COOLDOWN_PERIOD_MIN": "5",
		}
	default:
		return map[string]string{} // budget package defaults are used
	}
}
```

- [ ] **Step 1.3: 写 collection 索引初始化函数**

在 `enroll_token.go` 末尾追加:

```go
import (
	"context"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// EnsureEnrollTokenIndexes creates the TTL index on ExpiresAt so expired
// tokens auto-purge after 1 day past expiry (kept for audit, then deleted).
func EnsureEnrollTokenIndexes(ctx context.Context, db *mongo.Database) error {
	col := db.Collection(EnrollTokensCollection)
	_, err := col.Indexes().CreateMany(ctx, []mongo.IndexModel{
		{
			Keys: bson.D{{Key: "expires_at", Value: 1}},
			Options: options.Index().
				SetExpireAfterSeconds(86400). // 24h after expiry, drop
				SetName("ttl_expires_at"),
		},
		{
			Keys:    bson.D{{Key: "created_by_user", Value: 1}, {Key: "created_at", Value: -1}},
			Options: options.Index().SetName("by_user"),
		},
	})
	return err
}
```

- [ ] **Step 1.4: 编译**

```bash
cd ScopeSentry && go build ./...
```

Expected: 无错误。

- [ ] **Step 1.5: Commit**

```bash
git add ScopeSentry/internal/models/enroll_token.go \
        ScopeSentry/internal/models/node_capabilities.go
git commit -m "feat(enroll): add EnrollToken model and capability enum"
```

---

## Task 2: MongoDB User Provisioner 服务

**Files:**
- Create: `ScopeSentry/internal/services/credentials/mongo_user.go`
- Create: `ScopeSentry/internal/services/credentials/mongo_user_test.go`

- [ ] **Step 2.1: 写测试**

```go
package credentials

import (
	"context"
	"errors"
	"testing"

	"go.mongodb.org/mongo-driver/bson"
)

// fakeRunner records executed commands; used to test command construction
// without spinning up a real Mongo.
type fakeRunner struct {
	commands []bson.D
	stub     func(cmd bson.D) error
}

func (f *fakeRunner) RunCommand(_ context.Context, cmd bson.D) error {
	f.commands = append(f.commands, cmd)
	if f.stub != nil {
		return f.stub(cmd)
	}
	return nil
}

func TestMongoProvisioner_CreateUser_BuildsCorrectCommand(t *testing.T) {
	runner := &fakeRunner{}
	p := NewMongoProvisioner(runner, "ScopeSentry")
	creds, err := p.CreateNodeUser(context.Background(), "node-abc")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if creds.Username != "node-abc" {
		t.Errorf("username=%q", creds.Username)
	}
	if len(creds.Password) < 24 {
		t.Errorf("password len=%d, want ≥ 24", len(creds.Password))
	}
	if creds.Database != "ScopeSentry" {
		t.Errorf("database=%q", creds.Database)
	}
	if len(runner.commands) != 1 {
		t.Fatalf("expected 1 command, got %d", len(runner.commands))
	}
	cmd := runner.commands[0]
	if cmd[0].Key != "createUser" || cmd[0].Value != "node-abc" {
		t.Errorf("first key createUser=%v, got %v=%v", "node-abc", cmd[0].Key, cmd[0].Value)
	}
	// password should not be present in plaintext anywhere except the pwd field
	hasPwd := false
	for _, e := range cmd {
		if e.Key == "pwd" {
			hasPwd = true
			break
		}
	}
	if !hasPwd {
		t.Error("createUser command missing pwd")
	}
}

func TestMongoProvisioner_CreateUser_PropagatesErrors(t *testing.T) {
	runner := &fakeRunner{stub: func(_ bson.D) error { return errors.New("auth failure") }}
	p := NewMongoProvisioner(runner, "ScopeSentry")
	_, err := p.CreateNodeUser(context.Background(), "node-abc")
	if err == nil || err.Error() == "" {
		t.Error("expected propagated error")
	}
}

func TestMongoProvisioner_DropUser_BuildsCorrectCommand(t *testing.T) {
	runner := &fakeRunner{}
	p := NewMongoProvisioner(runner, "ScopeSentry")
	if err := p.DropNodeUser(context.Background(), "node-abc"); err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(runner.commands) != 1 {
		t.Fatalf("expected 1 command")
	}
	cmd := runner.commands[0]
	if cmd[0].Key != "dropUser" || cmd[0].Value != "node-abc" {
		t.Errorf("dropUser command malformed: %+v", cmd)
	}
}

func TestMongoProvisioner_DropUser_IgnoresUserNotFound(t *testing.T) {
	runner := &fakeRunner{stub: func(_ bson.D) error { return errors.New("UserNotFound: User node-abc@ScopeSentry not found") }}
	p := NewMongoProvisioner(runner, "ScopeSentry")
	if err := p.DropNodeUser(context.Background(), "node-abc"); err != nil {
		t.Errorf("UserNotFound should be ignored, got %v", err)
	}
}
```

- [ ] **Step 2.2: 跑测试,确认失败**

```bash
go test ./internal/services/credentials/ -run Mongo -v
```

Expected: undefined symbols.

- [ ] **Step 2.3: 写实现**

```go
// Package credentials provisions per-node DB credentials for scanner nodes.
// Each scanner node gets its own MongoDB user (limited to ScopeSentry DB)
// and Redis ACL user (key prefix and command whitelist), so a single
// compromised node cannot read the entire database. Per-node creds also
// allow surgical revocation when a node is decommissioned.
package credentials

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strings"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
)

// commandRunner is the narrow interface MongoProvisioner needs.
// In production it's a wrapper around *mongo.Database; tests pass a fake.
type commandRunner interface {
	RunCommand(ctx context.Context, cmd bson.D) error
}

// NodeCredentials are returned to the scanner during enrollment.
type NodeCredentials struct {
	Username string
	Password string
	Database string
}

type MongoProvisioner struct {
	runner   commandRunner
	database string // the DB scoped role applies to (ScopeSentry)
}

func NewMongoProvisioner(runner commandRunner, database string) *MongoProvisioner {
	return &MongoProvisioner{runner: runner, database: database}
}

// CreateNodeUser creates a user with readWrite on the ScopeSentry DB only.
// The returned password is the only chance to retrieve it; we don't log or
// re-fetch it.
func (p *MongoProvisioner) CreateNodeUser(ctx context.Context, username string) (NodeCredentials, error) {
	pwd, err := generatePassword(32)
	if err != nil {
		return NodeCredentials{}, fmt.Errorf("generate pwd: %w", err)
	}
	cmd := bson.D{
		{Key: "createUser", Value: username},
		{Key: "pwd", Value: pwd},
		{Key: "roles", Value: bson.A{
			bson.D{{Key: "role", Value: "readWrite"}, {Key: "db", Value: p.database}},
		}},
	}
	if err := p.runner.RunCommand(ctx, cmd); err != nil {
		return NodeCredentials{}, fmt.Errorf("createUser: %w", err)
	}
	return NodeCredentials{
		Username: username,
		Password: pwd,
		Database: p.database,
	}, nil
}

// DropNodeUser removes the user. UserNotFound is treated as success
// (idempotent: re-decommissioning a missing user shouldn't fail the API).
func (p *MongoProvisioner) DropNodeUser(ctx context.Context, username string) error {
	cmd := bson.D{{Key: "dropUser", Value: username}}
	if err := p.runner.RunCommand(ctx, cmd); err != nil {
		if strings.Contains(err.Error(), "UserNotFound") {
			return nil
		}
		return fmt.Errorf("dropUser: %w", err)
	}
	return nil
}

func generatePassword(byteLen int) (string, error) {
	b := make([]byte, byteLen)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	// URL-safe; no padding so passwords don't end in '='.
	return strings.TrimRight(base64.URLEncoding.EncodeToString(b), "="), nil
}

// --- production runner adapter ---

type adminRunner struct{ db *mongo.Database }

// NewAdminRunner wraps a *mongo.Database (typically `client.Database("admin")`).
// createUser/dropUser must be issued against the admin DB or against the
// target DB itself. We use admin DB for clarity; ensure the connection
// auth context has clusterAdmin or userAdminAnyDatabase.
func NewAdminRunner(db *mongo.Database) commandRunner {
	return &adminRunner{db: db}
}

func (a *adminRunner) RunCommand(ctx context.Context, cmd bson.D) error {
	res := a.db.RunCommand(ctx, cmd)
	if err := res.Err(); err != nil {
		return err
	}
	// We don't decode the result; success is indicated by Err()==nil.
	return nil
}
```

- [ ] **Step 2.4: 跑测试,确认通过**

```bash
go test ./internal/services/credentials/ -run Mongo -v
```

Expected: 4 PASS。

- [ ] **Step 2.5: Commit**

```bash
git add ScopeSentry/internal/services/credentials/mongo_user.go \
        ScopeSentry/internal/services/credentials/mongo_user_test.go
git commit -m "feat(credentials): add MongoDB per-node user provisioner"
```

---

## Task 3: Redis ACL Provisioner

**Files:**
- Create: `ScopeSentry/internal/services/credentials/redis_acl.go`
- Create: `ScopeSentry/internal/services/credentials/redis_acl_test.go`

Redis ACL 比 Mongo 复杂——命令是字符串拼接,需要更仔细地测试。

- [ ] **Step 3.1: 写测试**

```go
package credentials

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// fakeRedisRunner records ACL commands as raw arg slices.
type fakeRedisRunner struct {
	commands [][]any
	stub     func(args []any) error
}

func (f *fakeRedisRunner) Do(_ context.Context, args ...any) error {
	f.commands = append(f.commands, args)
	if f.stub != nil {
		return f.stub(args)
	}
	return nil
}

func TestRedisACL_CreateUser_AppliesPrefixAndCommandWhitelist(t *testing.T) {
	runner := &fakeRedisRunner{}
	p := NewRedisACLProvisioner(runner)
	creds, err := p.CreateNodeUser(context.Background(), "node-abc")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if creds.Username != "node-abc" || len(creds.Password) < 24 {
		t.Errorf("creds bad: %+v", creds)
	}
	if len(runner.commands) != 1 {
		t.Fatalf("expected 1 ACL command, got %d", len(runner.commands))
	}
	args := runner.commands[0]
	// Reconstruct the command line for assertion convenience.
	parts := []string{}
	for _, a := range args {
		parts = append(parts, toString(a))
	}
	cmd := strings.Join(parts, " ")
	// Required clauses
	for _, want := range []string{
		"ACL", "SETUSER", "node-abc", "on",
		">",                  // password marker
		"resetkeys",
		"~node:node-abc:*",   // node hash key
		"~NodeTask:node-abc:*", // task list (legacy)
		"~scan:stream:*",     // streams (forward-compat for Plan 3)
		"-@all",
		"+ping", "+hset", "+hmset", "+hget", "+hgetall", "+hdel", "+expire",
		"+lpush", "+rpush", "+lpop", "+rpop", "+lrange", "+llen", "+lrem",
		"+sadd", "+smembers", "+sismember",
		"+set", "+get", "+del", "+exists",
		"+xadd", "+xack", "+xreadgroup", "+xpending", "+xclaim", "+xinfo",
		"+subscribe", "+publish",
	} {
		if !strings.Contains(cmd, want) {
			t.Errorf("ACL missing %q\nfull: %s", want, cmd)
		}
	}
	// Forbidden:
	for _, no := range []string{"+@all", "+config", "+flushdb", "+flushall", "+keys"} {
		if strings.Contains(cmd, no) {
			t.Errorf("ACL must NOT contain %q", no)
		}
	}
}

func TestRedisACL_DropUser_BuildsACLDelUser(t *testing.T) {
	runner := &fakeRedisRunner{}
	p := NewRedisACLProvisioner(runner)
	if err := p.DropNodeUser(context.Background(), "node-abc"); err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(runner.commands) != 1 {
		t.Fatalf("expected 1 command")
	}
	args := runner.commands[0]
	if toString(args[0]) != "ACL" || toString(args[1]) != "DELUSER" || toString(args[2]) != "node-abc" {
		t.Errorf("DELUSER malformed: %v", args)
	}
}

func TestRedisACL_DropUser_IgnoresUnknownUser(t *testing.T) {
	runner := &fakeRedisRunner{stub: func(_ []any) error { return errors.New("ERR User node-abc does not exist") }}
	p := NewRedisACLProvisioner(runner)
	if err := p.DropNodeUser(context.Background(), "node-abc"); err != nil {
		t.Errorf("non-existent user: %v", err)
	}
}

func toString(v any) string {
	switch s := v.(type) {
	case string:
		return s
	default:
		return ""
	}
}
```

- [ ] **Step 3.2: 跑测试,确认失败**

```bash
go test ./internal/services/credentials/ -run RedisACL -v
```

- [ ] **Step 3.3: 写实现**

```go
package credentials

import (
	"context"
	"fmt"
	"strings"

	"github.com/redis/go-redis/v9"
)

// redisRunner is the narrow interface RedisACLProvisioner needs.
// In production it wraps *redis.Client; tests pass a fake.
type redisRunner interface {
	Do(ctx context.Context, args ...any) error
}

type RedisACLProvisioner struct {
	runner redisRunner
}

func NewRedisACLProvisioner(runner redisRunner) *RedisACLProvisioner {
	return &RedisACLProvisioner{runner: runner}
}

// allowedKeyPatterns are the only keys this user may touch.
// Keep them tight: scoped to the node's own NodeName plus shared streams (Plan 3).
func keyPatterns(nodeName string) []string {
	return []string{
		"~node:" + nodeName + ":*",
		"~NodeTask:" + nodeName + ":*",
		"~refresh_config:" + nodeName,
		"~TaskInfo:*",      // task progress is shared
		"~scan:stream:*",   // pull-mode streams (forward-compat)
		"~scan:dlq:*",      // dead-letter queues
	}
}

// allowedCommands is the explicit whitelist of redis commands the scanner needs.
// Derived from internal/redis/redis.go in ScopeSentry-Scan.
var allowedCommands = []string{
	"ping",
	// hash ops
	"hset", "hmset", "hget", "hgetall", "hdel", "hexists", "expire",
	// list ops
	"lpush", "rpush", "lpop", "rpop", "lrange", "llen", "lrem",
	// set ops
	"sadd", "smembers", "sismember", "srem",
	// string ops
	"set", "get", "del", "exists", "incr", "decr",
	// pub/sub
	"subscribe", "psubscribe", "publish", "unsubscribe", "punsubscribe",
	// streams (Plan 3)
	"xadd", "xack", "xreadgroup", "xpending", "xclaim", "xinfo", "xlen", "xrange",
	// scripting (used by some libraries internally)
	"eval", "evalsha", "script",
}

// CreateNodeUser creates an ACL user with restricted key prefix + command whitelist.
// Idempotent in spirit: re-running with the same name overwrites the previous ACL
// (Redis behavior). Returns fresh password on every call.
func (p *RedisACLProvisioner) CreateNodeUser(ctx context.Context, username string) (NodeCredentials, error) {
	pwd, err := generatePassword(32)
	if err != nil {
		return NodeCredentials{}, err
	}

	args := []any{"ACL", "SETUSER", username, "on", ">" + pwd, "resetkeys"}
	for _, k := range keyPatterns(username) {
		args = append(args, k)
	}
	args = append(args, "-@all")
	for _, c := range allowedCommands {
		args = append(args, "+"+c)
	}

	if err := p.runner.Do(ctx, args...); err != nil {
		return NodeCredentials{}, fmt.Errorf("ACL SETUSER: %w", err)
	}
	return NodeCredentials{
		Username: username,
		Password: pwd,
	}, nil
}

func (p *RedisACLProvisioner) DropNodeUser(ctx context.Context, username string) error {
	if err := p.runner.Do(ctx, "ACL", "DELUSER", username); err != nil {
		// Redis returns 0 (not error) if user doesn't exist via DELUSER, but error
		// strings vary across versions; be lenient.
		msg := err.Error()
		if strings.Contains(msg, "does not exist") || strings.Contains(msg, "not found") {
			return nil
		}
		return fmt.Errorf("ACL DELUSER: %w", err)
	}
	return nil
}

// --- production runner adapter ---

type goRedisRunner struct{ c *redis.Client }

// NewGoRedisRunner wraps a go-redis client. The client must be authenticated
// as a user with `+@admin` (or default user with no ACL).
func NewGoRedisRunner(c *redis.Client) redisRunner {
	return &goRedisRunner{c: c}
}

func (g *goRedisRunner) Do(ctx context.Context, args ...any) error {
	cmd := g.c.Do(ctx, args...)
	return cmd.Err()
}
```

- [ ] **Step 3.4: 跑测试,确认通过**

```bash
go test ./internal/services/credentials/ -v
```

Expected: 7 个测试 PASS。

- [ ] **Step 3.5: Commit**

```bash
git add ScopeSentry/internal/services/credentials/redis_acl.go \
        ScopeSentry/internal/services/credentials/redis_acl_test.go
git commit -m "feat(credentials): add Redis ACL per-node user provisioner"
```

---

## Task 4: Capability Filter (调度层关键改动)

**Files:**
- Create: `ScopeSentry/internal/services/dispatcher/capability_filter.go`
- Create: `ScopeSentry/internal/services/dispatcher/capability_filter_test.go`

- [ ] **Step 4.1: 写测试**

```go
package dispatcher

import (
	"testing"

	"github.com/Autumn-27/ScopeSentry/internal/models"
)

func TestCanDispatch_AllowedWhenCapabilityMatches(t *testing.T) {
	caps := []string{string(models.CapSubdomainScan), string(models.CapPortScan)}
	if !CanDispatch(caps, string(models.CapSubdomainScan)) {
		t.Error("subdomain task should dispatch to subdomain-capable node")
	}
}

func TestCanDispatch_RejectedWhenMissing(t *testing.T) {
	caps := []string{string(models.CapSubdomainScan)}
	if CanDispatch(caps, string(models.CapVulScan)) {
		t.Error("vuln task should NOT dispatch to subdomain-only node")
	}
}

func TestCanDispatch_EmptyCapsFallsBackToAllowAll_OnlyDuringMigration(t *testing.T) {
	// Backward compat: scanner versions before this feature don't report
	// capabilities. To avoid breaking them mid-rollout, empty caps means
	// "accept everything" — but log a warning when this happens (caller
	// is responsible for that warning).
	if !CanDispatch(nil, string(models.CapVulScan)) {
		t.Error("empty caps should temporarily accept all (legacy compat)")
	}
	if !CanDispatch([]string{}, string(models.CapVulScan)) {
		t.Error("empty slice should temporarily accept all (legacy compat)")
	}
}

func TestPickEligibleNodes_FiltersByCapability(t *testing.T) {
	nodes := []NodeView{
		{Name: "n1", State: 1, Capabilities: []string{"SubdomainScan", "PortScan"}, BudgetState: "open"},
		{Name: "n2", State: 1, Capabilities: []string{"VulScan"}, BudgetState: "open"},
		{Name: "n3", State: 1, Capabilities: []string{"SubdomainScan"}, BudgetState: "paused"}, // budget closed
		{Name: "n4", State: 2, Capabilities: []string{"SubdomainScan"}, BudgetState: "open"},   // node paused
	}
	got := PickEligibleNodes(nodes, "SubdomainScan")
	if len(got) != 1 || got[0].Name != "n1" {
		t.Errorf("eligible nodes = %v, want [n1]", names(got))
	}
}

func names(ns []NodeView) []string {
	out := make([]string, len(ns))
	for i, n := range ns {
		out[i] = n.Name
	}
	return out
}
```

- [ ] **Step 4.2: 跑测试,确认失败**

```bash
go test ./internal/services/dispatcher/ -v
```

- [ ] **Step 4.3: 写实现**

```go
// Package dispatcher decides which nodes can receive which tasks.
//
// In the push model (current), the dispatcher writes a task into
// NodeTask:{NodeName} for the chosen node. Adding capability + budget
// awareness here means we never write a task into a node that can't run it.
//
// In the pull model (Plan 3), dispatchers will write to scan:stream:{module}
// instead, and capability matching happens on the consumer side. Both
// models share PickEligibleNodes, so this code is forward-compatible.
package dispatcher

import "slices"

// NodeView is the subset of node metadata dispatcher needs.
// Materialized from the node:* hash in Redis or from a Mongo nodes collection.
type NodeView struct {
	Name         string
	State        int      // 1=running, 2=paused, 3=disconnected
	Capabilities []string // capability ids; empty = legacy node, accept all
	BudgetState  string   // "open"|"throttled"|"paused"|"emergency_cooldown"
}

// CanDispatch returns true if a node with the given capabilities can run
// the given task module. Empty caps is treated as "legacy node: accept all"
// to preserve backward compatibility during rollout.
func CanDispatch(nodeCaps []string, taskModule string) bool {
	if len(nodeCaps) == 0 {
		return true
	}
	return slices.Contains(nodeCaps, taskModule)
}

// PickEligibleNodes returns the subset of nodes that:
//   1. Are in running state (State==1)
//   2. Have a budget state that accepts work (open or throttled)
//   3. Either have the capability listed or have empty caps (legacy)
func PickEligibleNodes(nodes []NodeView, taskModule string) []NodeView {
	out := make([]NodeView, 0, len(nodes))
	for _, n := range nodes {
		if n.State != 1 {
			continue
		}
		if n.BudgetState == "paused" || n.BudgetState == "emergency_cooldown" {
			continue
		}
		if !CanDispatch(n.Capabilities, taskModule) {
			continue
		}
		out = append(out, n)
	}
	return out
}
```

- [ ] **Step 4.4: 跑测试,确认通过**

```bash
go test ./internal/services/dispatcher/ -v
```

Expected: 4 PASS。

- [ ] **Step 4.5: Commit**

```bash
git add ScopeSentry/internal/services/dispatcher/capability_filter.go \
        ScopeSentry/internal/services/dispatcher/capability_filter_test.go
git commit -m "feat(dispatcher): filter task dispatch by node capability and budget"
```

---

## Task 5: Enroll Token API Handlers

**Files:**
- Create: `ScopeSentry/internal/api/handlers/node/enroll.go`
- Create: `ScopeSentry/internal/api/handlers/node/enroll_test.go`

5 个 handler:
- `POST /api/node/enroll-tokens` — 管理员生成 token
- `GET  /api/node/enroll-tokens` — 列表
- `DELETE /api/node/enroll-tokens/:id` — 吊销未用 token
- `POST /api/node/enroll` — 节点用 token 换凭据
- `GET  /api/node/enroll-tokens/:id/status` — 前端弹窗轮询用

- [ ] **Step 5.1: 写测试(用 gin test 模式)**

```go
package node

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Autumn-27/ScopeSentry/internal/models"
	"github.com/gin-gonic/gin"
)

// fakeStore implements TokenStore + Provisioner for handler tests.
type fakeStore struct {
	tokens         map[string]*models.EnrollToken
	createCallCount int
	dropCallCount   int
	mongoCreds     models.NodeCredentials
	redisCreds     models.NodeCredentials
}

func newFakeStore() *fakeStore {
	return &fakeStore{
		tokens: map[string]*models.EnrollToken{},
		mongoCreds: models.NodeCredentials{Username: "node-x", Password: "mongo-pass", Database: "ScopeSentry"},
		redisCreds: models.NodeCredentials{Username: "node-x", Password: "redis-pass"},
	}
}

func (f *fakeStore) InsertToken(_ context.Context, tk *models.EnrollToken) error {
	f.tokens[tk.ID] = tk
	return nil
}
func (f *fakeStore) FindToken(_ context.Context, id string) (*models.EnrollToken, error) {
	tk, ok := f.tokens[id]
	if !ok {
		return nil, errors.New("not found")
	}
	return tk, nil
}
func (f *fakeStore) ConsumeToken(_ context.Context, id, ip, nodeID string) (*models.EnrollToken, error) {
	tk, ok := f.tokens[id]
	if !ok {
		return nil, errors.New("not found")
	}
	if tk.ConsumedAt != nil {
		return nil, errors.New("already consumed")
	}
	if !tk.IsValid(time.Now()) {
		return nil, errors.New("invalid")
	}
	now := time.Now()
	tk.ConsumedAt = &now
	tk.ConsumedByIP = ip
	tk.IssuedNodeID = nodeID
	return tk, nil
}
func (f *fakeStore) ListTokens(_ context.Context) ([]*models.EnrollToken, error) {
	out := []*models.EnrollToken{}
	for _, tk := range f.tokens {
		out = append(out, tk)
	}
	return out, nil
}
func (f *fakeStore) DeleteToken(_ context.Context, id string) error {
	delete(f.tokens, id)
	return nil
}
func (f *fakeStore) CreateMongoUser(_ context.Context, username string) (models.NodeCredentials, error) {
	f.createCallCount++
	return f.mongoCreds, nil
}
func (f *fakeStore) CreateRedisUser(_ context.Context, username string) (models.NodeCredentials, error) {
	return f.redisCreds, nil
}
func (f *fakeStore) DropMongoUser(_ context.Context, username string) error {
	f.dropCallCount++
	return nil
}
func (f *fakeStore) DropRedisUser(_ context.Context, username string) error {
	return nil
}

// helpers
func setupRouter(deps *fakeStore) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	h := NewEnrollHandler(deps, EnrollConfig{
		TokenTTL:           15 * time.Minute,
		MongoConnHost:      "10.0.0.1",
		MongoConnPort:      "27017",
		MongoDatabase:      "ScopeSentry",
		RedisConnHost:      "10.0.0.1",
		RedisConnPort:      "6379",
	})
	g := r.Group("/api/node")
	g.POST("/enroll-tokens", h.GenerateToken)
	g.GET("/enroll-tokens", h.ListTokens)
	g.DELETE("/enroll-tokens/:id", h.RevokeToken)
	g.POST("/enroll", h.Enroll)
	g.GET("/enroll-tokens/:id/status", h.TokenStatus)
	return r
}

func TestGenerateToken_HappyPath(t *testing.T) {
	store := newFakeStore()
	r := setupRouter(store)

	body, _ := json.Marshal(map[string]any{
		"intended_name":   "vps-1",
		"capabilities":    []string{"SubdomainScan", "PortScan"},
		"budget_template": "conservative",
	})
	req := httptest.NewRequest("POST", "/api/node/enroll-tokens", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		Token       string    `json:"token"`
		ExpiresAt   time.Time `json:"expires_at"`
		InstallCmd  string    `json:"install_command"`
	}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Token == "" || len(resp.Token) < 32 {
		t.Errorf("bad token: %q", resp.Token)
	}
	if resp.InstallCmd == "" || !contains(resp.InstallCmd, resp.Token) {
		t.Errorf("install command should embed token")
	}
}

func TestEnroll_RejectsUnknownToken(t *testing.T) {
	store := newFakeStore()
	r := setupRouter(store)

	body, _ := json.Marshal(map[string]any{
		"token":     "ENROLL_nonexistent",
		"node_name": "vps-1",
		"hostname":  "vps-1",
	})
	req := httptest.NewRequest("POST", "/api/node/enroll", bytes.NewReader(body))
	req.RemoteAddr = "1.2.3.4:1234"
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestEnroll_HappyPath_IssuesCredentials(t *testing.T) {
	store := newFakeStore()
	// Pre-insert a token
	tk := &models.EnrollToken{
		ID:           "ENROLL_validxxx",
		CreatedAt:    time.Now(),
		ExpiresAt:    time.Now().Add(15 * time.Minute),
		IntendedName: "vps-1",
		Capabilities: []string{"SubdomainScan"},
		BudgetTemplate: "conservative",
	}
	store.InsertToken(context.Background(), tk)

	r := setupRouter(store)
	body, _ := json.Marshal(map[string]any{
		"token":     "ENROLL_validxxx",
		"node_name": "vps-1",
		"hostname":  "vps-1",
	})
	req := httptest.NewRequest("POST", "/api/node/enroll", bytes.NewReader(body))
	req.RemoteAddr = "1.2.3.4:1234"
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}

	var resp struct {
		NodeName string `json:"node_name"`
		Mongo    struct {
			IP, Port, User, Password, Database string
		} `json:"mongo"`
		Redis struct {
			IP, Port, Password string
			User               string
		} `json:"redis"`
		Capabilities []string          `json:"capabilities"`
		Budget       map[string]string `json:"budget"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.NodeName != "vps-1" {
		t.Errorf("name=%q", resp.NodeName)
	}
	if resp.Mongo.User != "node-x" || resp.Mongo.Password != "mongo-pass" {
		t.Errorf("mongo creds wrong: %+v", resp.Mongo)
	}
	if len(resp.Capabilities) != 1 || resp.Capabilities[0] != "SubdomainScan" {
		t.Errorf("capabilities=%v", resp.Capabilities)
	}
	if resp.Budget["CPU_HIGH_LONG"] != "55" {
		t.Errorf("conservative budget CPU_HIGH_LONG=%q want 55", resp.Budget["CPU_HIGH_LONG"])
	}

	// Token should be marked consumed.
	tkAfter, _ := store.FindToken(context.Background(), "ENROLL_validxxx")
	if tkAfter.ConsumedAt == nil {
		t.Error("token should be consumed")
	}
	if tkAfter.ConsumedByIP != "1.2.3.4" {
		t.Errorf("ConsumedByIP=%q", tkAfter.ConsumedByIP)
	}
	if store.createCallCount != 1 {
		t.Errorf("CreateMongoUser called %d times, want 1", store.createCallCount)
	}
}

func TestEnroll_RejectsConsumedToken(t *testing.T) {
	store := newFakeStore()
	now := time.Now()
	tk := &models.EnrollToken{
		ID: "ENROLL_used", ExpiresAt: now.Add(time.Hour),
		ConsumedAt: &now, ConsumedByIP: "9.9.9.9",
	}
	store.InsertToken(context.Background(), tk)

	r := setupRouter(store)
	body, _ := json.Marshal(map[string]any{"token": "ENROLL_used", "node_name": "x"})
	req := httptest.NewRequest("POST", "/api/node/enroll", bytes.NewReader(body))
	req.RemoteAddr = "1.2.3.4:1234"
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401 for consumed token", w.Code)
	}
}

func TestRevokeToken_DeletesUnused(t *testing.T) {
	store := newFakeStore()
	tk := &models.EnrollToken{
		ID: "ENROLL_pending", ExpiresAt: time.Now().Add(time.Hour),
	}
	store.InsertToken(context.Background(), tk)

	r := setupRouter(store)
	req := httptest.NewRequest("DELETE", "/api/node/enroll-tokens/ENROLL_pending", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status=%d", w.Code)
	}
	if _, err := store.FindToken(context.Background(), "ENROLL_pending"); err == nil {
		t.Error("token should be deleted")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
```

- [ ] **Step 5.2: 跑测试,确认失败**

```bash
go test ./internal/api/handlers/node/ -run Enroll -v
```

- [ ] **Step 5.3: 写实现**

```go
// internal/api/handlers/node/enroll.go
package node

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/Autumn-27/ScopeSentry/internal/models"
	"github.com/gin-gonic/gin"
)

// EnrollDeps is the narrow interface that EnrollHandler needs.
// In production it's a single struct backed by Mongo + the credential
// provisioners; tests pass a fake.
type EnrollDeps interface {
	InsertToken(ctx context.Context, tk *models.EnrollToken) error
	FindToken(ctx context.Context, id string) (*models.EnrollToken, error)
	ConsumeToken(ctx context.Context, id, ip, nodeID string) (*models.EnrollToken, error)
	ListTokens(ctx context.Context) ([]*models.EnrollToken, error)
	DeleteToken(ctx context.Context, id string) error
	CreateMongoUser(ctx context.Context, username string) (models.NodeCredentials, error)
	CreateRedisUser(ctx context.Context, username string) (models.NodeCredentials, error)
	DropMongoUser(ctx context.Context, username string) error
	DropRedisUser(ctx context.Context, username string) error
}

// EnrollConfig is wiring info — addresses scanners need to phone home to.
type EnrollConfig struct {
	TokenTTL      time.Duration
	MongoConnHost string
	MongoConnPort string
	MongoDatabase string
	RedisConnHost string
	RedisConnPort string
	CtrlURL       string // e.g. "https://ctrl.example.com" (used to build the install command)
}

type EnrollHandler struct {
	deps EnrollDeps
	cfg  EnrollConfig
}

func NewEnrollHandler(deps EnrollDeps, cfg EnrollConfig) *EnrollHandler {
	if cfg.TokenTTL == 0 {
		cfg.TokenTTL = 15 * time.Minute
	}
	return &EnrollHandler{deps: deps, cfg: cfg}
}

// --- request/response shapes ---

type generateTokenReq struct {
	IntendedName   string   `json:"intended_name"`
	Capabilities   []string `json:"capabilities"`
	BudgetTemplate string   `json:"budget_template"`
	BoundIP        string   `json:"bound_ip"`
}

type generateTokenResp struct {
	Token          string    `json:"token"`
	ExpiresAt      time.Time `json:"expires_at"`
	InstallCommand string    `json:"install_command"`
}

type enrollReq struct {
	Token    string `json:"token"`
	NodeName string `json:"node_name"`
	Hostname string `json:"hostname"`
}

type enrollResp struct {
	NodeName     string            `json:"node_name"`
	Mongo        mongoCreds        `json:"mongo"`
	Redis        redisCreds        `json:"redis"`
	Capabilities []string          `json:"capabilities"`
	Budget       map[string]string `json:"budget"`
	CtrlURL      string            `json:"ctrl_url"`
}

type mongoCreds struct {
	IP       string `json:"ip"`
	Port     string `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
	Database string `json:"database"`
}

type redisCreds struct {
	IP       string `json:"ip"`
	Port     string `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
}

// --- handlers ---

func (h *EnrollHandler) GenerateToken(c *gin.Context) {
	var req generateTokenReq
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if len(req.Capabilities) == 0 {
		// Default: all capabilities (full-stack node)
		for _, cap := range models.AllCapabilities() {
			req.Capabilities = append(req.Capabilities, string(cap))
		}
	}
	if req.BudgetTemplate == "" {
		req.BudgetTemplate = string(models.BudgetDefault)
	}

	id, err := generateTokenID()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "token generation failed"})
		return
	}
	tk := &models.EnrollToken{
		ID:             id,
		CreatedAt:      time.Now(),
		ExpiresAt:      time.Now().Add(h.cfg.TokenTTL),
		BoundIP:        req.BoundIP,
		IntendedName:   req.IntendedName,
		Capabilities:   req.Capabilities,
		BudgetTemplate: req.BudgetTemplate,
	}
	if err := h.deps.InsertToken(c.Request.Context(), tk); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	cmd := fmt.Sprintf("curl -fsSL %s/install-node.sh | bash -s -- --token=%s",
		strings.TrimRight(h.cfg.CtrlURL, "/"), id)

	c.JSON(http.StatusOK, generateTokenResp{
		Token:          id,
		ExpiresAt:      tk.ExpiresAt,
		InstallCommand: cmd,
	})
}

func (h *EnrollHandler) ListTokens(c *gin.Context) {
	tks, err := h.deps.ListTokens(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"tokens": tks})
}

func (h *EnrollHandler) RevokeToken(c *gin.Context) {
	id := c.Param("id")
	tk, err := h.deps.FindToken(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "token not found"})
		return
	}
	if tk.ConsumedAt != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "token already consumed; cannot revoke (decommission node instead)"})
		return
	}
	if err := h.deps.DeleteToken(c.Request.Context(), id); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"revoked": id})
}

func (h *EnrollHandler) TokenStatus(c *gin.Context) {
	tk, err := h.deps.FindToken(c.Request.Context(), c.Param("id"))
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	c.JSON(http.StatusOK, tk)
}

func (h *EnrollHandler) Enroll(c *gin.Context) {
	var req enrollReq
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if req.Token == "" || req.NodeName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "token and node_name required"})
		return
	}

	clientIP := extractClientIP(c.Request.RemoteAddr, c.GetHeader("X-Forwarded-For"))

	// Optional: enforce IP binding if token had one.
	tk, err := h.deps.FindToken(c.Request.Context(), req.Token)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
		return
	}
	if tk.BoundIP != "" && tk.BoundIP != clientIP {
		c.JSON(http.StatusForbidden, gin.H{"error": "token bound to different IP"})
		return
	}
	if !tk.IsValid(time.Now()) {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "token expired or already used"})
		return
	}

	nodeID := sanitizeNodeID(req.NodeName)

	// Atomic consume — IF this races with another caller, only one wins.
	// fakeStore impl checks for already-consumed; production uses
	// findOneAndUpdate so it's also atomic at the DB layer.
	consumed, err := h.deps.ConsumeToken(c.Request.Context(), req.Token, clientIP, nodeID)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": err.Error()})
		return
	}

	// Create per-node credentials.
	mongoC, err := h.deps.CreateMongoUser(c.Request.Context(), nodeID)
	if err != nil {
		// Best-effort rollback (token consumption is one-shot, but we should
		// log it; an admin can manually issue a new token).
		c.JSON(http.StatusInternalServerError, gin.H{"error": "mongo provision failed: " + err.Error()})
		return
	}
	redisC, err := h.deps.CreateRedisUser(c.Request.Context(), nodeID)
	if err != nil {
		// Roll back the Mongo user we just created.
		_ = h.deps.DropMongoUser(c.Request.Context(), nodeID)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "redis provision failed: " + err.Error()})
		return
	}

	budget := models.BudgetTemplate(consumed.BudgetTemplate).EnvOverrides()

	c.JSON(http.StatusOK, enrollResp{
		NodeName: nodeID,
		Mongo: mongoCreds{
			IP: h.cfg.MongoConnHost, Port: h.cfg.MongoConnPort,
			User: mongoC.Username, Password: mongoC.Password, Database: h.cfg.MongoDatabase,
		},
		Redis: redisCreds{
			IP: h.cfg.RedisConnHost, Port: h.cfg.RedisConnPort,
			User: redisC.Username, Password: redisC.Password,
		},
		Capabilities: consumed.Capabilities,
		Budget:       budget,
		CtrlURL:      h.cfg.CtrlURL,
	})
}

// --- helpers ---

func generateTokenID() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "ENROLL_" + hex.EncodeToString(b), nil
}

// sanitizeNodeID makes a name safe for use as Mongo username / Redis ACL name.
// Strip non-[a-zA-Z0-9_-], lowercase, prefix with "node-".
func sanitizeNodeID(name string) string {
	var b strings.Builder
	b.WriteString("node-")
	for _, r := range strings.ToLower(name) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteRune('-')
		}
	}
	out := b.String()
	if len(out) > 60 {
		out = out[:60]
	}
	return out
}

func extractClientIP(remoteAddr, xff string) string {
	if xff != "" {
		// Use first hop in X-Forwarded-For.
		parts := strings.Split(xff, ",")
		return strings.TrimSpace(parts[0])
	}
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

var _ = errors.New // shut up unused import if errors becomes unused after final form
```

⚠️ 上面 `var _ = errors.New` 是为了避免 import 块编译报错的占位,实际编写时如果用不到 errors 包,**直接从 import 中删除**即可,不要留 `var _` 这种代码。

- [ ] **Step 5.4: 跑测试,确认通过**

```bash
go test ./internal/api/handlers/node/ -run Enroll -v
```

Expected: 5 PASS。

- [ ] **Step 5.5: Commit**

```bash
git add ScopeSentry/internal/api/handlers/node/enroll.go \
        ScopeSentry/internal/api/handlers/node/enroll_test.go
git commit -m "feat(enroll): add token generation, enroll, list, revoke handlers"
```

---

## Task 6: Production EnrollDeps 实现(粘合 Mongo collection + provisioners)

**Files:**
- Create: `ScopeSentry/internal/services/enrollstore/store.go`

- [ ] **Step 6.1: 写 store.go**

```go
// Package enrollstore is the production implementation of node.EnrollDeps.
// Glues together: Mongo collection for tokens, Mongo user provisioner,
// Redis ACL provisioner. Tests at the handler layer use fakes; this layer
// is exercised by integration tests.
package enrollstore

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/Autumn-27/ScopeSentry/internal/models"
	"github.com/Autumn-27/ScopeSentry/internal/services/credentials"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type Store struct {
	tokens         *mongo.Collection
	mongoProvisioner *credentials.MongoProvisioner
	redisProvisioner *credentials.RedisACLProvisioner
}

func NewStore(db *mongo.Database, mp *credentials.MongoProvisioner, rp *credentials.RedisACLProvisioner) *Store {
	return &Store{
		tokens:           db.Collection(models.EnrollTokensCollection),
		mongoProvisioner: mp,
		redisProvisioner: rp,
	}
}

func (s *Store) InsertToken(ctx context.Context, tk *models.EnrollToken) error {
	_, err := s.tokens.InsertOne(ctx, tk)
	return err
}

func (s *Store) FindToken(ctx context.Context, id string) (*models.EnrollToken, error) {
	var tk models.EnrollToken
	err := s.tokens.FindOne(ctx, bson.M{"_id": id}).Decode(&tk)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, fmt.Errorf("token not found")
	}
	return &tk, err
}

// ConsumeToken atomically marks the token consumed. Concurrent calls are safe:
// only the first findOneAndUpdate match wins; the rest get nil.
func (s *Store) ConsumeToken(ctx context.Context, id, ip, nodeID string) (*models.EnrollToken, error) {
	now := time.Now()
	filter := bson.M{
		"_id":          id,
		"consumed_at":  bson.M{"$exists": false},
		"expires_at":   bson.M{"$gt": now},
	}
	update := bson.M{
		"$set": bson.M{
			"consumed_at":     now,
			"consumed_by_ip":  ip,
			"issued_node_id":  nodeID,
		},
	}
	opts := options.FindOneAndUpdate().SetReturnDocument(options.After)
	var tk models.EnrollToken
	err := s.tokens.FindOneAndUpdate(ctx, filter, update, opts).Decode(&tk)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, fmt.Errorf("token already consumed or expired")
	}
	if err != nil {
		return nil, err
	}
	return &tk, nil
}

func (s *Store) ListTokens(ctx context.Context) ([]*models.EnrollToken, error) {
	cur, err := s.tokens.Find(ctx, bson.M{},
		options.Find().SetSort(bson.M{"created_at": -1}).SetLimit(200))
	if err != nil {
		return nil, err
	}
	defer cur.Close(ctx)
	var out []*models.EnrollToken
	for cur.Next(ctx) {
		var tk models.EnrollToken
		if err := cur.Decode(&tk); err != nil {
			return nil, err
		}
		out = append(out, &tk)
	}
	return out, cur.Err()
}

func (s *Store) DeleteToken(ctx context.Context, id string) error {
	_, err := s.tokens.DeleteOne(ctx, bson.M{"_id": id})
	return err
}

// Provisioner pass-throughs (translate models.NodeCredentials).

func (s *Store) CreateMongoUser(ctx context.Context, username string) (models.NodeCredentials, error) {
	c, err := s.mongoProvisioner.CreateNodeUser(ctx, username)
	if err != nil {
		return models.NodeCredentials{}, err
	}
	return models.NodeCredentials{Username: c.Username, Password: c.Password, Database: c.Database}, nil
}

func (s *Store) CreateRedisUser(ctx context.Context, username string) (models.NodeCredentials, error) {
	c, err := s.redisProvisioner.CreateNodeUser(ctx, username)
	if err != nil {
		return models.NodeCredentials{}, err
	}
	return models.NodeCredentials{Username: c.Username, Password: c.Password}, nil
}

func (s *Store) DropMongoUser(ctx context.Context, username string) error {
	return s.mongoProvisioner.DropNodeUser(ctx, username)
}

func (s *Store) DropRedisUser(ctx context.Context, username string) error {
	return s.redisProvisioner.DropNodeUser(ctx, username)
}
```

⚠️ 注意 `models.NodeCredentials`(Plan 中第二处使用) 与 Task 2 的 `credentials.NodeCredentials` **是不同的类型**。在 `internal/models/node_capabilities.go` 末尾追加:

```go
// NodeCredentials is the cross-package public shape (independent of internal
// credentials package, which has its own internal struct).
type NodeCredentials struct {
	Username string
	Password string
	Database string
}
```

(这样 handler 层和 store 层都用 `models.NodeCredentials`,`credentials` 包返回的内部 struct 在 store 内做一次翻译。)

- [ ] **Step 6.2: 编译**

```bash
go build ./...
```

Expected: 无错。

- [ ] **Step 6.3: Commit**

```bash
git add ScopeSentry/internal/services/enrollstore/store.go \
        ScopeSentry/internal/models/node_capabilities.go
git commit -m "feat(enroll): production EnrollDeps backed by Mongo + provisioners"
```

---

## Task 7: install-node.sh + 静态分发

**Files:**
- Create: `ScopeSentry/assets/install-node.sh`
- Create: `ScopeSentry/internal/api/handlers/installer/installer.go`
- Create: `ScopeSentry/internal/api/handlers/installer/installer_test.go`
- Modify: `ScopeSentry/internal/api/routes/routes.go`

- [ ] **Step 7.1: 写 install-node.sh**

完整脚本如下,直接保存到 `ScopeSentry/assets/install-node.sh`(注意 `__CTRL_URL__` 是占位符,运行时被服务端替换):

```bash
#!/usr/bin/env bash
# ScopeSentry node bootstrap.
#
# Usage:
#   curl -fsSL https://ctrl.example.com/install-node.sh | bash -s -- --token=ENROLL_xxx
#
# Optional flags:
#   --name=NAME          override node name (default: hostname-RANDOM)
#   --image=IMAGE        scanner image tag (default: autumn27/scopesentry-scan:latest)
#   --skip-docker-check  assume Docker is present
#
# Environment overrides:
#   SCAN_DATA_DIR        host path for scanner data (default /opt/scopesentry-node)
set -euo pipefail

CTRL_URL="__CTRL_URL__"
TOKEN=""
NODE_NAME=""
IMAGE="autumn27/scopesentry-scan:latest"
SKIP_DOCKER_CHECK=0
SCAN_DATA_DIR="${SCAN_DATA_DIR:-/opt/scopesentry-node}"

# --- arg parse ---
for arg in "$@"; do
	case "$arg" in
		--token=*)        TOKEN="${arg#--token=}" ;;
		--name=*)         NODE_NAME="${arg#--name=}" ;;
		--image=*)        IMAGE="${arg#--image=}" ;;
		--skip-docker-check) SKIP_DOCKER_CHECK=1 ;;
		*)
			echo "❌ unknown arg: $arg" >&2
			exit 2
			;;
	esac
done

# --- pre-flight checks ---
[[ -n "${TOKEN}" ]] || { echo "❌ --token is required" >&2; exit 2; }
[[ "$(uname -s)" == "Linux" ]] || { echo "❌ scanner needs host network mode → Linux only" >&2; exit 2; }
[[ ${EUID} -eq 0 ]] || { echo "❌ run as root (sudo)" >&2; exit 2; }

NODE_NAME="${NODE_NAME:-$(hostname)-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)}"

echo "▶ ScopeSentry node bootstrap"
echo "  Node name: ${NODE_NAME}"
echo "  Control:   ${CTRL_URL}"
echo "  Image:     ${IMAGE}"
echo "  Data dir:  ${SCAN_DATA_DIR}"
echo

# --- ensure dependencies ---
need_install=()
command -v jq    >/dev/null || need_install+=("jq")
command -v curl  >/dev/null || need_install+=("curl")

if [[ ${#need_install[@]} -gt 0 ]]; then
	echo "Installing missing tools: ${need_install[*]}"
	if command -v apt-get >/dev/null; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -y >/dev/null
		apt-get install -y "${need_install[@]}" >/dev/null
	elif command -v yum >/dev/null; then
		yum install -y "${need_install[@]}" >/dev/null
	elif command -v apk >/dev/null; then
		apk add --no-cache "${need_install[@]}" >/dev/null
	else
		echo "❌ unsupported package manager — install ${need_install[*]} manually and rerun" >&2
		exit 3
	fi
fi

if [[ ${SKIP_DOCKER_CHECK} -eq 0 ]]; then
	if ! command -v docker >/dev/null; then
		echo "Docker not found, installing via get.docker.com…"
		curl -fsSL https://get.docker.com | sh
	fi
	systemctl enable --now docker || true
fi

echo "Pulling scanner image (this is the slowest step)…"
docker pull "${IMAGE}"

# --- enroll: exchange token for credentials ---
echo "Calling enroll endpoint…"
RESP=$(
	curl -fsSL --max-time 15 \
		-X POST "${CTRL_URL}/api/node/enroll" \
		-H "Content-Type: application/json" \
		--data "$(jq -n \
			--arg token "${TOKEN}" \
			--arg name  "${NODE_NAME}" \
			--arg host  "$(hostname)" \
			'{token:$token, node_name:$name, hostname:$host}')"
) || {
	echo "❌ enroll failed (curl exit $?)" >&2
	exit 4
}

# Parse strictly — surface useful error if shape is wrong.
if ! echo "${RESP}" | jq -e '.node_name and .mongo.user and .redis.password' >/dev/null; then
	echo "❌ enroll response malformed:" >&2
	echo "${RESP}" >&2
	exit 5
fi

ASSIGNED_NAME=$(echo "${RESP}" | jq -r '.node_name')

# --- write env file ---
install -m 700 -d "${SCAN_DATA_DIR}"
ENV_FILE="${SCAN_DATA_DIR}/.env"

echo "Writing env file (chmod 600)…"
{
	echo "NodeName=${ASSIGNED_NAME}"
	echo "MONGODB_IP=$(echo "${RESP}" | jq -r '.mongo.ip')"
	echo "MONGODB_PORT=$(echo "${RESP}" | jq -r '.mongo.port')"
	echo "MONGODB_USER=$(echo "${RESP}" | jq -r '.mongo.user')"
	echo "MONGODB_PASSWORD=$(echo "${RESP}" | jq -r '.mongo.password')"
	echo "MONGODB_DATABASE=$(echo "${RESP}" | jq -r '.mongo.database')"
	echo "REDIS_IP=$(echo "${RESP}" | jq -r '.redis.ip')"
	echo "REDIS_PORT=$(echo "${RESP}" | jq -r '.redis.port')"
	echo "REDIS_PASSWORD=$(echo "${RESP}" | jq -r '.redis.password')"
	# Capabilities: comma-separated, scanner reads CAPABILITIES env.
	echo "CAPABILITIES=$(echo "${RESP}" | jq -r '.capabilities | join(",")')"
	# Budget overrides (Plan 1 vars)
	echo "${RESP}" | jq -r '.budget | to_entries[] | "\(.key)=\(.value)"'
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

# --- run scanner ---
echo "Starting scanner container…"
docker rm -f scopesentry-scan 2>/dev/null || true
docker run -d \
	--name scopesentry-scan \
	--network host \
	--restart always \
	--ulimit core=0 \
	--env-file "${ENV_FILE}" \
	"${IMAGE}" >/dev/null

# --- verify heartbeat ---
echo -n "Waiting for first heartbeat"
for i in $(seq 1 20); do
	sleep 3
	echo -n "."
	# Best-effort check: GET /api/node/{name}/online (TODO: depends on existing online endpoint signature).
	# If this endpoint isn't auth-public, the install script just relies on docker logs as a fallback.
	if curl -fsSL --max-time 3 "${CTRL_URL}/api/node/online?name=${ASSIGNED_NAME}" 2>/dev/null \
		| jq -e '.online == true' >/dev/null 2>&1; then
		echo " ✅"
		echo
		echo "Node ${ASSIGNED_NAME} enrolled and online."
		exit 0
	fi
done
echo
echo "⚠ Container started but heartbeat not visible to control plane within 60s."
echo "  Inspect:  docker logs scopesentry-scan"
exit 6
```

**关键决策记录:**
- 不用 `set -x` 避免泄露密码到 log
- `--ulimit core=0` 禁用 core dump(扫描器 OOM 时能省 GB 级磁盘)
- ASSIGNED_NAME 优先使用服务端返回的(因为做了 sanitize),不是 client 提供的
- `online` 接口依赖现有 `GET /api/node/online`,如果 API 形状不同需要在 Step 7.4 调整

- [ ] **Step 7.2: 写 installer handler**

```go
// Package installer serves the node bootstrap script. The script is embedded
// at compile-time and template-rendered with this server's CtrlURL on each
// request, so a single binary works across deployments.
package installer

import (
	_ "embed"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

//go:embed install-node.sh
var rawScript string

type Handler struct {
	ctrlURL string
}

func NewHandler(ctrlURL string) *Handler {
	return &Handler{ctrlURL: strings.TrimRight(ctrlURL, "/")}
}

// Serve responds with the install script, with __CTRL_URL__ replaced.
// Sets aggressive no-cache headers because the script may change.
func (h *Handler) Serve(c *gin.Context) {
	body := strings.ReplaceAll(rawScript, "__CTRL_URL__", h.ctrlURL)
	c.Header("Content-Type", "text/x-shellscript; charset=utf-8")
	c.Header("Cache-Control", "no-cache, must-revalidate")
	c.Header("X-Content-Type-Options", "nosniff")
	c.String(http.StatusOK, body)
}
```

**重要:** Go embed 需要文件在 handler 同一目录或子目录。我们把 `install-node.sh` 放在 `ScopeSentry/assets/`,但 embed 路径必须是相对于 .go 文件的。两个选择:
- (A) 把 install-node.sh 放进 `ScopeSentry/internal/api/handlers/installer/install-node.sh`,handler 直接 `//go:embed install-node.sh`
- (B) 用 embed.FS 跨目录:`//go:embed ../../../assets/install-node.sh`(go 1.16+ 支持但反人类)

**选 (A)**: 把脚本放在 handler 目录里。修改 Step 7.1 的路径为 `ScopeSentry/internal/api/handlers/installer/install-node.sh`。`assets/` 目录不要建。

- [ ] **Step 7.3: 写测试**

```go
// internal/api/handlers/installer/installer_test.go
package installer

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestServe_ReplacesCtrlURL(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	h := NewHandler("https://example.com/")
	r.GET("/install-node.sh", h.Serve)

	req := httptest.NewRequest("GET", "/install-node.sh", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status=%d", w.Code)
	}
	body := w.Body.String()
	if !strings.Contains(body, `CTRL_URL="https://example.com"`) {
		t.Errorf("ctrl URL not replaced (trailing slash trimmed)")
	}
	if strings.Contains(body, "__CTRL_URL__") {
		t.Errorf("placeholder still present")
	}
	if w.Header().Get("Cache-Control") == "" {
		t.Errorf("missing Cache-Control")
	}
	if w.Header().Get("Content-Type") != "text/x-shellscript; charset=utf-8" {
		t.Errorf("wrong content-type: %q", w.Header().Get("Content-Type"))
	}
}
```

- [ ] **Step 7.4: 注册路由**

修改 `ScopeSentry/internal/api/routes/routes.go`,在 api 组**之外**注册公开路由:

```go
// inside RegisterRoutes(or wherever the gin engine is built) BEFORE the api group:
inst := installer.NewHandler(cfg.CtrlURL) // cfg holds the public-facing URL
engine.GET("/install-node.sh", inst.Serve)
```

具体改法取决于现有代码结构。先 `grep -n "RegisterRoutes\|engine\." ScopeSentry/internal/api/routes/routes.go` 找入口,贴着现有的 router setup 加。

- [ ] **Step 7.5: shellcheck 校验脚本**

```bash
sudo apt install shellcheck   # macOS: brew install shellcheck
shellcheck ScopeSentry/internal/api/handlers/installer/install-node.sh
```

修复任何 SC 警告。常见的:`SC2086`(quote variables)、`SC2155`(declare separately)。

- [ ] **Step 7.6: 跑测试**

```bash
go test ./internal/api/handlers/installer/ -v
```

Expected: PASS。

- [ ] **Step 7.7: Commit**

```bash
git add ScopeSentry/internal/api/handlers/installer/install-node.sh \
        ScopeSentry/internal/api/handlers/installer/installer.go \
        ScopeSentry/internal/api/handlers/installer/installer_test.go \
        ScopeSentry/internal/api/routes/routes.go
git commit -m "feat(enroll): serve install-node.sh with embedded template"
```

---

## Task 8: 路由 + 应用启动接线

**Files:**
- Modify: `ScopeSentry/internal/api/routes/node/node.go`
- Modify: 启动入口(`cmd/ScopeSentry/main.go` 或 `internal/server/server.go`,具体看现有结构)

- [ ] **Step 8.1: 注册 enroll 路由**

修改 `internal/api/routes/node/node.go::RegisterNodeRoutes`,在现有 7 条路由后追加 5 条:

```go
		Routes: []models.Route{
			// ... existing 7 routes (Get, GetOnline, ConfigUpdate, Delete, GetLogs, GetNodePlugin, RestartNode) ...
			{
				Method:  "POST",
				Path:    "/enroll-tokens",
				Handler: enrollHandler.GenerateToken,
				Middlewares: common.WithAuth(),
			},
			{
				Method:  "GET",
				Path:    "/enroll-tokens",
				Handler: enrollHandler.ListTokens,
				Middlewares: common.WithAuth(),
			},
			{
				Method:  "DELETE",
				Path:    "/enroll-tokens/:id",
				Handler: enrollHandler.RevokeToken,
				Middlewares: common.WithAuth(),
			},
			{
				Method:  "GET",
				Path:    "/enroll-tokens/:id/status",
				Handler: enrollHandler.TokenStatus,
				Middlewares: common.WithAuth(),
			},
			{
				Method:  "POST",
				Path:    "/enroll",
				Handler: enrollHandler.Enroll,
				// NO common.WithAuth() — token IS the auth.
			},
		},
```

`enrollHandler` 通过 `RegisterNodeRoutes` 的参数传入(改签名),或在 routes.go 的入口处构造一个全局变量。具体方式跟随现有代码风格。

- [ ] **Step 8.2: 启动时调用索引初始化 + 构造 EnrollHandler**

在 server bootstrap 处(MongoDB 初始化之后):

```go
ctx := context.Background()
db := mongoClient.Database("ScopeSentry")
if err := models.EnsureEnrollTokenIndexes(ctx, db); err != nil {
	log.Fatalf("ensure enroll indexes: %v", err)
}

// admin database for createUser/dropUser
admin := mongoClient.Database("admin")
mongoProv := credentials.NewMongoProvisioner(credentials.NewAdminRunner(admin), "ScopeSentry")
redisProv := credentials.NewRedisACLProvisioner(credentials.NewGoRedisRunner(redisClient))

store := enrollstore.NewStore(db, mongoProv, redisProv)
enrollHandler = nodehandler.NewEnrollHandler(store, nodehandler.EnrollConfig{
	TokenTTL:      15 * time.Minute,
	MongoConnHost: cfg.MongoPublicHost,   // host scanner uses to dial in
	MongoConnPort: cfg.MongoPublicPort,
	MongoDatabase: "ScopeSentry",
	RedisConnHost: cfg.RedisPublicHost,
	RedisConnPort: cfg.RedisPublicPort,
	CtrlURL:       cfg.CtrlURL,           // public URL of this server
})
```

`cfg.MongoPublicHost` 是节点拨号用的地址(可能跟服务器内部连接的不同—— 比如服务器用 `127.0.0.1:27017`,节点用 `controlplane.example.com:27017`)。在 yaml/env 配置中加这两个字段。

- [ ] **Step 8.3: 编译 + 跑全部测试**

```bash
cd ScopeSentry && go build ./... && go test ./...
```

Expected: 全过。

- [ ] **Step 8.4: 端到端冒烟(本机)**

启动 server,curl 走完整流程:

```bash
# 1. 生成 token (假设有现成的 admin JWT 在 $TOKEN_JWT)
curl -fsSL -X POST http://localhost:8082/api/node/enroll-tokens \
	-H "Authorization: Bearer ${TOKEN_JWT}" \
	-H "Content-Type: application/json" \
	-d '{"intended_name":"smoke-test","capabilities":["SubdomainScan"],"budget_template":"conservative"}' \
	| tee /tmp/token.json

ENROLL_TOKEN=$(jq -r .token /tmp/token.json)

# 2. 模拟 enroll
curl -fsSL -X POST http://localhost:8082/api/node/enroll \
	-H "Content-Type: application/json" \
	-d "{\"token\":\"${ENROLL_TOKEN}\",\"node_name\":\"smoke-test\",\"hostname\":\"smoke-test\"}" \
	| tee /tmp/enroll.json

# 3. 验证 mongo 用户存在
mongosh -u root -p ROOT_PWD --authenticationDatabase admin --eval \
	'db.getSiblingDB("admin").system.users.find({user: "node-smoke-test"}).pretty()'

# 4. 验证 redis ACL 存在
redis-cli -a ROOT_PWD ACL LIST

# 5. 用新凭据连接 mongo
MONGO_USER=$(jq -r .mongo.user /tmp/enroll.json)
MONGO_PWD=$(jq -r .mongo.password /tmp/enroll.json)
mongosh -u $MONGO_USER -p $MONGO_PWD --authenticationDatabase ScopeSentry \
	--eval 'db.getCollection("subdomain").findOne()'

# 6. 试图二次 enroll 同 token —— 应该 401
curl -fsSL -X POST http://localhost:8082/api/node/enroll \
	-H "Content-Type: application/json" \
	-d "{\"token\":\"${ENROLL_TOKEN}\",\"node_name\":\"smoke-test-2\"}"
# expected: HTTP 401 "token already consumed or expired"

# 7. 清理
mongosh -u root -p ROOT_PWD --authenticationDatabase admin --eval 'db.dropUser("node-smoke-test")'
redis-cli -a ROOT_PWD ACL DELUSER node-smoke-test
```

- [ ] **Step 8.5: Commit**

```bash
git add ScopeSentry/internal/api/routes/node/node.go ScopeSentry/cmd/...
git commit -m "feat(enroll): wire enroll routes and bootstrap services"
```

---

## Task 9: 扫描器侧能力上报

**Files:**
- Modify: `ScopeSentry-Scan/internal/global/type.go`
- Modify: `ScopeSentry-Scan/internal/config/config.go`
- Modify: `ScopeSentry-Scan/internal/node/node.go`

- [ ] **Step 9.1: Config 加 Capabilities 字段**

`internal/global/type.go`:

```go
type Config struct {
	NodeName     string           `yaml:"NodeName"`
	State        int              `yaml:"state"`
	TimeZoneName string           `yaml:"TimeZoneName"`
	Debug        bool             `yaml:"debug"`
	MongoDB      MongoDBConfig    `yaml:"mongodb"`
	Redis        RedisConfig      `yaml:"redis"`
	Interactsh   InteractshConfig `yaml:"interactsh"`
	Budget       BudgetConfig     `yaml:"budget"`
	Capabilities []string         `yaml:"capabilities"` // NEW
}
```

- [ ] **Step 9.2: 从 env 读 CAPABILITIES**

`internal/config/config.go::LoadConfig` 的 env 分支:

```go
		Capabilities: parseCSV(getEnv("CAPABILITIES", "")),
```

并在文件末尾加:

```go
func parseCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}
```

import 加 `"strings"`。

- [ ] **Step 9.3: 心跳上报 capabilities**

`internal/node/node.go::RegisterOnce`,在 `nodeInfo` map 里追加:

```go
	"capabilities": utils.Tools.JoinStrings(global.AppConfig.Capabilities, ","),
```

如果 `JoinStrings` 不存在,直接用 `strings.Join`(import "strings")。

也要在 `updateHeartbeat` 里追加同字段(确保心跳一致)。

- [ ] **Step 9.4: 编译**

```bash
cd ScopeSentry-Scan && go build ./...
```

Expected: 无错。

- [ ] **Step 9.5: Commit**

```bash
git add ScopeSentry-Scan/internal/global/type.go \
        ScopeSentry-Scan/internal/config/config.go \
        ScopeSentry-Scan/internal/node/node.go
git commit -m "feat(node): scanner reports capabilities to control plane"
```

---

## Task 10: 前端 - API client + 类型

**Files:**
- Modify: `ScopeSentry-UI/src/api/node/types.ts`(或新建)
- Modify: `ScopeSentry-UI/src/api/node/index.ts`(或新建)

- [ ] **Step 10.1: 找现有 node API 文件**

```bash
cd ScopeSentry-UI
grep -rn "node/online\|/api/node" src/api/ | head -10
```

根据现有命名风格(`useGet/useDelete/usePost` 还是 axios 直用),follow 同样的模式。

- [ ] **Step 10.2: 加类型定义**

`src/api/node/types.ts`:

```typescript
export interface EnrollToken {
  id: string
  created_at: string
  expires_at: string
  consumed_at?: string
  consumed_by_ip?: string
  intended_name: string
  capabilities: string[]
  budget_template: 'default' | 'conservative' | 'aggressive'
  issued_node_id?: string
}

export interface GenerateTokenRequest {
  intended_name?: string
  capabilities?: string[]
  budget_template?: 'default' | 'conservative' | 'aggressive'
  bound_ip?: string
}

export interface GenerateTokenResponse {
  token: string
  expires_at: string
  install_command: string
}

export const ALL_CAPABILITIES = [
  'SubdomainScan',
  'SubdomainTakeover',
  'SkipCDN',
  'PortScan',
  'AssetMapping',
  'WebFingerprint',
  'URLScan',
  'WebCrawler',
  'DirScan',
  'VulScan',
  'PassiveScan',
  'PageMonitoring',
] as const

export type Capability = typeof ALL_CAPABILITIES[number]
```

- [ ] **Step 10.3: 加 API client 方法**

`src/api/node/index.ts`(用现有 axios 封装,这里用占位符 `request`):

```typescript
import request from '@/axios'
import type {
  EnrollToken,
  GenerateTokenRequest,
  GenerateTokenResponse,
} from './types'

export const generateEnrollToken = (req: GenerateTokenRequest) =>
  request.post<GenerateTokenResponse>({
    url: '/api/node/enroll-tokens',
    data: req,
  })

export const listEnrollTokens = () =>
  request.get<{ tokens: EnrollToken[] }>({
    url: '/api/node/enroll-tokens',
  })

export const revokeEnrollToken = (id: string) =>
  request.delete({ url: `/api/node/enroll-tokens/${encodeURIComponent(id)}` })

export const getEnrollTokenStatus = (id: string) =>
  request.get<EnrollToken>({
    url: `/api/node/enroll-tokens/${encodeURIComponent(id)}/status`,
  })
```

- [ ] **Step 10.4: Commit**

```bash
git add ScopeSentry-UI/src/api/node/
git commit -m "feat(ui): enroll token API client"
```

---

## Task 11: 前端 - CapabilityEditor 组件

**Files:**
- Create: `ScopeSentry-UI/src/views/Node/components/CapabilityEditor.vue`

- [ ] **Step 11.1: 写组件**

```vue
<!-- src/views/Node/components/CapabilityEditor.vue -->
<template>
  <div class="capability-editor">
    <el-checkbox v-model="allSelected" :indeterminate="isIndeterminate" @change="handleAll">
      全选
    </el-checkbox>
    <el-divider style="margin: 8px 0" />
    <el-checkbox-group v-model="local" @change="emit('update:modelValue', local)">
      <el-row :gutter="12">
        <el-col v-for="cap in caps" :key="cap" :span="12">
          <el-checkbox :label="cap" :value="cap">
            <span class="cap-label">{{ capLabel(cap) }}</span>
            <el-tooltip :content="capDescription(cap)" placement="top">
              <el-icon class="cap-help"><InfoFilled /></el-icon>
            </el-tooltip>
          </el-checkbox>
        </el-col>
      </el-row>
    </el-checkbox-group>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { ElCheckbox, ElCheckboxGroup, ElDivider, ElIcon, ElRow, ElCol, ElTooltip } from 'element-plus'
import { InfoFilled } from '@element-plus/icons-vue'
import { ALL_CAPABILITIES, type Capability } from '@/api/node/types'

const props = defineProps<{ modelValue: Capability[] }>()
const emit = defineEmits<{ (e: 'update:modelValue', v: Capability[]): void }>()

const caps = ALL_CAPABILITIES
const local = ref<Capability[]>([...props.modelValue])

watch(
  () => props.modelValue,
  (v) => {
    if (v.join(',') !== local.value.join(',')) local.value = [...v]
  },
)

const allSelected = computed({
  get: () => local.value.length === caps.length,
  set: () => {},
})
const isIndeterminate = computed(
  () => local.value.length > 0 && local.value.length < caps.length,
)

function handleAll(checked: boolean | string | number) {
  local.value = checked ? [...caps] : []
  emit('update:modelValue', local.value)
}

function capLabel(c: Capability): string {
  return ({
    SubdomainScan: '子域名扫描',
    SubdomainTakeover: '子域名接管',
    SkipCDN: 'CDN 识别',
    PortScan: '端口扫描',
    AssetMapping: '资产指纹',
    WebFingerprint: 'Web 指纹',
    URLScan: 'URL 扫描',
    WebCrawler: '爬虫',
    DirScan: '目录扫描',
    VulScan: '漏洞扫描',
    PassiveScan: '被动扫描',
    PageMonitoring: '页面监控',
  } as Record<Capability, string>)[c]
}

function capDescription(c: Capability): string {
  return ({
    SubdomainScan: '执行 puredns/subfinder/oneforall 等子域名收集插件',
    SubdomainTakeover: '检查子域名指向已废弃服务',
    SkipCDN: '识别 CDN/WAF',
    PortScan: 'rustscan / naabu 端口探测',
    AssetMapping: 'gogo / fingerprintx 服务识别',
    WebFingerprint: 'httpx + 指纹库',
    URLScan: 'URL 提取与归一化',
    WebCrawler: 'katana 爬虫',
    DirScan: '目录爆破',
    VulScan: 'nuclei 漏洞扫描(CPU 大户)',
    PassiveScan: '被动监听代理流量',
    PageMonitoring: '定期对比页面 DOM',
  } as Record<Capability, string>)[c]
}
</script>

<style scoped>
.cap-label { margin-right: 4px; }
.cap-help { color: var(--el-text-color-placeholder); margin-left: 2px; vertical-align: middle; }
</style>
```

- [ ] **Step 11.2: Commit**

```bash
git add ScopeSentry-UI/src/views/Node/components/CapabilityEditor.vue
git commit -m "feat(ui): capability editor checkbox component"
```

---

## Task 12: 前端 - InstallCommandBox 组件 + 倒计时

**Files:**
- Create: `ScopeSentry-UI/src/views/Node/components/InstallCommandBox.vue`

- [ ] **Step 12.1: 写组件**

```vue
<!-- src/views/Node/components/InstallCommandBox.vue -->
<template>
  <div class="install-cmd-box">
    <div class="header">
      <span class="title">在新 VPS 上以 root 身份执行(Linux only):</span>
      <el-tag :type="countdownType">{{ countdown }}</el-tag>
    </div>

    <pre class="cmd"><code>{{ cmd }}</code></pre>

    <div class="actions">
      <el-button type="primary" @click="copy">
        <el-icon><CopyDocument /></el-icon> 复制命令
      </el-button>
      <el-button @click="showQR = !showQR">
        <el-icon><Picture /></el-icon> 二维码
      </el-button>
    </div>

    <transition name="el-fade-in">
      <div v-if="showQR" class="qr-wrapper">
        <vue-qrcode :value="cmd" :size="240" />
        <p class="hint">用手机扫码查看完整命令</p>
      </div>
    </transition>

    <div class="poll-status">
      <el-icon v-if="polling" class="loading"><Loading /></el-icon>
      <span>{{ pollMessage }}</span>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, onBeforeUnmount, ref } from 'vue'
import { ElButton, ElIcon, ElTag, ElMessage } from 'element-plus'
import { CopyDocument, Picture, Loading } from '@element-plus/icons-vue'
import VueQrcode from 'vue-qrcode'
import { getEnrollTokenStatus } from '@/api/node'
import type { EnrollToken } from '@/api/node/types'

const props = defineProps<{
  cmd: string
  token: string
  expiresAt: string // ISO
}>()

const emit = defineEmits<{ (e: 'consumed', payload: EnrollToken): void }>()

const showQR = ref(false)
const polling = ref(true)
const pollMessage = ref('等待节点执行命令…')

// --- countdown ---
const now = ref(Date.now())
const tickInterval = setInterval(() => (now.value = Date.now()), 1000)

const remainingMs = computed(() => Math.max(0, new Date(props.expiresAt).getTime() - now.value))

const countdown = computed(() => {
  if (remainingMs.value <= 0) return '已过期'
  const total = Math.floor(remainingMs.value / 1000)
  const m = String(Math.floor(total / 60)).padStart(2, '0')
  const s = String(total % 60).padStart(2, '0')
  return `${m}:${s}`
})

const countdownType = computed(() =>
  remainingMs.value <= 0 ? 'danger' : remainingMs.value < 60_000 ? 'warning' : 'success',
)

// --- polling ---
let pollHandle: number | undefined
onMounted(() => {
  pollHandle = window.setInterval(async () => {
    if (remainingMs.value <= 0) {
      polling.value = false
      pollMessage.value = '令牌已过期,请重新生成'
      clearInterval(pollHandle)
      return
    }
    try {
      const tk = (await getEnrollTokenStatus(props.token)) as unknown as EnrollToken
      if (tk.consumed_at) {
        polling.value = false
        pollMessage.value = `节点已上线 ✅ (来自 ${tk.consumed_by_ip})`
        emit('consumed', tk)
        clearInterval(pollHandle)
      }
    } catch {
      // ignore — token may have been revoked in another tab
    }
  }, 3000)
})

onBeforeUnmount(() => {
  clearInterval(tickInterval)
  if (pollHandle) clearInterval(pollHandle)
})

async function copy() {
  await navigator.clipboard.writeText(props.cmd)
  ElMessage.success('已复制')
}
</script>

<style scoped>
.install-cmd-box { display: flex; flex-direction: column; gap: 12px; }
.header { display: flex; justify-content: space-between; align-items: center; }
.title { color: var(--el-text-color-secondary); font-size: 13px; }
.cmd { background: var(--el-fill-color-darker); padding: 12px; border-radius: 6px; overflow-x: auto; font-family: ui-monospace, monospace; font-size: 13px; }
.actions { display: flex; gap: 8px; }
.qr-wrapper { display: flex; flex-direction: column; align-items: center; gap: 4px; padding: 12px; }
.qr-wrapper .hint { color: var(--el-text-color-placeholder); font-size: 12px; }
.poll-status { color: var(--el-text-color-regular); display: flex; gap: 6px; align-items: center; }
.loading { animation: spin 1s linear infinite; }
@keyframes spin { from { transform: rotate(0); } to { transform: rotate(360deg); } }
</style>
```

依赖 `vue-qrcode`,如果没装:

```bash
cd ScopeSentry-UI && pnpm add vue-qrcode
```

- [ ] **Step 12.2: Commit**

```bash
git add ScopeSentry-UI/package.json ScopeSentry-UI/pnpm-lock.yaml \
        ScopeSentry-UI/src/views/Node/components/InstallCommandBox.vue
git commit -m "feat(ui): install command box with countdown and consume polling"
```

---

## Task 13: 前端 - EnrollDialog 整合

**Files:**
- Create: `ScopeSentry-UI/src/views/Node/components/EnrollDialog.vue`

- [ ] **Step 13.1: 写弹窗**

```vue
<!-- src/views/Node/components/EnrollDialog.vue -->
<template>
  <el-dialog v-model="visible" title="添加扫描节点" width="640px" @close="reset">
    <el-form v-if="!result" :model="form" label-width="120px">
      <el-form-item label="节点名(可选)">
        <el-input v-model="form.intended_name" placeholder="留空则用 hostname-随机后缀" />
      </el-form-item>

      <el-form-item label="资源预算">
        <el-radio-group v-model="form.budget_template">
          <el-radio-button label="conservative">保守(12h 关机 VPS)</el-radio-button>
          <el-radio-button label="default">默认</el-radio-button>
          <el-radio-button label="aggressive">激进(高配独占)</el-radio-button>
        </el-radio-group>
      </el-form-item>

      <el-form-item label="可用模块">
        <CapabilityEditor v-model="form.capabilities" />
      </el-form-item>

      <el-form-item label="绑定来源 IP">
        <el-input v-model="form.bound_ip" placeholder="可选, 不填表示任意 IP 可使用" />
        <p class="hint">如果填了,只有从这个 IP 发起的 enroll 才能成功</p>
      </el-form-item>
    </el-form>

    <InstallCommandBox
      v-else
      :cmd="result.install_command"
      :token="result.token"
      :expires-at="result.expires_at"
      @consumed="handleConsumed"
    />

    <template #footer>
      <el-button v-if="!result" @click="visible = false">取消</el-button>
      <el-button v-if="!result" type="primary" :loading="loading" @click="submit">
        生成安装命令
      </el-button>
      <el-button v-else @click="reset">生成新命令</el-button>
    </template>
  </el-dialog>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import {
  ElDialog, ElForm, ElFormItem, ElInput, ElRadioGroup, ElRadioButton, ElButton, ElMessage,
} from 'element-plus'
import CapabilityEditor from './CapabilityEditor.vue'
import InstallCommandBox from './InstallCommandBox.vue'
import { ALL_CAPABILITIES, type Capability } from '@/api/node/types'
import { generateEnrollToken } from '@/api/node'
import type { GenerateTokenResponse, EnrollToken } from '@/api/node/types'

const visible = ref(false)
const loading = ref(false)
const result = ref<GenerateTokenResponse | null>(null)

const form = ref({
  intended_name: '',
  capabilities: [...ALL_CAPABILITIES] as Capability[],
  budget_template: 'conservative' as 'conservative' | 'default' | 'aggressive',
  bound_ip: '',
})

const emit = defineEmits<{ (e: 'enrolled', tk: EnrollToken): void }>()

defineExpose({ open: () => (visible.value = true) })

async function submit() {
  loading.value = true
  try {
    const resp = (await generateEnrollToken({
      intended_name: form.value.intended_name || undefined,
      capabilities: form.value.capabilities,
      budget_template: form.value.budget_template,
      bound_ip: form.value.bound_ip || undefined,
    })) as unknown as GenerateTokenResponse
    result.value = resp
  } catch (e) {
    ElMessage.error('生成 token 失败:' + (e as Error).message)
  } finally {
    loading.value = false
  }
}

function handleConsumed(tk: EnrollToken) {
  ElMessage.success(`节点 ${tk.issued_node_id} 已上线`)
  emit('enrolled', tk)
  // Keep dialog open so user can see the success state for a moment
}

function reset() {
  result.value = null
}
</script>

<style scoped>
.hint { color: var(--el-text-color-placeholder); font-size: 12px; margin: 4px 0 0; }
</style>
```

- [ ] **Step 13.2: 集成到 Node.vue**

修改 `src/views/Node/Node.vue`,在工具栏(节点列表上方)加按钮:

```vue
<template>
  <!-- ... existing stuff ... -->
  <el-button type="primary" :icon="Plus" @click="enrollDialog?.open()">
    添加节点
  </el-button>

  <EnrollDialog ref="enrollDialog" @enrolled="refreshNodeList" />
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { Plus } from '@element-plus/icons-vue'
import EnrollDialog from './components/EnrollDialog.vue'

const enrollDialog = ref<InstanceType<typeof EnrollDialog>>()

// existing refresh fn name in Node.vue — adjust if different
const refreshNodeList = () => { /* call your existing list-fetch */ }
</script>
```

- [ ] **Step 13.3: 本地启动 UI 看效果**

```bash
cd ScopeSentry-UI && pnpm dev
```

打开浏览器,登录,进入"节点管理",点"添加节点":
- 弹窗出现
- 填写后点"生成安装命令" → 出现 curl 命令 + 倒计时 + 二维码按钮
- 复制命令测试
- 期间在另一个终端走 curl 模拟 enroll → 弹窗轮询应该 3 秒内变成"节点已上线 ✅"

- [ ] **Step 13.4: Commit**

```bash
git add ScopeSentry-UI/src/views/Node/
git commit -m "feat(ui): enroll dialog with capability editor and live polling"
```

---

## Task 14: Decommission(节点退役)端到端

虽然原 spec 没明确要求,但**没有退役机制等于安全漏洞**——节点跑路了凭据还活着。补一下。

**Files:**
- Modify: `ScopeSentry/internal/api/handlers/node/node.go`(已有 Delete handler,补强)
- 新建: `ScopeSentry/assets/uninstall-node.sh` → 同 Task 7 同样的 embed 处理

(略,与 Task 7 结构一致;在 Plan 实施时可选做,不强制)

简化版:在现有 `Delete` handler 里调用 `DropMongoUser` + `DropRedisUser`。改动量小。

- [ ] **Step 14.1: 修改 Delete handler 增加凭据回收**

找到 `internal/api/handlers/node/node.go::Delete`,在原有逻辑后加:

```go
nodeID := req.Name // 或现有的字段名
ctx := c.Request.Context()
if err := h.deps.DropMongoUser(ctx, nodeID); err != nil {
	logger.Warnf("decommission %s: drop mongo user: %v", nodeID, err)
}
if err := h.deps.DropRedisUser(ctx, nodeID); err != nil {
	logger.Warnf("decommission %s: drop redis acl: %v", nodeID, err)
}
```

(如果 `Delete` handler 当前不在 `EnrollHandler` 里,把 deps 拆成独立 struct 或共享实例)

- [ ] **Step 14.2: Commit**

```bash
git commit -am "feat(node): drop per-node DB creds on decommission"
```

---

## Task 15: 端到端冒烟 + 文档

- [ ] **Step 15.1: 部署到一台测试 VPS,真实跑通**

1. Push 后端镜像 + 前端
2. 在管理员浏览器点"添加节点",生成 token
3. SSH 到一台空 VPS:
   ```bash
   curl -fsSL https://ctrl.example.com/install-node.sh | bash -s -- --token=ENROLL_xxx
   ```
4. 等 60 秒
5. 浏览器节点列表应出现新节点,绿点

- [ ] **Step 15.2: 写部署文档**

在 `docs/` 下新增 `node-onboarding.md`,列:
- 必要的服务端 yaml 字段(MongoPublicHost / RedisPublicHost / CtrlURL)
- HTTPS 配置(Caddy 5 行配置示例)
- 节点 VPS 最低要求(Linux + Docker)
- 故障排查(token 已用、enroll 401、container 起不来)

- [ ] **Step 15.3: Commit + Tag**

```bash
git add docs/node-onboarding.md
git commit -m "docs: node HTTP onboarding guide"
git tag v$(NEW_VERSION)-enroll-mvp
```

---

## 验收

| Task | 验收点 |
|---|---|
| 1 | EnrollToken/Capability/BudgetTemplate 编译通过 |
| 2 | 4 个 mongo provisioner 测试 PASS |
| 3 | 4 个 redis ACL provisioner 测试 PASS,密钥前缀正确 |
| 4 | 4 个 dispatcher 测试 PASS |
| 5 | 5 个 enroll handler 测试 PASS(包括 401 路径) |
| 6 | enrollstore 编译,集成测试可手动跑通 |
| 7 | shellcheck 无警告;installer_test PASS;占位符替换正确 |
| 8 | 端到端 curl 冒烟成功:生成 → enroll → 验证 mongo user 存在 → 二次用 token 拒绝 |
| 9 | 扫描器启动后 redis 看到 `node:xxx hash` 里有 `capabilities` 字段 |
| 10-13 | 浏览器手动测试:点"添加节点" → curl 命令出现 → 在 VPS 跑 → 弹窗自动变绿勾 |
| 14 | 删除节点后 mongo user 被 drop,redis ACL 被删 |
| 15 | 真实 VPS 端到端 ≤ 90 秒上线 |

---

## 安全考量(必读)

1. **HTTPS 不是可选项**。HTTP 下中间人可篡改安装脚本,你的 `curl | bash` 直接执行恶意代码。Caddy + Let's Encrypt 5 分钟搞定:
   ```
   ctrl.example.com {
     reverse_proxy localhost:8082
   }
   ```

2. **Mongo / Redis 公网端口仍然开放**。本计划走 C3(per-node 凭据)而非 C1(API gateway),所以端口暴露但凭据细粒度。建议:
   - 防火墙限白名单(已知节点 IP 段)
   - fail2ban 监控失败登录
   - Redis `requirepass` 强密码 + ACL 严格

3. **Token 泄露**:即使 15 分钟单次,泄露窗口仍然存在。缓解:
   - `bound_ip` 字段强制单 IP(默认不开,但可选用)
   - `consumed_by_ip` 审计字段记录实际使用者

4. **凭据回滚**:Mongo user 创建后,Redis 创建失败会触发 `DropMongoUser`(Step 5.3 已实现)。若 Mongo drop 也失败,留下了"孤儿 user"——建议加监控:每天扫一遍 mongo `system.users`,跟 `nodes` 集合对账,无主的 alert。

5. **`docker pull` 阶段**:installer 拉镜像如果走公开 hub,有人可以中间人替换镜像(虽然 registry 有签名)。强烈建议:
   - 用私有 registry(Harbor / ECR)+ 镜像签名
   - 或者用 image digest 而不是 tag(`autumn27/scopesentry-scan@sha256:abc...`)

---

## Self-Review

**Spec coverage:**
- 一键 curl 安装 → Task 7 ✅
- 一次性 token + 15 分钟过期 + IP 绑定 → Task 1, 5, 6 ✅
- per-node Mongo user + Redis ACL → Task 2, 3 ✅
- 能力声明 + dispatcher 过滤 → Task 4, 9 ✅
- 前端"添加节点"按钮 + 命令复制 + 实时上线反馈 → Task 11-13 ✅
- 二维码 + 倒计时 → Task 12 ✅
- 自动 docker install + jq install → Task 7 ✅
- 节点退役回收凭据 → Task 14 ✅
- HTTPS 警告 + 文档 → Task 15 ✅

**Placeholder scan:** 几处 `// existing ...` 是合理的(指向无需修改的代码),没有 TBD/TODO。Step 5.3 的 `var _ = errors.New` 占位已明确要求实施时删除。

**Type consistency:**
- `models.NodeCredentials` vs `credentials.NodeCredentials`:Task 6.1 明确说明了在 store 层翻译,handler 层用 `models.NodeCredentials`。
- `EnrollDeps` 接口与 fakeStore / Store 实现的方法签名一致(`InsertToken/FindToken/...`)。
- `Capability` 在 Go 和 TS 两侧用相同的字符串列表(Task 1.2 + Task 10.2),scanner 包不引入新类型。

---

## 与 Plan 1 / Plan 3 衔接

- **Plan 1 (节点保命)**: enroll 返回的 `budget` 直接写到 `.env`,新节点首次启动即按预算限流。Plan 1 必须先合并。
- **Plan 3 (Pull + Lease)**: Redis ACL 的 `keyPatterns` 已经把 `~scan:stream:*` `~scan:dlq:*` 包进去了,Plan 3 实施时无需重新发凭据。
- 节点 `state` (paused / emergency_cooldown) 在 dispatcher 过滤里已经被尊重 → Plan 3 改 pull 模型时,过滤逻辑直接在 consumer 端复用。

---

## 下一步

完成 Plan 2 (HTTP 一键上线) 上线 + 灰度 3 个节点稳定 1 周后,进入 **Plan 3 (Pull + Lease)**。
