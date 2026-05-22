# 任务计划：ScopeSentry 本地开发启动方案

## 目标
为 `ScopeSentry`、`ScopeSentry-Scan`、`ScopeSentry-UI` 制定一套适合当前仓库状态的本地开发启动方案，并在必要时落成文档或脚本。

## 当前阶段
阶段 9

## 各阶段

### 阶段 1：需求与发现
- [x] 理解用户意图
- [x] 确定约束条件和需求
- [x] 将发现记录到 findings.md
- **状态：** complete

### 阶段 2：规划与结构
- [x] 确定技术方案
- [x] 明确本地启动流程的交付形式
- [x] 记录决策及理由
- **状态：** complete

### 阶段 3：实现
- [x] 按计划逐步执行
- [x] 如有需要创建文档或辅助脚本
- [x] 增量验证
- **状态：** complete

### 阶段 4：测试与验证
- [x] 验证所有需求已满足
- [x] 将测试结果记录到 progress.md
- [x] 修复发现的问题
- **状态：** complete

### 阶段 5：交付
- [x] 检查所有输出文件
- [x] 确保交付物完整
- [x] 交付给用户
- **状态：** complete

### 阶段 6：子域名对比功能迭代规划
- [x] 盘点当前已完成能力与已修复问题
- [x] 明确下一步优先级与阶段目标
- [x] 修复同类表格高度回归在模板页/计划任务页/页面监控页上的复现
- [ ] 按计划推进交互补齐、运行态验证与性能收口
- **状态：** in_progress

### 阶段 7：SubdomainScan Stream Chunk 开发计划
- [x] 确认产品决策：严格阶段模式、SubdomainScan v1、root domain x plugin chunk、DLQ 默认阻塞
- [x] 复查现有 PortScan Stream Chunk、扫描链路、SubdomainScan 模块与 UI 进度组件
- [x] 编写详细开发计划，覆盖服务端、扫描端、UI、脚本、测试和上线回滚
- [x] 自检计划覆盖度、占位内容、类型命名和文件路径
- **状态：** complete

### 阶段 8：SubdomainScan Stream Chunk 实现
- [x] 在隔离 worktree `feature/subdomain-stream-chunk` 中落地 SubdomainScan stream chunk v1
- [x] 服务端复用 PortScan 的 Redis Streams + Lease + DLQ 模型，新增 SubdomainScan stage-aware chunk、API、summary/DLQ/retry/ignore 能力
- [x] 扫描端新增 SubdomainScan stream consumer、chunk runner、legacy bypass、downstream resume 和 chunk timeout 注入
- [x] UI 泛化 StreamChunkProgress，并在任务进度中展示 SubdomainScan chunk 与 PortScan chunk
- [x] 本地脚本补充 Subdomain stream 开关、timeout、dry-run smoke 与环境变量验证
- [x] 端口配置核对为 `8080` 后端和 `4000` 前端，不再使用 `8082`/`4001` 作为当前运行配置
- [x] 完成 Go 定向测试、UI ESLint、UI 生产构建、脚本验证与 diff 空白检查
- **状态：** complete

### 阶段 9：Stream 运维化路线与 P0 脚本
- [x] 确认后续路线：P0 状态确认脚本、P1 健康看板、P2 任务控制、P3 节点容量治理、P4 其他模块分片
- [x] 增强 `enable-stream-task.sh`，新增 `doctor` 并修复扫描端运行时配置提示
- [x] 覆盖服务端/扫描端 Stream env、UI bundle、Redis Streams、Mongo chunk/DLQ 的脚本测试
- [x] 新增 Stream 运维化路线文档
- [ ] 将 P0 脚本提交并同步到远程 deploy 仓库
- [ ] 进入 P1 Stream 任务健康看板开发
- **状态：** in_progress

## 关键问题
1. 本地开发方案是否需要只给文档，还是要顺手落成启动脚本/README。
2. 用户当前二开的重点是 UI/API，还是扫描链路与插件。

## 已做决策
| 决策 | 理由 |
|------|------|
| 先梳理现有三仓职责与运行边界，再设计本地方案 | 当前仓库文档与代码实现存在偏差，先澄清实际结构 |
| 使用项目根目录规划文件持续记录方案和发现 | 这是一个多步骤研究与规划任务 |
| 本地启动方案以根目录文档加最小脚本形式交付 | 用户希望继续推进，直接落地比纯建议更可执行 |
| 推荐“数据库容器化 + Go 服务宿主机运行 + 前端 Vite dev” | 在当前代码结构下，这是反馈速度和运行稳定性的平衡点 |
| Go 服务运行时统一落到根目录 `.local-dev/` | 避免把配置和上传目录污染进各子仓源码目录 |
| `dev-server.sh` 改为编译 `./cmd/main/main.go` | 仓库中 `cmd/main/` 额外存在 `basic_usage.go`，直接编整个目录会因双 `main()` 失败 |
| Go 构建缓存和模块缓存统一写入 `.local-dev/` | 提高本地脚本可重复性，避免依赖全局缓存路径 |
| `dev-ui.sh` 改为检查 `node_modules/.pnpm` | `node_modules` 目录存在但依赖树不完整时，原脚本会误判为已安装 |
| `dev-scan.sh` 改为编译 `./cmd/ScopeSentry/main.go` | 扫描端入口目录同样混有额外 `main()` 文件，按目录构建会失败 |
| 使用 `example.com + httpx/WebFingerprint` 作为最小扫描验证链路 | 能在不引入高风险目标的前提下验证任务分发与插件执行 |
| 新增 `dev-smoke.sh` 串起节点注册、模板创建、任务分发与进度轮询 | 把人工验证步骤收成一个可重复的一键 smoke 流程 |
| 新增 `dev-scan-docker.sh` 与本地 Docker compose | 在 macOS 上让扫描工具运行于 Linux 容器，规避宿主机工具兼容性问题 |
| `dev-smoke.sh` 在 Darwin 默认优先走 Docker 扫描端 | 降低 macOS 本地验证端口扫描链路时的误报和空结果概率 |
| `dev-smoke.sh` 默认扫描驱动改为 Docker | 让 smoke 在各平台都优先走容器化扫描节点，避免误起宿主机节点 |
| 新增 `dev-scan-docker-build.sh` | 给扫描端二开提供“源码改动 -> Linux 二进制 -> 本地镜像 -> Docker 节点重启”的快速回归路径 |
| 子域名对比功能下一阶段先做“真实任务验证 + 交互补齐 + 性能收口” | 当前基础能力已具备，继续堆新功能前应先把可用性和稳定性收紧 |
| SubdomainScan chunk v1 采用 `1 root domain + 1 plugin = 1 chunk` | 先解决多节点可靠分配、租约重试和 DLQ，避免一开始引入字典切片导致复杂度过高 |
| SubdomainScan stream 模式保持 opt-in，旧链路保留 | 降低上线风险，可以先在本地和少量节点验证 |
| SubdomainScan 采用严格阶段模式 | 保证 PortScan 等下游不会在子域名阶段未终态前提前开始 |
| TargetHandler 输出需要持久化到 `stream_stage_inputs` | 旧链路依赖内存 channel，服务端要规划子域名 chunk 必须拿到规范化后的根域名和透传目标 |
| v1 不让同一节点并发运行同一个 SubdomainScan 插件实例 | 当前插件会调用 `SetParameter`、`SetResult`、`SetTaskId`，插件实例可变，并发复用风险较高 |
| SubdomainScan chunk timeout 注入到内置插件参数 | `timeoutSec` 只在队列消息里存在还不够，执行插件时必须转成 `-timeout` 或 `-et` 才能约束长时间运行 |
| 当前本地运行端口固定为后端 `8080`、前端 `4000` | 用户明确不要继续使用 `8082`/`4001`，当前 Vite proxy、compose 和脚本默认值均按该端口核对 |
| Stream 后续按默认模式演进，不再优先做 UI 开关 | 用户确认后期肯定都是 Stream 模式，P0 重点回到上线状态确认脚本 |
| P1 优先做健康看板，再做控制和容量治理 | 先解决“任务为什么跑很久”的可观测问题，再给操作入口，降低误操作风险 |

## 遇到的错误
| 错误 | 尝试次数 | 解决方案 |
|------|---------|---------|
| 前端依赖树残留 npm 安装，`pnpm dev` 缺少 `codemirror` | 1 | 通过 `pnpm install` 重建依赖，并调整脚本检测方式 |
| `go build ./cmd/main` 因 `basic_usage.go` 与 `main.go` 双入口失败 | 1 | 改为按官方构建入口 `./cmd/main/main.go` 编译 |

## 备注
- `ScopeSentry`、`ScopeSentry-Scan`、`ScopeSentry-UI` 是三个独立 git 仓库。
- 后端与扫描端都依赖可执行文件目录创建配置和数据目录，本地运行方式需要围绕这一点设计。
- 已创建 `LOCAL_DEV_SETUP.md` 与 `scripts/` 下的辅助脚本。
- 子域名对比功能当前已具备摘要接口、明细接口、前端对比页、明细搜索/复制/导出、运行中自动刷新与分页弹窗修复。
