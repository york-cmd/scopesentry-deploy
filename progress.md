# 进度日志

## 会话：2026-03-27

### 阶段 1：需求与发现
- **状态：** in_progress
- **开始时间：** 2026-03-27
- 执行的操作：
  - 读取项目根目录下三个子仓库的 README、依赖定义、主入口和配置加载逻辑。
  - 确认前端开发代理、后端端口、数据库依赖、本地目录写入方式和插件/模块扩展点。
  - 检查本机 Go、Node、pnpm、Docker 与 Docker Compose 是否可用。
- 创建/修改的文件：
  - `task_plan.md`
  - `findings.md`
  - `progress.md`

### 阶段 2：规划与结构
- **状态：** complete
- 执行的操作：
  - 将本地开发方案收口为“混合开发模式”。
  - 确定交付形式为根目录文档加最小启动脚本。
  - 将运行时目录统一规划到 `.local-dev/`。
- 创建/修改的文件：
  - `task_plan.md`
  - `findings.md`
  - `progress.md`

## 会话：2026-03-30

### 阶段 3：实现
- **状态：** complete
- **开始时间：** 2026-03-30
- 执行的操作：
  - 新增 `LOCAL_DEV_SETUP.md`，整理本地开发模式、启动顺序、运行目录、常见问题和建议流程。
  - 新增 `scripts/dev-db-up.sh`、`scripts/dev-server.sh`、`scripts/dev-ui.sh`、`scripts/dev-scan.sh`、`scripts/dev-sync-ui-static.sh`。
  - 将主服务和扫描端脚本设计为构建到 `.local-dev/` 后再运行，避免运行时文件污染源码目录。
- 创建/修改的文件：
  - `LOCAL_DEV_SETUP.md`
  - `scripts/dev-db-up.sh`
  - `scripts/dev-server.sh`
  - `scripts/dev-ui.sh`
  - `scripts/dev-scan.sh`
  - `scripts/dev-sync-ui-static.sh`
  - `task_plan.md`
  - `findings.md`
  - `progress.md`

### 阶段 4：测试与验证
- **状态：** complete
- 执行的操作：
  - 为新增脚本补充执行权限。
  - 运行 `bash -n` 做语法校验。
  - 核对最终交付文件列表。
- 创建/修改的文件：
  - `scripts/dev-db-up.sh`
  - `scripts/dev-server.sh`
  - `scripts/dev-ui.sh`
  - `scripts/dev-scan.sh`
  - `scripts/dev-sync-ui-static.sh`
  - `task_plan.md`
  - `findings.md`
  - `progress.md`

## 会话：2026-03-31

### 阶段 4：测试与验证
- **状态：** complete
- **开始时间：** 2026-03-31
- 执行的操作：
  - 实际启动 `MongoDB` 和 `Redis` 容器，并确认两者 `healthy`。
  - 实际重装前端依赖，修复 `codemirror` 缺失问题。
  - 实际编译后端二进制，定位 `cmd/main` 双 `main()` 问题并修正脚本构建入口。
  - 启动后端二进制与前端 Vite 服务，并验证 `8082`、`4001`、以及 `/api` 代理链路。
  - 实际复现扫描端 `cmd/ScopeSentry` 多 `main()` 编译失败，并将扫描端脚本构建入口修正为 `./cmd/ScopeSentry/main.go`。
  - 补充文档和脚本，固化本轮真实启动时遇到的坑。
- 创建/修改的文件：
  - `scripts/dev-server.sh`
  - `scripts/dev-scan.sh`
  - `scripts/dev-ui.sh`
  - `LOCAL_DEV_SETUP.md`
  - `task_plan.md`
  - `findings.md`
  - `progress.md`

## 测试结果
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| 工具链检查 | `go version` / `node -v` / `pnpm -v` / `docker --version` / `docker compose version` | 本地具备基本开发工具链 | 已确认均可用 | pass |
| 脚本语法检查 | `bash -n scripts/dev-db-up.sh scripts/dev-server.sh scripts/dev-ui.sh scripts/dev-scan.sh scripts/dev-sync-ui-static.sh` | 所有脚本语法合法 | 命令退出码为 0 | pass |
| 脚本权限检查 | `ls -l scripts` | 新增脚本具备可执行权限 | 5 个脚本均为 `-rwxr-xr-x` | pass |
| 交付物检查 | `find . -maxdepth 2 \\( -name 'LOCAL_DEV_SETUP.md' -o -path './scripts/*' \\) | sort` | 文档与脚本均存在 | 已确认 1 份文档和 5 个脚本 | pass |
| Docker 容器状态 | `docker compose -f ScopeSentry/single-host-deployment.yml ps` | MongoDB/Redis 启动且 healthy | 两个容器均为 `Up ... (healthy)` | pass |
| 前端依赖修复 | `pnpm install` | 缺失依赖补齐 | `codemirror 6.0.2` 已安装，安装命令退出码为 0 | pass |
| 后端编译验证 | `go build -o .local-dev/scope-sentry/scope-sentry-dev ./cmd/main/main.go` | 后端二进制可编译 | 命令退出码为 0 | pass |
| 扫描端编译验证 | `go build -o .local-dev/scope-scan/scopesentry-scan-dev ./cmd/ScopeSentry/main.go` | 扫描端二进制可编译 | 扫描端已按该入口成功启动 | pass |
| 后端 HTTP 可用性 | `curl -I http://127.0.0.1:8082` | 返回 `200 OK` | 已返回 `HTTP/1.1 200 OK` | pass |
| 前端 HTTP 可用性 | `curl -I http://127.0.0.1:4001` | 返回 `200 OK` | 已返回 `HTTP/1.1 200 OK` | pass |
| 前后端代理联通 | `curl -i http://127.0.0.1:4001/api/swagger/doc.json` | 通过前端代理访问后端 swagger JSON | 已返回 `HTTP/1.1 200 OK` 和 Swagger 文档 | pass |

## 会话：2026-04-01

### 阶段 4：测试与验证
- **状态：** complete
- **开始时间：** 2026-04-01
- 执行的操作：
  - 重新确认扫描端入口与官方 `.goreleaser.yaml` 一致，按 `./cmd/ScopeSentry/main.go` 成功拉起本地扫描节点。
  - 通过 `/api/user/login`、`/api/node`、`/api/node/plugin` 验证节点注册与插件状态。
  - 新建最小模板 `local-dev-httpx-20260401-105941`，启用 `AssetMapping/httpx` 与 `AssetHandle/WebFingerprint`。
  - 向 `local-dev-node` 投递 `http://example.com` 任务，验证任务分发、节点取任务、模块执行、任务完成计数。
  - 读取 `/api/task/progress/info` 与 `/api/node/log`，确认 `TargetHandler`、`AssetMapping`、`AssetHandle` 链路有真实执行痕迹。
  - 新增 `scripts/dev-smoke.sh`，把 DB/后端/扫描端复用或启动、登录、模板创建、任务投递和进度轮询固化成一键 smoke。
  - 实际运行 `./scripts/dev-smoke.sh`，确认脚本能自动跑通一轮 `example.com` 验证并输出运行目录、密码、日志路径和任务进度。
- 创建/修改的文件：
  - `scripts/dev-smoke.sh`
  - `scripts/dev-scan.sh`
  - `LOCAL_DEV_SETUP.md`
  - `task_plan.md`
  - `findings.md`
  - `progress.md`

## 测试结果补充
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| 节点注册验证 | `GET /api/node` | 出现本地扫描节点 | 已返回 `local-dev-node`，状态为 `1` | pass |
| 节点插件状态验证 | `POST /api/node/plugin` | 返回节点插件安装/检查信息 | 内置插件状态已返回，`ksubdomain` 为 `check=0`，其余最小链路插件正常 | pass |
| 最小模板验证 | `POST /api/task/template/save` + `POST /api/task/template/detail` | 可创建并读回最小扫描模板 | 已读回 `AssetMapping=httpx`、`AssetHandle=WebFingerprint` | pass |
| 任务分发验证 | `POST /api/task/add` | 本地节点领取任务并开始执行 | 节点日志出现 `Get a new task` 和 `Task begin` | pass |
| 任务进度验证 | `POST /api/task/progress/info` | 返回模块开始/结束时间 | `TargetHandler`、`AssetMapping`、`AssetHandle`、`All` 均有开始/结束时间 | pass |
| 节点完成计数验证 | `GET /api/node` | `finished` 增加 | `local-dev-node.finished = 1` | pass |
| smoke 脚本语法验证 | `bash -n scripts/dev-smoke.sh` | 新增脚本语法合法 | 命令退出码为 0 | pass |
| smoke 脚本实跑验证 | `./scripts/dev-smoke.sh` | 自动跑通本地扫描 smoke | 已输出 `smoke passed`、任务 ID、运行目录、密码、日志路径、任务进度 | pass |

### 阶段 3：实现
- **状态：** complete
- **开始时间：** 2026-04-01
- 执行的操作：
  - 新增 `scripts/dev-scan-docker.sh`，为本地开发封装扫描端 Docker 启动、停止、日志与 compose 环境注入。
  - 新增 `scripts/dev-scan-docker-compose.yml`，把扫描端容器改为通过 `host.docker.internal` 回连宿主机 MongoDB/Redis。
  - 扩展 `scripts/dev-smoke.sh`，在 macOS 上默认优先走 Docker 扫描端，并支持 `SCAN_DRIVER=docker|host` 显式切换。
  - 更新 `LOCAL_DEV_SETUP.md`，把扫描端 Docker 本地开发模式、镜像覆盖方式和使用场景写入文档。
- 创建/修改的文件：
  - `scripts/dev-scan-docker.sh`
  - `scripts/dev-scan-docker-compose.yml`
  - `scripts/dev-smoke.sh`
  - `LOCAL_DEV_SETUP.md`
  - `task_plan.md`
  - `progress.md`

## 测试结果补充（Docker 扫描端）
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| Docker 扫描端脚本语法验证 | `bash -n scripts/dev-scan-docker.sh scripts/dev-smoke.sh` | 新增脚本语法合法 | 命令退出码为 0 | pass |
| Docker compose 配置展开 | `./scripts/dev-scan-docker.sh config` | 正确展开容器环境变量和挂载目录 | 已展开 `host.docker.internal`、`.local-dev/scope-scan-docker/*` 挂载与默认节点名 | pass |
| 本地镜像缓存检查 | `docker image ls autumn27/scopesentry-scan:latest` | 如已缓存则可直接启动 | 无输出，说明本地未缓存该镜像 | pass |
| Docker 扫描端实跑验证 | `./scripts/dev-scan-docker.sh up` | 拉起扫描端容器并准备注册节点 | 宿主机 Docker 访问 `registry-1.docker.io` 超时，镜像未拉取完成 | blocked |

### 阶段 3：实现
- **状态：** complete
- **开始时间：** 2026-04-01
- 执行的操作：
  - 将 `scripts/dev-smoke.sh` 的默认扫描驱动改为 Docker，同时保留 `SCAN_DRIVER=host` 手工覆盖能力。
  - 新增 `scripts/dev-scan-docker-build.sh`，支持从本地 `ScopeSentry-Scan` 源码交叉编译 Linux `amd64` 二进制并构建本地 Docker 镜像。
  - 更新 `LOCAL_DEV_SETUP.md`，补充“改扫描端代码后如何走 Docker 集成验证”的建议流程。
- 创建/修改的文件：
  - `scripts/dev-smoke.sh`
  - `scripts/dev-scan-docker-build.sh`
  - `LOCAL_DEV_SETUP.md`
  - `task_plan.md`
  - `progress.md`

## 测试结果补充（扫描端 Docker 开发）
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| smoke/build 脚本语法验证 | `bash -n scripts/dev-smoke.sh scripts/dev-scan-docker-build.sh scripts/dev-scan-docker.sh` | 相关脚本语法合法 | 命令退出码为 0 | pass |
| smoke 默认驱动检查 | `rg -n "DEFAULT_SCAN_DRIVER" scripts/dev-smoke.sh` | 默认值为 Docker | 已确认 `DEFAULT_SCAN_DRIVER=\"docker\"` | pass |
| 新增脚本权限检查 | `ls -l scripts/dev-scan-docker-build.sh` | 脚本具备可执行权限 | 已为 `-rwxr-xr-x` | pass |
| Linux 交叉编译尝试 | `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build ...` | 能产出 Linux 扫描端二进制 | 首次因 `goproxy.cn` DNS 失败；切换 `GOPROXY=https://proxy.golang.org,direct` 后已开始下载依赖，但本轮未等待完整结束 | partial |

## 错误日志
| 时间戳 | 错误 | 尝试次数 | 解决方案 |
|--------|------|---------|---------|
| 2026-03-27 | 规划文件不存在 | 1 | 已初始化 `task_plan.md`、`findings.md`、`progress.md` |

## 五问重启检查
| 问题 | 答案 |
|------|------|
| 我在哪里？ | 阶段 5 |
| 我要去哪里？ | 向用户交付已落地的本地开发方案和脚本 |
| 目标是什么？ | 为当前项目制定并落地一套适合二开的本地开发启动方案 |
| 我学到了什么？ | 见 `findings.md` |
| 我做了什么？ | 见上方记录 |

---
*每个阶段完成后或遇到错误时更新此文件*

## 会话：2026-04-17

### 阶段 6：子域名对比功能迭代规划
- **状态：** in_progress
- **开始时间：** 2026-04-17
- 执行的操作：
  - 重新盘点子域名工具对比功能当前已完成的后端接口、前端标签页、明细弹窗与自动刷新策略。
  - 确认近期已修复的分页可见性问题不再属于功能规划阻塞项。
  - 将下一步建议收敛为“真实任务验收、交互补齐、性能收口、发布同步”四个方向。
  - 排查扫描模板页截图里的“共 7 条但表格为空”问题，确认和之前任务页一样属于表格高度为 `0` 的回归。
  - 修复 `ScanTemplate.vue`、`ScheduledTask.vue`、`PageMonit.vue` 的表格高度初始化与激活时重算逻辑。
  - 新增 `scripts/tests/task_table_height_guard_test.sh` 作为静态回归保护。
- 创建/修改的文件：
  - `task_plan.md`
  - `findings.md`
  - `progress.md`
  - `ScopeSentry-UI/src/views/Task/ScanTemplate.vue`
  - `ScopeSentry-UI/src/views/Task/ScheduledTask.vue`
  - `ScopeSentry-UI/src/views/Task/components/PageMonit.vue`
  - `scripts/tests/task_table_height_guard_test.sh`

## 会话：2026-05-22

### 阶段 7：SubdomainScan Stream Chunk 开发计划
- **状态：** complete
- **开始时间：** 2026-05-22
- 执行的操作：
  - 根据用户确认的约束收敛方案：严格阶段模式、只做 SubdomainScan v1、`1 root domain + 1 plugin = 1 chunk`、不做字典切片、DLQ 默认阻塞但可手动忽略。
  - 复查现有 PortScan Stream Chunk 相关文件、扫描端 streamtask 消费器、SubdomainScan 模块、TargetHandler 输出链路和 UI 端 PortChunkProgress。
  - 新增详细开发计划 `docs/superpowers/plans/2026-05-22-subdomain-stream-chunk-scheduling.md`，覆盖 19 个任务：模型、stage input 仓库、TargetHandler 持久化、chunk builder、producer/reaper/continuation 泛化、dispatcher、下游 resume、scanner bypass、chunk runner、consumer、API、UI、脚本 smoke 和端到端验证。
  - 对计划做自检：确认无业务代码改动、无 `git diff --check` 问题、计划中不保留待定文件路径，并补充 scanner 侧不得跨仓 import server models 的约束。
- 创建/修改的文件：
  - `docs/superpowers/plans/2026-05-22-subdomain-stream-chunk-scheduling.md`
  - `task_plan.md`
  - `findings.md`
  - `progress.md`

## 测试结果补充（SubdomainScan Stream Chunk 规划）
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| 计划占位扫描 | `rg -n "TODO|TBD|placeholder|implement later|fill in|if present|if needed|if the project|not available|where possible|后续|待定|占位" docs/superpowers/plans/2026-05-22-subdomain-stream-chunk-scheduling.md` | 不出现未决实现占位 | 仅命中自检段落中的 `Placeholder scan` 描述 | pass |
| diff 空白检查 | `git diff --check` | 无尾随空白或补丁格式问题 | 无输出，退出码为 0 | pass |

### 阶段 8：SubdomainScan Stream Chunk 实现
- **状态：** complete
- **开始时间：** 2026-05-22
- 执行的操作：
  - 在 worktree `/Users/york/.config/superpowers/worktrees/info-scan/subdomain-stream-chunk`、分支 `feature/subdomain-stream-chunk` 中继续实现。
  - 服务端新增/泛化 stream chunk 管理能力：SubdomainScan chunk 规划、stage gate、continuation、DLQ 阻塞/忽略、summary/DLQ/retry/ignore API 与进度摘要。
  - 扫描端新增 SubdomainScan stream 消费与执行链路：Subdomain chunk runner、Subdomain resume process、legacy bypass、pending 阶段完成保护、TargetHandler stage input 记录。
  - 补齐 Subdomain chunk timeout：`timeoutSec` 按秒向上取整为分钟，内置 `subfinder`/`shuffledns`/`oneforall` 注入 `-timeout`，`puredns`/`ksubdomain` 注入 `-et`；模板已显式配置 `-timeout` 或 `-et` 时不覆盖。
  - UI 将 PortScan chunk 面板泛化为 `StreamChunkProgress`，任务进度中新增 SubdomainScan chunk tab，保留旧 PortScan wrapper 兼容。
  - 本地脚本补充 `STREAM_SUBDOMAIN_ENABLED`、`STREAM_SUBDOMAIN_CHUNK_TIMEOUT_SECONDS`、`ADAPTIVE_PULL_ENABLED` 等环境变量透传，并新增 Subdomain stream dry-run smoke 与 env 测试。
  - 核对当前运行端口：`ScopeSentry-UI/vite.config.ts` 使用 `4000` 并代理到 `8080`，`ScopeSentry/single-host-deployment.yml` 使用 `8080:8080`，脚本默认 `BACKEND_URL=http://127.0.0.1:8080`。
- 创建/修改的文件：
  - `ScopeSentry/internal/models/stream_task.go`
  - `ScopeSentry/internal/repositories/streamtask/*`
  - `ScopeSentry/internal/repositories/streamstageinput/*`
  - `ScopeSentry/internal/services/streamdispatch/*`
  - `ScopeSentry/internal/api/handlers/streamtask/*`
  - `ScopeSentry/internal/api/routes/task/task.go`
  - `ScopeSentry/internal/services/task/task/task.go`
  - `ScopeSentry-Scan/internal/streamtask/*`
  - `ScopeSentry-Scan/internal/runner/runner.go`
  - `ScopeSentry-Scan/modules/manage.go`
  - `ScopeSentry-Scan/modules/subdomainscan/module.go`
  - `ScopeSentry-Scan/modules/targethandler/module.go`
  - `ScopeSentry-UI/src/api/task/index.ts`
  - `ScopeSentry-UI/src/api/task/types.ts`
  - `ScopeSentry-UI/src/views/Task/components/StreamChunkProgress.vue`
  - `ScopeSentry-UI/src/views/Task/components/PortChunkProgress.vue`
  - `ScopeSentry-UI/src/views/Task/components/ProgressInfo.vue`
  - `scripts/dev-scan.sh`
  - `scripts/dev-scan-docker.sh`
  - `scripts/dev-scan-docker-compose.yml`
  - `scripts/dev-smoke.sh`
  - `scripts/tests/subdomain_stream_chunk_smoke.sh`
  - `scripts/tests/stream_subdomain_env_test.sh`

## 测试结果补充（SubdomainScan Stream Chunk 实现）
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| 扫描端 timeout RED | `go test ./internal/streamtask -run 'TaskOptionsFromMessage.*Subdomain.*Timeout' -v` | 新增测试先失败，证明能捕捉未注入 timeout 的缺口 | 失败于参数仍为 `-t 10`，未包含 `-timeout 120` | pass |
| 扫描端 streamtask 定向 | `go test ./internal/streamtask -run 'TaskOptionsFromMessage|Subdomain' -v` | 消息解析、Subdomain 路由和 timeout 注入通过 | 命令退出码 0 | pass |
| 扫描端 Subdomain chunk 定向 | `go test ./internal/streamtask ./modules/subdomainscan -run 'Subdomain|Stream|Message|Chunk|TaskOptionsFromMessage' -v` | Subdomain stream 消费、chunk runner、结果处理通过 | 命令退出码 0 | pass |
| 扫描端扩展定向 | `go test ./internal/results ./internal/streamtask ./internal/task ./internal/runner ./modules ./modules/targethandler ./modules/subdomainscan ./modules/portscan -run 'Subdomain|Stream|Message|Handler|Consumer|Lease|Bypass|Chunk|TargetHandler|PortScan|Resume|RecordTaskEnd|TaskOptionsFromMessage' -v` | 扫描端相关链路均通过 | 命令退出码 0 | pass |
| 服务端定向 | `go test ./internal/models ./internal/database/mongodb ./internal/repositories/streamtask ./internal/repositories/streamstageinput ./internal/services/streamdispatch ./internal/services/task/task ./internal/api/handlers/streamtask ./internal/api/routes/task -run 'StreamTask|StreamStageInput|Subdomain|Continuation|Chunk|Producer|Reaper|DLQ|Dispatcher|Progress|Register|PortScan|Summary|Retry|StreamChunkSummary' -v` | stream task、stage input、dispatcher、continuation、API、summary 均通过 | 命令退出码 0；Mongo/Redis 初始化有连接日志，相关 repo 测试按 fake/skip 设计处理 | pass |
| UI 定向 ESLint | `pnpm exec eslint --ext .js,.ts,.vue ./src/views/Task/components/StreamChunkProgress.vue ./src/views/Task/components/PortChunkProgress.vue ./src/views/Task/components/ProgressInfo.vue ./src/api/task/index.ts ./src/api/task/types.ts` | 本轮新增/修改 UI 文件 lint 通过 | 命令退出码 0 | pass |
| UI 生产构建 | `pnpm run build:pro` | 可生成生产构建 | 输出 `Build successful. Please see dist-pro directory`，命令退出码 0 | pass |
| UI 全仓类型检查 | `pnpm run ts:check` | 记录全仓类型状态 | 退出码 2；失败集中在既有未使用导入、`Asset/asset` 大小写冲突、Element Plus `ISelectProps` 等，不指向本轮新增文件 | known-fail |
| Subdomain env 测试 | `bash scripts/tests/stream_subdomain_env_test.sh` | 脚本正确透传 Subdomain stream env | 输出 `stream subdomain env test passed` | pass |
| Subdomain smoke dry-run | `scripts/tests/subdomain_stream_chunk_smoke.sh --dry-run` | dry-run 不触发真实扫描但能校验流程参数 | 输出 `subdomain stream chunk smoke dry-run passed` | pass |
| 脚本语法 | `bash -n scripts/dev-scan.sh scripts/dev-scan-docker.sh scripts/dev-smoke.sh scripts/tests/subdomain_stream_chunk_smoke.sh scripts/tests/stream_subdomain_env_test.sh scripts/tests/dev_scan_env_smoke.sh` | 相关脚本语法合法 | 命令退出码 0 | pass |
| diff 空白检查 | `git diff --check && git -C ScopeSentry diff --check && git -C ScopeSentry-Scan diff --check && git -C ScopeSentry-UI diff --check` | 无尾随空白和补丁空白错误 | 命令退出码 0 | pass |
| 端口配置核对 | `rg -n "8082|4001" ScopeSentry-UI/vite.config.ts ScopeSentry/single-host-deployment.yml scripts LOCAL_DEV_SETUP.md ...` 与 `rg -n "4000|8080|proxy|BACKEND_URL" ...` | 当前运行配置使用 `8080/4000` | 配置文件和脚本默认值为 `8080/4000`；`8082/4001` 只剩历史记录、测试数据或端口字典 | pass |

### 阶段 9：Stream 运维化路线与 P0 脚本
- **状态：** in_progress
- **开始时间：** 2026-05-22
- 执行的操作：
  - 根据用户确认的路线，将后续工作固定为 P0 状态确认脚本、P1 健康看板、P2 任务控制、P3 节点容量治理、P4 其他模块分片。
  - 增强 `scripts/enable-stream-task.sh`：新增 `doctor` 子命令；`status` 增加扫描端 container env；扫描端缺少 `/apps/config/config.yaml` 时改为说明运行时会使用容器 env。
  - `doctor` 检查服务端 compose/container Stream flag、扫描端 node.env/container Stream flag、UI bundle 是否包含 Subdomain stream 进度、Redis stream 是否可访问、Mongo `stream_task_chunks` 是否可访问。
  - 更新 `scripts/tests/enable_stream_task_test.sh`，用 fake docker 覆盖 `enable`、`status` 和 `doctor`。
  - 新增 `docs/superpowers/plans/2026-05-22-stream-operations-roadmap.md`，记录 P0-P4 的交付边界和验收目标。
  - 提交并推送根仓库到 `origin/main`，提交为 `d7b05ea feat: add stream operations doctor`。
- 创建/修改的文件：
  - `scripts/enable-stream-task.sh`
  - `scripts/tests/enable_stream_task_test.sh`
  - `docs/superpowers/plans/2026-05-22-stream-operations-roadmap.md`
  - `task_plan.md`
  - `progress.md`

## 测试结果补充（Stream 运维化 P0）
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| enable/status/doctor 脚本测试 | `bash scripts/tests/enable_stream_task_test.sh` | fake Docker 环境下 enable、status、doctor 均通过 | 输出 `enable stream task script test passed` | pass |
| 脚本语法 | `bash -n scripts/enable-stream-task.sh scripts/tests/enable_stream_task_test.sh` | 脚本语法合法 | 命令退出码 0 | pass |

### 阶段 10：P1 Stream 任务健康看板
- **状态：** in_progress
- **开始时间：** 2026-05-22
- 执行的操作：
  - 在服务端 worktree `/Users/york/.config/superpowers/worktrees/info-scan/stream-health-dashboard/ScopeSentry`、分支 `feature/stream-health-dashboard` 中实现 P1 后端改动。
  - 在 UI worktree `/Users/york/.config/superpowers/worktrees/info-scan/stream-health-dashboard/ScopeSentry-UI`、分支 `feature/stream-health-dashboard` 中实现 P1 前端改动。
  - 服务端 `streamtask.Summary` 新增 `StreamChunkHealthSummary`，返回 `failed`、`cancelled`、`stuck`、`leaseExpired`、`oldestRunningSeconds`、`lastFinishedAt`、`finishedLastMinute`、`finishedLastFiveMinutes`、`nodeActivity`、`runningChunks`。
  - `GetTaskProgress` 的 `subdomainScanChunks` / `portScanChunks` 同步返回相同健康字段，保证任务进度页和独立 summary API 一致。
  - 将健康统计从“按阶段全量读取所有 chunk”改为三类窗口化查询：running/retrying 明细、最近 5 分钟 finished chunk、最后 1 条 finished chunk，避免大任务看板接口过重。
  - UI `StreamChunkProgress.vue` 新增汇总指标、健康指标、运行中分片表、节点活跃表，并保留原 DLQ retry/ignore 表。
  - 补齐中英文 i18n 和 TypeScript 类型。
  - 2026-05-26：将 P1 服务端和 UI 源码改动从隔离 worktree 合入当前主目录；没有触碰服务端主目录中已有的 `cmd/main/static` 生成资源改动。
  - 2026-05-26：在当前主目录重新运行后端定向测试、UI ESLint、UI 生产构建和 diff 空白检查。
  - 2026-05-26：通过 `./devctl server publish --tag v2026.05.26-stream-health-dashboard` 打包 UI、同步服务端 embed static、交叉编译服务端、构建并推送 GHCR 服务端镜像。
  - 2026-05-26：已推送 `ghcr.io/york-cmd/scopesentry-server:v2026.05.26-stream-health-dashboard` 和 `ghcr.io/york-cmd/scopesentry-server:latest`，digest 为 `sha256:f832baa2eff8a6a61b0f74c34cb13a1fc89ea2a75743191e3b41e5a054e86065`。
- 创建/修改的文件：
  - `ScopeSentry/internal/api/handlers/streamtask/admin.go`
  - `ScopeSentry/internal/api/handlers/streamtask/admin_test.go`
  - `ScopeSentry/internal/services/task/task/task.go`
  - `ScopeSentry/internal/services/task/task/stream_chunk_summary_test.go`
  - `ScopeSentry-UI/src/api/task/types.ts`
  - `ScopeSentry-UI/src/locales/en.ts`
  - `ScopeSentry-UI/src/locales/zh-CN.ts`
  - `ScopeSentry-UI/src/views/Task/components/StreamChunkProgress.vue`

## 测试结果补充（Stream 运维化 P1）
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| 后端定向测试 | `go test ./internal/api/handlers/streamtask ./internal/services/task/task ./internal/api/routes/task -run 'Stream|Summary|DLQ|Retry|Register' -v` | Stream summary、DLQ、retry、route 注册测试通过 | 命令退出码 0；Redis NOAUTH 和 Mongo URI 为既有初始化日志，不影响测试 | pass |
| UI 定向 ESLint | `pnpm exec eslint --ext .js,.ts,.vue ./src/views/Task/components/StreamChunkProgress.vue ./src/api/task/types.ts ./src/locales/zh-CN.ts ./src/locales/en.ts` | 本轮 UI 文件 lint 通过 | 命令退出码 0 | pass |
| UI 生产构建 | `pnpm run build:pro` | 可生成生产构建 | 输出 `Build successful. Please see dist-pro directory`，命令退出码 0 | pass |
| 服务端 diff 空白检查 | `git diff --check` | 无尾随空白或补丁空白问题 | 命令退出码 0 | pass |
| UI diff 空白检查 | `git diff --check` | 无尾随空白或补丁空白问题 | 命令退出码 0 | pass |
| 当前主目录后端定向测试 | `go test ./internal/api/handlers/streamtask ./internal/services/task/task ./internal/api/routes/task -run 'Stream|Summary|DLQ|Retry|Register' -v` | 合入后仍通过 | 命令退出码 0；Redis NOAUTH 和 Mongo URI 为既有初始化日志 | pass |
| 当前主目录 UI 定向 ESLint | `pnpm exec eslint --ext .js,.ts,.vue ./src/views/Task/components/StreamChunkProgress.vue ./src/api/task/types.ts ./src/locales/zh-CN.ts ./src/locales/en.ts` | 合入后仍通过 | 命令退出码 0 | pass |
| 当前主目录 UI 生产构建 | `pnpm run build:pro` | 合入后能构建生产包 | 输出 `Build successful. Please see dist-pro directory`，命令退出码 0 | pass |
| 当前主目录 diff 空白检查 | `git diff --check -- <P1 服务端/UI 文件>` | P1 文件无空白问题 | 命令退出码 0 | pass |
| 服务端镜像发布 | `./devctl server publish --tag v2026.05.26-stream-health-dashboard` | 构建并推送 GHCR 服务端镜像 | tag 和 latest 均推送成功，digest 为 `sha256:f832baa2eff8a6a61b0f74c34cb13a1fc89ea2a75743191e3b41e5a054e86065` | pass |
| 镜像 UI 标识验证 | `docker run --rm --entrypoint sh ghcr.io/york-cmd/scopesentry-server:v2026.05.26-stream-health-dashboard -lc 'grep ... /opt/ScopeSentry/ScopeSentry'` | 镜像二进制包含 P1 看板标识 | 命中 `Node Activity`、`节点活跃`、`finishedLastFiveMinutes`、`leaseExpired`、`streamChunkNodeActivity` | pass |

## 待确认
- P1 源码已合入 `/Users/york/ai-proctet/info-scan/ScopeSentry` 和 `/Users/york/ai-proctet/info-scan/ScopeSentry-UI` 主目录，并已发布到 `ghcr.io/york-cmd/scopesentry-server:latest`。
- 服务端/UI 子仓库本地 main 相对 `Autumn-27` upstream 有历史分叉，本轮未直接推送到上游官方仓库。

### 阶段 11：P2 Stream 任务控制能力
- **状态：** in_progress
- **开始时间：** 2026-05-26
- 执行的操作：
  - 在服务端 worktree `/Users/york/.config/superpowers/worktrees/info-scan/stream-task-controls/ScopeSentry`、扫描端 worktree `/Users/york/.config/superpowers/worktrees/info-scan/stream-task-controls/ScopeSentry-Scan`、UI worktree `/Users/york/.config/superpowers/worktrees/info-scan/stream-task-controls/ScopeSentry-UI` 中实现 P2。
  - 服务端新增 `stream_task_controls` 控制模型、Mongo repository、唯一索引和 summary `controlState` 字段。
  - 服务端新增 `pause`、`resume`、`cancel`、`dlq/retry/all`、`dlq/ignore/all`、`release-node` API 和路由。
  - `Dispatcher` 在规划 PortScan/SubdomainScan chunk 前读取控制状态；`ContinuationController` 在进入下游阶段前读取控制状态，paused/cancelled 阻断继续推进。
  - `cancel` 将 pending/queued/retrying chunk 标记为 cancelled，并写入阶段 cancelled 控制状态；running chunk 不强杀。
  - `release-node` 将指定节点持有的 running/retrying chunk 清理 node/streamId/leaseExpiresAt，attempt +1 后重新投递。
  - 扫描端 `Handler` 执行前读取 chunk status；cancelled/ignored 直接返回成功，让 Redis consumer ACK 并跳过插件执行。
  - UI `StreamChunkProgress` 顶部新增调度状态、暂停/恢复、取消未执行、DLQ 批量 retry/ignore；节点活跃表新增释放节点入口。
  - 将 P2 改动从隔离 worktree 合入当前项目主目录，未触碰服务端主目录中已有的静态资源生成改动。
- 创建/修改的文件：
  - `ScopeSentry/internal/models/stream_task.go`
  - `ScopeSentry/internal/repositories/streamtask/control_repository.go`
  - `ScopeSentry/internal/repositories/streamtask/repository.go`
  - `ScopeSentry/internal/services/streamdispatch/dispatcher.go`
  - `ScopeSentry/internal/services/streamdispatch/continuation.go`
  - `ScopeSentry/internal/api/handlers/streamtask/admin.go`
  - `ScopeSentry/internal/api/routes/task/task.go`
  - `ScopeSentry/internal/database/mongodb/initdb.go`
  - `ScopeSentry-Scan/internal/streamtask/handler.go`
  - `ScopeSentry-Scan/internal/streamtask/state.go`
  - `ScopeSentry-UI/src/api/task/index.ts`
  - `ScopeSentry-UI/src/api/task/types.ts`
  - `ScopeSentry-UI/src/locales/en.ts`
  - `ScopeSentry-UI/src/locales/zh-CN.ts`
  - `ScopeSentry-UI/src/views/Task/components/StreamChunkProgress.vue`
  - 对应测试文件

## 测试结果补充（Stream 运维化 P2）
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| 后端 P2 RED | `go test ./internal/api/handlers/streamtask ./internal/services/streamdispatch ./internal/api/routes/task ./internal/database/mongodb -run 'Pause|Resume|Batch|Cancel|Release|Control|DispatcherSkips|RegisterTaskRoutesIncludes|ExistingDatabaseIndexSpecs' -count=1` | 新增测试先失败 | 失败于缺少控制模型/API/路由/dispatcher 方法 | pass |
| 扫描端 P2 RED | `go test ./internal/streamtask -run 'Cancelled|HandlerSkips' -count=1` | 新增测试先失败 | 失败于缺少 `chunkStatusCancelled` 和状态校验 | pass |
| 后端 P2 定向 | `go test ./internal/api/handlers/streamtask ./internal/services/streamdispatch ./internal/repositories/streamtask ./internal/services/task/task ./internal/api/routes/task ./internal/database/mongodb ./internal/models -run 'Stream|Summary|DLQ|Retry|Ignore|Pause|Resume|Batch|Cancel|Release|Dispatcher|Continuation|Reaper|Repository|Control|Register' -count=1` | 服务端控制、DLQ、调度、continuation、索引测试通过 | 命令退出码 0 | pass |
| 扫描端 P2 定向 | `go test ./internal/streamtask -run 'Stream|Handler|Consumer|Lease|TaskOptions|Cancelled' -count=1` | stream consumer/handler 和取消跳过测试通过 | 命令退出码 0 | pass |
| UI 定向 ESLint | `pnpm exec eslint --ext .js,.ts,.vue ./src/views/Task/components/StreamChunkProgress.vue ./src/api/task/index.ts ./src/api/task/types.ts ./src/locales/zh-CN.ts ./src/locales/en.ts` | P2 UI 文件 lint 通过 | 命令退出码 0 | pass |
| UI 生产构建 | `pnpm run build:pro` | 可生成生产构建 | 输出 `Build successful. Please see dist-pro directory`，命令退出码 0 | pass |
| P2 diff 空白检查 | `git diff --check -- <P2 文件清单>` | P2 文件无尾随空白或补丁空白问题 | 服务端、扫描端、UI 命令退出码 0 | pass |
