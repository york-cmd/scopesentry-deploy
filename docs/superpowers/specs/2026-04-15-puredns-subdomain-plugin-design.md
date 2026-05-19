# puredns Subdomain Plugin Design

## Goal

为 `ScopeSentry-Scan` 增加一个内置 `SubdomainScan` 插件 `puredns`，用于基于现有任务子域名字典对单个根域名执行字典爆破，并输出经过 `puredns` 解析验证后的子域名结果。

## Scope

第一版只覆盖以下能力：

- 插件类型：内置插件
- 模块：`SubdomainScan`
- 输入：单个根域名字符串
- 扫描方式：字典爆破
- 字典来源：复用现有任务参数中的 `subfile`
- 运行环境：Linux 扫描容器
- 依赖：`puredns`、`massdns`、默认 resolvers 文件

不包含以下能力：

- `resolve` 模式
- 自定义 trusted resolvers / wildcard resolvers
- 自定义 rate-limit
- Windows / macOS 扫描端支持
- 运行时动态下载依赖
- 多种子域名字典来源并存

## Architecture

插件本身仍然是 Go 插件壳，风格对齐现有 `ksubdomain`。实际爆破由外部命令 `puredns bruteforce` 完成，`puredns` 依赖 `massdns` 做解析与校验。插件负责：

- 读取任务参数
- 生成临时输入输出文件
- 执行外部命令
- 解析命令结果
- 将每个结果转换为现有 `SubdomainResult`

`puredns`、`massdns` 和默认 resolvers 文件直接打进扫描镜像，以避免热插件或运行时下载造成的环境漂移。

## Files

### New or Modified

- Create: `ScopeSentry-Scan/modules/subdomainscan/puredns/puredns.go`
- Modify: `ScopeSentry-Scan/internal/plugins/plugins.go`
- Modify: `ScopeSentry-Scan/dockerfile`
- Create: `ScopeSentry-Scan/tools/linux/puredns`
- Create: `ScopeSentry-Scan/tools/linux/massdns`
- Create: `ScopeSentry-Scan/tools/config/puredns-resolvers.txt`

### Tests

- Create: `ScopeSentry-Scan/modules/subdomainscan/puredns/puredns_test.go`
- Modify: `ScopeSentry-Scan/internal/plugins/plugins_test.go`

## Plugin Behavior

### Plugin Identity

- Name: `puredns`
- Module: `SubdomainScan`
- PluginId: 新增固定 ID

### Install

`Install()` 负责：

- 确保 `global.ExtDir/puredns` 运行目录存在
- 确保临时输入输出目录存在
- 检查 `/apps/ext/puredns/puredns`、`/apps/ext/puredns/massdns`、默认 resolvers 文件是否存在

第一版不做下载逻辑；缺依赖直接报错。

### Check

`Check()` 负责：

- 检查二进制是否存在且可执行
- 以轻量方式验证 `puredns` 命令可调用

第一版不做真实爆破检查，只做存在性和版本/帮助输出级别检查。

### Execute

`Execute(input)` 流程：

1. 读取根域名字符串
2. 从现有参数里读取 `subfile`
3. 将字典路径定位到现有字典目录
4. 构造 `puredns bruteforce` 命令：
   - 目标根域名
   - `subfile`
   - `massdns` 路径
   - 默认 resolvers 文件路径
   - 输出文件路径
5. 在任务上下文内执行命令
6. 读取结果文件，每行一个子域名
7. 对每个子域名调用现有 DNS 工具，生成 `SubdomainResult`
8. 将结果写入当前 `Result` channel

### Parameters

第一版只支持两个参数：

- `subfile`: 子域名字典文件名，必填
- `et`: 执行超时，单位秒，可选

没有 `subfile` 直接记录错误并返回。

## Container Packaging

扫描镜像需要新增：

- `/apps/ext/puredns/puredns`
- `/apps/ext/puredns/massdns`
- `/apps/ext/puredns/resolvers.txt`

`dockerfile` 需要：

- 创建 `/apps/ext/puredns`
- `COPY` 三类依赖
- 赋可执行权限

## Result Model

插件不引入新结果类型，继续使用现有 `types.SubdomainResult`。

这样可以无缝接到：

- 去重逻辑
- Mongo 写入
- 下游 `SubdomainSecurity`

## Error Handling

第一版需要明确区分：

- 参数缺失
- 二进制缺失
- resolvers 文件缺失
- 外部命令执行失败
- 结果文件为空

错误以插件日志为主，不要求把整批扫描直接中断到全局任务失败。

## Testing

### Unit Tests

- 插件注册测试：确认 `puredns` 被注册到 `SubdomainScan`
- 参数测试：缺少 `subfile` 时返回合理错误
- 命令拼装测试：验证命令参数含 `bruteforce`、目标域名、字典、massdns、resolvers、超时
- 输出解析测试：从模拟结果文件恢复 `SubdomainResult`

### Packaging Checks

- 扫描镜像构建路径包含 `puredns`、`massdns`、resolvers

## Non-Goals

- 不做多模式支持
- 不做运行时下载
- 不做热插件版本
- 不做高级 resolver / wildcard 控制
