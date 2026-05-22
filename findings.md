# 发现与决策

## 需求
- 用户希望为当前项目设计一版可执行的本地开发启动方案，目标是后续进行二开。
- 用户当前重新聚焦到“子域名工具对比”功能，希望明确下一步开发计划。

## 研究发现
- 当前项目实际由三个独立仓库组成：`ScopeSentry`、`ScopeSentry-Scan`、`ScopeSentry-UI`。
- `ScopeSentry` 当前是 Go 服务，不是 README 中描述的 Python/FastAPI。
- `ScopeSentry` 通过 `embed` 提供前端静态资源，生产形态偏向后端内嵌前端。
- `ScopeSentry-UI` 本地开发时运行在 `4000` 端口，并把 `/api`、`/images` 代理到 `127.0.0.1:8082`。
- `ScopeSentry` 和 `ScopeSentry-Scan` 都会以可执行文件所在目录作为配置和数据根目录，因此不适合长期依赖 `go run` 作为稳定开发方式。
- 官方单机部署依赖 MongoDB 与 Redis，且扫描端容器配置使用了 `network_mode: host`。
- 当前机器具备主要本地开发条件：Go、Node、pnpm、Docker、Docker Compose 已安装。
- 实际启动中发现 `ScopeSentry/cmd/main/` 目录下同时有 `main.go` 与 `basic_usage.go`，直接对目录执行 `go build` 会因为双 `main()` 定义失败。
- 实际启动中发现 `ScopeSentry-Scan/cmd/ScopeSentry/` 目录下同时有 `main.go`、`restructure_cmd.go` 与 `test_yaegi.go`，直接对目录执行 `go build` 会因为多处 `main()` 定义失败。
- 前端目录是“`package-lock.json` + `pnpm dev`”的混合状态，`node_modules` 可能存在但依赖树并不完整。
- Vite 前端实际可用端口为 `4001`，因为当时 `4000` 已被占用。
- 后端 `8082` 已成功返回 `200 OK`，前端 `4001` 也已返回 `200 OK`。
- 通过 `http://127.0.0.1:4001/api/swagger/doc.json` 访问到 `200 OK`，说明前端代理已成功打通后端。
- 扫描端启动后，`/api/node` 能看到 `local-dev-node`，说明节点注册链路已打通。
- `/api/node/plugin` 已返回当前节点的插件安装/检查状态；绝大多数内置插件为 `install=1, check=1`，但 `ksubdomain` 当前为 `install=1, check=0`。
- 对 `http://example.com` 投递最小任务后，`/api/task/progress/info` 显示 `TargetHandler`、`AssetMapping`、`AssetHandle` 都完成了开始/结束时间，说明任务分发和最小插件链路已被真实执行。
- 节点日志中可见 `Get a new task`、`Task begin`、以及 `TargetHandler`、`AssetMapping`、`AssetHandle`、`scan` 的开始/结束日志，说明节点取任务和模块执行链路完整。
- 本地扫描节点日志里有两类非阻断告警：`ksubdomain` 检查阶段超时，以及 `trufflehog` 将 `dictionaries` 目录当作自定义文件读取时报 warning。
- `dev-smoke.sh` 已能自动复用或后台拉起 DB、后端、扫描端，再通过 API 自动完成登录、模板创建、任务投递、进度轮询和节点日志快照。
- 子域名工具对比当前已经具备后端聚合接口、明细接口、前端对比标签页、明细弹窗搜索/复制/导出、任务运行中自动刷新。
- 子域名工具对比的主要可用性问题里，“明细分页被表格挤出可视区”已修复。
- 当前下一阶段不缺基础功能，更缺真实任务数据下的验收、交互细节补齐，以及大任务量下的性能与查询成本控制。
- 扫描模板页、计划任务页、页面监控页仍保留旧的表格高度计算逻辑：`maxHeight` 初始值为 `0`，且只有 `onMounted` 没有 `onActivated`，在暗黑模式或 keep-alive 激活场景下会复现“有总数但表格不显示”的问题。
- 该问题和之前任务列表页是同一类根因，统一修复模式是：给表格设置非零默认高度、激活页面时重新计算高度、卸载时移除 `resize` 监听。
- PortScan Redis Streams + Lease + DLQ 已经落地为可复用模式，核心文件包括 `ScopeSentry/internal/services/streamdispatch/*`、`ScopeSentry/internal/models/stream_task.go`、`ScopeSentry-Scan/internal/streamtask/*` 和 `ScopeSentry-UI/src/views/Task/components/PortChunkProgress.vue`。
- 当前扫描链路仍是 `TargetHandler -> SubdomainScan -> SubdomainSecurity -> PortScanPreparation -> PortScan`，SubdomainScan stream 化必须保证严格阶段顺序。
- `TargetHandler` 的规范化输出当前主要通过内存 channel 传给 `SubdomainScan`，服务端无法直接从原始 target 准确规划子域名 chunk，因此需要新增 `stream_stage_inputs` 持久化根域名和透传目标。
- SubdomainScan 插件实例存在可变状态写入，例如参数、结果 channel、任务 ID，因此 v1 需要用插件级锁避免同一节点并发执行同一个插件实例。
- SubdomainScan stream chunk v1 的低风险拆分规则是 `1 root domain + 1 plugin = 1 chunk`，暂不做字典 sharding。
- SubdomainScan DLQ 应默认阻塞下游；用户手动 ignore 后才允许以部分结果继续。
- SubdomainScan stream chunk 已落地为 opt-in 能力，服务端严格等 TargetHandler 完成并持久化 `stream_stage_inputs` 后再规划 SubdomainScan chunks，等 SubdomainScan chunks 全部终态且无未忽略 DLQ 后才进入下游。
- SubdomainScan chunk timeout 不能只留在 Redis message；扫描端执行插件前需要转换成插件参数。当前规则是秒数向上取整为分钟，`subfinder`/`shuffledns`/`oneforall` 使用 `-timeout`，`puredns`/`ksubdomain` 使用 `-et`，模板已显式设置 `-timeout` 或 `-et` 时不覆盖。
- 当前本地运行端口已统一回 `8080/4000`：Vite dev server 使用 `4000`，代理目标是 `127.0.0.1:8080`；后端 compose 暴露 `8080:8080`；脚本默认 `BACKEND_URL=http://127.0.0.1:8080`。
- `pnpm run ts:check` 仍存在全仓既有类型问题，主要包括未使用导入、`Asset/asset` 文件大小写冲突、Element Plus `ISelectProps` 不存在、部分旧页面 props/返回值类型不匹配；本轮新增的 Stream chunk UI 定向 ESLint 和生产构建已通过。

## 技术决策
| 决策 | 理由 |
|------|------|
| 本地开发优先考虑“数据库容器化 + 服务源码运行” | 兼顾开发反馈速度与依赖稳定性 |
| 后续方案重点围绕固定 `bin/` 目录启动 Go 服务设计 | 避免配置和数据目录写到临时路径 |
| 最终将运行时目录改为工作区根目录 `.local-dev/` | 比各仓自己的 `bin/` 更干净，便于统一清理 |
| 交付物同时包含 `LOCAL_DEV_SETUP.md` 和 `scripts/` 下的启动脚本 | 既能说明原理，也能直接执行 |
| 扫描端维持“按需启动”，不纳入默认三步本地开发流 | 大部分 UI/API 二开不需要扫描端，能减少噪音和排错成本 |
| `dev-server.sh` 应按 `goreleaser` 声明的 `./cmd/main/main.go` 作为构建入口 | 这与仓库当前发布配置一致 |
| 在本地脚本中使用 `.local-dev/go-build-cache` 与 `.local-dev/go-mod-cache` | 避免对全局 Go 缓存路径产生隐式依赖 |
| `dev-smoke.sh` 不默认启动 UI，只聚焦后端与扫描链路 smoke | 避免把 UI 端口探测和 Vite 生命周期混进扫描链路验证，职责更清晰 |
| 子域名对比下一阶段优先做验收和收口，而不是立即增加新统计维度 | 先把已有链路做稳，能更快得到真实使用反馈 |
| 表格列表页的高度问题按统一模式修复，不单独做暗黑模式特判 | 根因是高度初始化和激活时机，不是主题样式本身 |
| SubdomainScan Stream Chunk 先做 v1，不做字典切片 | root domain/plugin 粒度已经能提升多节点可靠性和可观测性，且更容易复用 PortScan 的 lease/DLQ 模式 |
| 严格阶段模式优先于流水线模式 | 用户明确担心子域名未跑完就进入端口扫描，严格模式更符合当前扫描语义 |
| 新增 `stream_stage_inputs` 而不是从原始 target 重算 | 避免 TargetHandler 中 URL、CIDR、公司、APP、直连子域名等类型转换在服务端重复实现并产生偏差 |
| UI 侧将 PortChunkProgress 泛化为 StreamChunkProgress | 后续 SubdomainScan 和 PortScan 都能复用 DLQ/重试/忽略/摘要显示 |
| SubdomainScan chunk timeout 只注入已知内置/模板插件 | 自定义插件参数语义不可知，强行追加未知 flag 可能破坏执行；未知插件先保持模板参数不变 |
| DLQ 默认继续阻塞但提供 ignore | 保留可靠性优先的默认行为，同时允许用户确认风险后以部分结果继续下游 |
| 当前 worktree 保留用于后续集成 | 三个子仓都有大量未提交 baseline 改动，直接清理或自动合并风险较高，后续应单独执行合回/推送步骤 |

## 遇到的问题
| 问题 | 解决方案 |
|------|---------|
| README 技术栈与当前代码不一致 | 以代码和当前配置为准，不按旧文档直接推断 |
| `pnpm dev` 启动时报 `Could not resolve "codemirror"` | 重装前端依赖并将脚本从“检查 node_modules 是否存在”改为“检查 node_modules/.pnpm 是否存在” |
| 后端脚本原始构建目标 `./cmd/main` 无法通过编译 | 调整为 `./cmd/main/main.go` |
| 扫描端脚本原始构建目标 `./cmd/ScopeSentry` 无法通过编译 | 调整为 `./cmd/ScopeSentry/main.go` |
| `ksubdomain` 在本地节点初始化检查阶段超时 | 当前不影响节点注册和最小任务链路，作为后续插件专项调试项保留 |
| Subdomain chunk timeout 最初未传递到插件参数 | 在 `ScopeSentry-Scan/internal/streamtask/handler.go` 增加 `applySubdomainChunkTimeout`，并用测试覆盖 subfinder、puredns、显式 timeout 和 `--timeout=30` 语法 |
| `rg 8082|4001` 会命中大量无关内容 | 区分当前运行配置与历史/测试数据/端口字典；当前配置文件和脚本默认值已核对为 `8080/4000` |

## 资源
- `ScopeSentry/README_CN.md`
- `ScopeSentry/cmd/main/main.go`
- `ScopeSentry/internal/config/config.go`
- `ScopeSentry/single-host-deployment.yml`
- `ScopeSentry-Scan/internal/config/config.go`
- `ScopeSentry-Scan/internal/plugins/plugins.go`
- `ScopeSentry-Scan/modules/manage.go`
- `ScopeSentry-UI/vite.config.ts`
- `ScopeSentry-UI/package.json`
- `LOCAL_DEV_SETUP.md`
- `scripts/dev-db-up.sh`
- `scripts/dev-server.sh`
- `scripts/dev-ui.sh`
- `scripts/dev-scan.sh`
- `scripts/dev-smoke.sh`
- `scripts/dev-sync-ui-static.sh`
- `ScopeSentry/internal/services/task/task/task.go`
- `ScopeSentry/internal/models/task.go`
- `ScopeSentry/internal/api/handlers/task/task.go`
- `ScopeSentry-UI/src/views/Task/components/SubdomainToolComparison.vue`
- `ScopeSentry-UI/src/views/Task/components/ProgressInfo.vue`
- `ScopeSentry-UI/src/views/Task/components/StreamChunkProgress.vue`
- `ScopeSentry-Scan/internal/streamtask/handler.go`
- `docs/superpowers/plans/2026-05-22-subdomain-stream-chunk-scheduling.md`

## 视觉/浏览器发现
- 本任务目前不涉及视觉材料。

---
*每执行2次查看/浏览器/搜索操作后更新此文件*
*防止视觉信息丢失*
