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
