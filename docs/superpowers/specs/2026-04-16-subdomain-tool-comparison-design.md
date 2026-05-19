# Subdomain Tool Comparison Design

## Goal

支持“按任务比较不同子域名工具效果”，包括：

- 每个插件在单个任务中发现的子域名数量
- 各插件结果并集数量
- 各插件独有数量
- 各插件两两交集数量

第一阶段只提供后端统计接口，不做前端展示面板。

## Problem Statement

当前 `SubdomainScan` 结果链路会在写库前对 `host` 做任务内去重，因此无法仅靠现有 `subdomain` 主表判断：

- 某个子域名是由哪个插件发现的
- 同一个子域名是否被多个插件同时发现

现有 `SubdomainResult` 也没有来源字段，当前去重会直接抹掉“多工具命中同一子域名”的事实。

## Chosen Approach

引入**发现事件表**，而不是直接让主 `subdomain` 表承担统计职责。

### New Collection

新增集合：

- `subdomain_discovery_events`

每条记录表示：

- 某任务
- 某插件
- 发现了某个子域名

主 `subdomain` 表继续保持当前“去重后的资产结果”职责。

## Data Model

### Discovery Event

建议字段：

- `taskId`
- `taskName`
- `pluginHash`
- `pluginName`
- `module`
- `host`
- `rootDomain`
- `time`

索引建议：

- 唯一索引：`taskId + pluginHash + host`
- 查询索引：`taskId`

### Existing Result

`SubdomainResult` 第一阶段只需要增加来源字段以便在扫描链路中传递：

- `SourcePlugin`
- `SourcePluginHash`

这些字段用于写事件表，不要求立刻写入主 `subdomain` 集合。

## Write Path

在 `SubdomainScan` 模块中：

1. 插件返回 `SubdomainResult`
2. 在进入现有任务内去重逻辑前，先写 discovery event
3. 再按现有逻辑决定是否进入主 `subdomain` 资产链路

这样即使：

- `subfinder` 先发现 `a.example.com`
- `puredns` 后发现同一域名

也会留下两条事件记录，但主表只保留一条最终资产。

## API Scope

第一阶段新增一个任务维度统计接口，例如：

- `POST /api/task/subdomain/tool-comparison`

请求：

- `taskId`

返回建议包含：

- `plugins`: 每个插件的发现数量
- `unionCount`: 所有插件并集数量
- `exclusiveCounts`: 每个插件独有数量
- `pairwiseIntersections`: 两两交集数量

返回形态可以是：

- 纯统计 JSON
- 不返回完整域名列表

第一阶段先以统计汇总为主，差异明细文件或完整域名列表可以第二阶段再补。

## Aggregation Rules

以 `host` 为集合元素进行比较：

- 插件数量：`count(distinct host where taskId + pluginHash)`
- 并集：`count(distinct host where taskId)`
- 独有：仅被一个插件命中的 `host`
- 两两交集：同时被两个指定插件命中的 `host`

## Files

### Likely Changes

- `ScopeSentry-Scan/internal/types/types.go`
- `ScopeSentry-Scan/modules/subdomainscan/module.go`
- `ScopeSentry-Scan/internal/results/handler.go` or new repository/service helper on scan side
- `ScopeSentry/internal/models/task.go`
- `ScopeSentry/internal/services/task/task/task.go`
- `ScopeSentry/internal/api/handlers/task/task.go`
- `ScopeSentry/internal/api/routes/task/task.go`
- `ScopeSentry/internal/database/mongodb/initdb.go` or index bootstrap path

### Tests

- 扫描端：事件写入测试
- 服务端：聚合统计测试
- 接口层：请求/响应测试

## Non-Goals

- 不做前端页面
- 不做跨任务全局统计
- 不做主 `subdomain` 表结构大改
- 不做差异明细下载文件

## Why This Approach

这个方案的优点是：

- 不破坏现有主资产去重模型
- 能完整保留“某插件发现过某子域名”的事实
- 后续做前端图表、导出和趋势统计都建立在可扩展的数据模型上
