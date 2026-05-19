# ScopeSentry Local Development

## 首选入口

现在优先推荐直接使用统一入口 `./devctl`，而不是手动分别执行多个 `scripts/dev-*.sh`。

最常用的流程：

```bash
./devctl install
./devctl doctor
./devctl up
./devctl status
```

常用命令：

- `./devctl install`
- `./devctl doctor`
- `./devctl up`
- `./devctl down`
- `./devctl restart`
- `./devctl status`
- `./devctl logs server|ui|scan|db`
- `./devctl update`
- `./devctl scan rebuild`
- `./devctl clean`
- `./devctl uninstall`
- `./devctl uninstall --purge`

## `./devctl` 详细说明

`./devctl` 是这套本地开发环境的统一控制入口。它的目标不是替代源码里的业务逻辑，而是把“本地依赖、启动顺序、日志路径、密码文件、扫描镜像重建、环境清理”这些容易分散的事情收口到一个命令里。

默认控制的组件有 4 个：

- `db`: MongoDB + Redis，使用 Docker
- `server`: ScopeSentry 服务端，本地源码构建后运行
- `ui`: ScopeSentry-UI，本地 `pnpm dev`
- `scan`: ScopeSentry-Scan，默认使用本地二开 Docker 镜像 `scopesentry-scan-dev:local`

### `./devctl install`

用途：

- 做本地环境初始化
- 检查依赖是否齐全
- 生成服务端 `ScopeSentry/.env`
- 初始化 `.local-dev` 目录结构
- 生成状态文件 `.local-dev/state/manifest.json`

特点：

- 这是幂等操作，可以重复执行
- 如果 `ScopeSentry/.env` 已存在，默认不会覆盖
- 这一步不会启动任何业务组件
- 这一步不会生成登录密码

为什么不会生成登录密码：

- ScopeSentry 的登录密码是在服务端第一次成功初始化数据库时由程序自己生成的
- 生成后会写入 `.local-dev/runtime/server/PASSWORD`
- 所以 `install` 只能把目录和配置准备好，不能提前“伪造”登录密码

补充说明：

- 如果你当前 MongoDB 已经有历史初始化数据，服务端不会再次生成新密码
- 这时 `./devctl status` 里密码文件可能显示 `pending`
- `pending` 不一定代表启动失败，也可能只是“当前数据库不是首次初始化”

建议首次执行：

```bash
./devctl install
```

如果你明确想重建 `.env`：

```bash
./devctl install --force
```

### `./devctl doctor`

用途：

- 只读检查当前本地开发环境是否满足启动条件
- 在 `up` 之前先发现依赖、Docker、端口、配置和运行态问题
- 在 `up` 失败后快速收敛排查范围

特点：

- 不会启动、停止或修改任何业务组件
- 会输出 `PASS/WARN/FAIL`
- 失败项后面会附带简短修复建议

建议使用时机：

- 首次执行 `up` 之前
- Docker Desktop 刚重启之后
- `up` 失败之后

常用示例：

```bash
./devctl doctor
```

### `./devctl up`

用途：

- 一键启动默认混合开发环境

执行顺序：

1. 确保 `install` 已完成
2. 启动 MongoDB/Redis
3. 启动服务端
4. 启动前端
5. 启动 Docker 扫描节点
6. 等待关键文件和端口出现
7. 输出当前状态摘要

特点：

- 这是幂等操作
- 已经在运行的组件会尽量跳过
- 会把本地状态刷新到 `.local-dev/state/manifest.json`
- 扫描端默认优先使用本地二开镜像 `scopesentry-scan-dev:local`
- 如果本地扫描镜像不存在，会先自动构建一次再启动扫描容器
- 如果某个阶段失败，会直接输出失败阶段、对应日志尾部和下一步建议
- 默认会打印详细进度，包括当前阶段、等待状态、已耗时和超时窗口

适合：

- 电脑重启后恢复环境
- 新拉代码后启动整套开发环境
- 你想确认节点、后端、前端是否能一起工作

关于扫描端默认行为：

- `./devctl up` 默认目标镜像是 `scopesentry-scan-dev:local`
- 如果这个本地镜像缺失，`up` 会自动构建一次再启动
- 如果你改了 `ScopeSentry-Scan` 源码，仍然需要显式执行 `./devctl scan rebuild` 来刷新到最新代码

失败时你现在通常会看到这些信息：

- 失败阶段，例如 `db`、`server`、`ui`、`scan`
- 对应组件日志的最后一段
- `hint: run ./devctl doctor`

等待时你现在通常会看到这些信息：

- `stage db: start mongodb/redis`
- `waiting db: mongo health=starting, elapsed=15s, timeout=90s`
- `stage server: ready in 9s`

如果你想调节等待心跳频率，可以临时设置：

```bash
DEVCTL_PROGRESS_INTERVAL=1 ./devctl up
```

默认值是 `5` 秒。

### `./devctl status`

用途：

- 查看当前本地开发环境的摘要状态

会输出的信息：

- 当前 profile
- API 地址
- UI 地址
- 节点名
- 扫描镜像 tag
- 密码文件路径
- 密码文件是否已生成
- `db/server/ui/scan` 四个组件的状态
- manifest 文件路径

你最常用它来回答这些问题：

- 后端访问地址是什么
- 前端访问地址是什么
- 当前节点叫什么
- 登录密码文件在哪
- 扫描节点是不是在线前状态至少已经起来

建议习惯：

- 每次 `up` 之后先跑一次 `./devctl status`
- 每次 `scan rebuild` 之后也跑一次 `./devctl status`

### `./devctl logs server|ui|scan|db`

用途：

- 统一查看日志，不再手动找路径或容器名

具体对应关系：

- `server`: `.local-dev/logs/dev-server.log`
- `ui`: `.local-dev/logs/dev-ui.log`
- `scan`: `docker logs -f scopesentry-scan-dev`
- `db`: Docker Compose 下的 MongoDB/Redis 日志

常用示例：

```bash
./devctl logs server
./devctl logs ui
./devctl logs scan
./devctl logs db
```

适合：

- 后端启动失败
- 前端端口冲突或依赖问题
- 扫描节点未注册
- 数据库容器异常

### `./devctl down`

用途：

- 停掉当前本地开发环境

默认行为：

- 停止服务端本地进程
- 停止前端本地进程
- 停止扫描容器
- 停止 MongoDB/Redis 容器
- 不删除数据库数据
- 不删除 `.local-dev`

适合：

- 临时收起环境
- 切换分支前先停服务
- 释放端口和资源

### `./devctl restart`

用途：

- 快速重启整套环境

语义：

- 等价于 `./devctl down` 后再执行 `./devctl up`

适合：

- 你改了服务端配置
- 你怀疑环境状态脏了
- 多个组件都需要一起刷新

### `./devctl update`

用途：

- 刷新本地开发环境依赖，并把运行中的环境重启到新状态

当前设计下它会做的事：

- 确保环境已初始化
- 刷新前端依赖
- 重启本地 `server/ui`
- 重建并重启扫描容器

注意：

- 这是“开发环境更新”命令，不是 `git pull`
- 默认不清数据库
- 默认会动扫描镜像

适合：

- 你改了扫描端代码并希望统一更新
- 你更新了前端依赖或服务端构建产物

### `./devctl scan rebuild`

这是你改扫描端代码后最重要的命令。

用途：

- 重新编译 `ScopeSentry-Scan` Linux 二进制
- 重建 Docker 扫描镜像
- 重启扫描容器

为什么必须这样：

- 现在 Docker 扫描端不是“源码挂载热同步”模式
- 容器里的扫描端二进制来自镜像构建时的 `COPY`
- 所以你改了 `ScopeSentry-Scan` 代码后，不重建镜像，容器里不会是最新版本

什么时候必须跑：

- 改了 `ScopeSentry-Scan` 的 Go 代码
- 改了扫描端 `dockerfile`
- 改了扫描端镜像内置工具或依赖

什么时候通常不用跑：

- 只改了服务端代码
- 只改了前端代码
- 只看日志、只改文档

建议习惯：

```bash
./devctl scan rebuild
./devctl status
./devctl logs scan
```

和 `./devctl up` 的关系：

- `up` 只会在本地扫描镜像缺失时自动构建一次
- `scan rebuild` 会强制按当前 `ScopeSentry-Scan` 源码重新编译并重建镜像

### `./devctl clean`

用途：

- 清理本地运行中的临时产物，但不做破坏性删除

会清掉的内容：

- `.local-dev/logs`
- `.local-dev/pids`
- `.local-dev/cache`
- `.local-dev/runtime/tmp`

不会清掉的内容：

- `ScopeSentry/.env`
- `.local-dev/runtime/server/PASSWORD`
- MongoDB/Redis 数据
- 你的源码改动

适合：

- 日志太多
- pid 脏了
- 本地缓存想重建
- 你想“轻度打扫”，不是重装环境

### `./devctl uninstall`

用途：

- 卸载当前本地开发运行态

默认行为：

- 停掉所有受管组件
- 删除 `.local-dev`
- 保留数据库数据目录
- 保留源码目录

适合：

- 你要把本地运行态整体重建
- 你怀疑 `.local-dev` 里状态已经很脏

### `./devctl uninstall --purge`

用途：

- 做彻底清理

额外行为：

- 在 `uninstall` 的基础上再删除 MongoDB/Redis 本地数据目录

适合：

- 你要回到接近全新环境
- 你要验证首次初始化流程
- 你不再需要当前本地数据库数据

执行前要确认：

- 你确实不需要现有本地数据
- 这不是误操作

## 推荐使用习惯

日常最常见的 4 条路径：

首次准备环境：

```bash
./devctl install
./devctl up
./devctl status
```

日常恢复环境：

```bash
./devctl up
./devctl status
```

修改扫描端代码后：

```bash
./devctl scan rebuild
./devctl status
./devctl logs scan
```

环境脏了但不想删数据：

```bash
./devctl down
./devctl clean
./devctl up
```

登录信息说明：

- 用户名固定为 `ScopeSentry`
- 登录密码由服务端首次初始化数据库时生成
- 密码文件默认位于 `.local-dev/runtime/server/PASSWORD`
- `./devctl status` 会输出密码文件位置和当前存在状态
- 如果数据库不是首次初始化，密码文件可能一直不存在，这时需要使用你之前已有的登录密码

这份方案基于当前工作区的真实结构，而不是 README 里的旧技术栈描述。

当前工作区包含 3 个独立仓库：

- `ScopeSentry`: 主服务端，Go
- `ScopeSentry-Scan`: 扫描节点，Go
- `ScopeSentry-UI`: 前端，Vue 3 + Vite

## 推荐的本地开发模式

推荐使用“混合开发模式”：

1. `MongoDB` 和 `Redis` 用 Docker 启动。
2. `ScopeSentry` 用源码构建后在宿主机运行。
3. `ScopeSentry-UI` 用 `pnpm dev` 运行，走 Vite 热更新。
4. 只有在需要调试扫描链路、插件或任务执行时，再启动 `ScopeSentry-Scan`。
5. 在 macOS 上，优先把扫描端放进 Docker；只有要直接断点调试扫描端 Go 代码时，再用宿主机二进制模式。

这样做的原因：

- 数据库和缓存依赖稳定，省掉本地安装。
- Go 服务本地运行，日志和断点更直接。
- 前端保留热更新，不必每次重新打包。
- 避免长期用 `go run`，因为这两个 Go 程序会按“可执行文件所在目录”生成配置和数据目录。

## 三种可选路径

### 路径 A：官方全 Docker

适合快速体验，不适合二开。

- 优点：最省事。
- 缺点：改 Go/前端代码都要重新做镜像或替换容器，反馈慢。

### 路径 B：混合开发模式

这是推荐方案。

- 优点：开发反馈快，运行依赖稳定。
- 缺点：需要记住 3 到 4 个启动命令。

### 路径 C：全源码本地运行

只在你明确不想用 Docker 时再考虑。

- 优点：依赖最透明。
- 缺点：MongoDB 和 Redis 也要本机安装和维护，没有必要。

## 运行目录约定

本方案把运行时产物集中放在工作区根目录的 `.local-dev/` 下：

- `.local-dev/runtime/server/`: 主服务运行时目录
- `.local-dev/runtime/scan-host/`: 宿主机扫描节点运行时目录
- `.local-dev/runtime/scan-docker/`: Docker 扫描节点运行时目录
- `.local-dev/logs/`: 统一日志目录
- `.local-dev/pids/`: 本地进程 pid 目录
- `.local-dev/cache/`: 本地缓存目录
- `.local-dev/state/manifest.json`: 当前本地环境状态摘要

这样可以避免把 `config.yaml`、`uploads/`、`images/`、扫描节点缓存等内容散落到源码目录里。

## 先决条件

当前工作区建议满足：

- Go `>= 1.24`
- Node `>= 18`
- pnpm `>= 8`
- Docker + Docker Compose

前端开发默认端口：

- `http://127.0.0.1:4000`

主服务默认端口：

- `http://127.0.0.1:8082`

## 启动顺序

> 以下"分脚本启动顺序"是 `./devctl` 出现前的旧手动流程，现在主要给两类人看：
> 1. 想了解 devctl 背后到底依次做了什么
> 2. devctl 某一步出问题时单步手动复现
>
> 常规二开请直接用顶部"首选入口"里的 `./devctl install/doctor/up`，下面的 `dev-*.sh` 已经退到内部 helper 的位置。

### 1. 启动 MongoDB 和 Redis

在工作区根目录运行：

```bash
./scripts/dev-db-up.sh
```

这一步会复用 `ScopeSentry/single-host-deployment.yml`，只拉起：

- `mongodb`
- `redis`

### 2. 启动主服务

```bash
./scripts/dev-server.sh
```

这个脚本会：

- 读取 `ScopeSentry/.env`
- 从 `ScopeSentry` 源码构建二进制
- 把二进制放到 `.local-dev/runtime/server/`
- 用本机 `127.0.0.1:27017` 和 `127.0.0.1:6379` 启动服务

第一次运行后，主服务的运行目录里会生成：

- `config.yaml`
- `files/`
- `uploads/`
- `images/`

### 3. 启动前端

```bash
./scripts/dev-ui.sh
```

这个脚本会在 `ScopeSentry-UI` 中：

- 在缺少 `node_modules` 时自动安装依赖
- 启动 `pnpm dev`

前端本地开发访问：

- `http://127.0.0.1:4000`

前端会把 `/api` 和 `/images` 代理到：

- `http://127.0.0.1:8082`

如果 `4000` 已被占用，Vite 会自动递增到 `4001`、`4002` 等端口。

### 4. 需要时启动扫描节点

macOS 本地开发推荐先用 Docker 扫描端。

#### 方案 A：Docker 扫描端

```bash
./scripts/dev-scan-docker.sh
```

这个脚本会：

- 读取 `ScopeSentry/.env`
- 复用本地 `MongoDB` 和 `Redis`
- 用 `host.docker.internal` 让容器连接宿主机上的 `127.0.0.1:27017/6379`
- 把扫描端运行时目录放到 `.local-dev/runtime/scan-docker/`

默认节点名：

- `local-dev-node-docker`

默认镜像：

- `autumn27/scopesentry-scan:latest`

常用命令：

```bash
./scripts/dev-scan-docker.sh
./scripts/dev-scan-docker.sh ps
./scripts/dev-scan-docker.sh logs -f
./scripts/dev-scan-docker.sh down
```

如果你本机拉不到 Docker Hub，可以直接覆盖镜像：

```bash
SCAN_IMAGE=your-registry/scopesentry-scan:latest ./scripts/dev-scan-docker.sh
```

其中：

- `logs -f` 实际等价于 `docker compose ... logs -f`
- 容器内扫描工具走 Linux 环境，能避开 macOS 宿主机工具不兼容的问题

#### 方案 B：宿主机二进制扫描端

```bash
./scripts/dev-scan.sh
```

这个脚本会：

- 读取 `ScopeSentry/.env`
- 从 `ScopeSentry-Scan/cmd/ScopeSentry/main.go` 构建扫描端二进制
- 把二进制放到 `.local-dev/runtime/scan-host/`
- 用本机 `127.0.0.1:27017` 和 `127.0.0.1:6379` 连接数据库与任务队列

只在以下场景建议继续用宿主机模式：

- 你要直接调试扫描端 Go 源码
- 你确认所需外部工具都有可用的 macOS 版本
- 你只验证不依赖 Linux 工具链的最小链路

无论哪种模式，扫描节点第一次启动前，建议先确认主服务已经正常起来，并且数据库里已经有基础配置。否则扫描端可能拿不到 `modules.yaml` 对应的全局模块配置。

### 5. 一键验证扫描链路

```bash
./scripts/dev-smoke.sh
```

这个脚本会：

- 自动拉起 `MongoDB` 和 `Redis`
- 在后端未启动时后台启动 `ScopeSentry`
- 在节点未注册时启动 `ScopeSentry-Scan`
- 自动登录后端
- 创建一份只包含 `httpx + WebFingerprint` 的最小模板
- 向当前 smoke 节点投递一个 `http://example.com` 任务
- 轮询任务进度，直到确认 `TargetHandler`、`AssetMapping`、`AssetHandle`、`All` 都跑完

现在 `dev-smoke.sh` 已经默认走 Docker 扫描端。

如果你想显式指定：

```bash
SCAN_DRIVER=docker ./scripts/dev-smoke.sh
SCAN_DRIVER=host ./scripts/dev-smoke.sh
```

输出里会直接给出：

- `backend_url`
- `username`
- `password`
- `node_name`
- `task_id`
- 后端和扫描端运行目录
- 后端日志、扫描端日志、节点日志快照路径

如果你只想换一个测试目标，也可以直接传参：

```bash
./scripts/dev-smoke.sh https://example.org
```

## 日常开发建议

### 场景 1：只改前端页面或 API

只需要启动：

1. `./scripts/dev-db-up.sh`
2. `./scripts/dev-server.sh`
3. `./scripts/dev-ui.sh`

这时可以完全不启动 `ScopeSentry-Scan`。

### 场景 2：改任务执行链路、插件、节点逻辑

需要启动：

1. `./scripts/dev-db-up.sh`
2. `./scripts/dev-server.sh`
3. `./scripts/dev-scan-docker.sh`
4. `./scripts/dev-ui.sh`

如果你这次就是要改 `ScopeSentry-Scan` 的 Go 代码本身，再把第 3 步切回：

```bash
./scripts/dev-scan.sh
```

### 场景 3：改扫描端代码，但仍然想用 Docker 做集成验证

推荐流程：

1. 修改 `ScopeSentry-Scan` 源码
2. 重建本地 Linux 扫描镜像并重启节点
3. 跑 smoke 或手动下发任务验证

命令：

```bash
./scripts/dev-scan-docker-build.sh restart
SCAN_IMAGE=scopesentry-scan-dev:local ./scripts/dev-smoke.sh
```

其中 `dev-scan-docker-build.sh` 会：

- 把当前扫描端源码交叉编译成 Linux `amd64` 二进制
- 输出到 `ScopeSentry-Scan/dist/ScopeSentry-Scan_linux_amd64_v1/ScopeSentry-Scan`
- 基于仓库里的 `ScopeSentry-Scan/dockerfile` 构建本地镜像
- 在你传 `restart` 时自动重启 Docker 扫描节点

默认本地镜像名：

- `scopesentry-scan-dev:local`

默认 Go 代理：

- 优先使用你当前环境里的 `GOPROXY`
- 如果没配，则回退到 `https://proxy.golang.org,direct`

如果你只想构建镜像，不立刻重启节点：

```bash
./scripts/dev-scan-docker-build.sh
```

如果你只想让 smoke 在节点缺失时自动拉起你自己的本地镜像：

```bash
SCAN_IMAGE=scopesentry-scan-dev:local ./scripts/dev-smoke.sh
```

如果你要显式指定 Go 代理：

```bash
GO_PROXY_URL=https://goproxy.cn,direct ./scripts/dev-scan-docker-build.sh restart
```

### 场景 4：验证“内嵌前端”发布形态

开发时不建议每次都把前端打包进主服务。

只有在你要验证最终发布形态时，再运行：

```bash
./scripts/dev-sync-ui-static.sh
```

这个脚本会：

1. 在 `ScopeSentry-UI` 中执行 `pnpm build:pro`
2. 用构建产物覆盖 `ScopeSentry/cmd/main/static/`

随后重新运行：

```bash
./scripts/dev-server.sh
```

再访问：

```text
http://127.0.0.1:8082
```

这时看到的是主服务二进制里内嵌的前端页面，不再是 Vite 开发服务器。

## 常见问题

### 1. 为什么不推荐长期使用 `go run`

因为这两个 Go 程序都把配置和运行时目录绑定到“可执行文件路径”：

- 主服务会在二进制目录旁边创建 `config.yaml`、`uploads/`、`images/`
- 扫描端会在二进制目录旁边创建 `config/`、`tmp/`、`plugin/`、`data/`

如果用 `go run`，这些内容会落在临时构建目录，行为不稳定。

### 2. 为什么扫描端不默认跟主服务一起启动

二开早期通常先改：

- 页面
- API
- 数据结构
- 权限
- 任务管理

这些都不需要先把扫描链路带起来。扫描端只会增加启动噪音和排错成本。

### 3. 为什么现在又推荐在 macOS 上用 Docker 扫描端

问题不在“扫描端不能容器化”，而在“官方原始编排直接用了 `network_mode: host`”。

这在 macOS Docker Desktop 上不适合作为本地开发方案，所以之前才先落了宿主机版脚本。

现在新增的 `./scripts/dev-scan-docker.sh` 走的是另一条路径：

- 后端继续宿主机运行
- MongoDB/Redis 继续通过端口暴露在宿主机
- 扫描端容器通过 `host.docker.internal` 回连宿主机

这样既能保留本地开发体验，也能让扫描工具在 Linux 容器里运行，规避 macOS 宿主机工具兼容性问题。

### 4. 要如何清理本地运行时数据

删除工作区根目录下的：

```text
.local-dev/
```

如果还要清库，再处理：

```text
ScopeSentry/data/
```

注意：`ScopeSentry/data/` 是 Docker 挂载的数据目录，删除前先确认你不需要保留本地数据。

### 5. 前端启动时报依赖缺失，但 `node_modules` 明明存在

这通常是旧的 npm 安装痕迹和当前 `pnpm dev` 混用了。

现象通常是：

- `node_modules` 存在
- 但某些包实际缺失，比如 `codemirror`
- 启动时报 `Could not resolve ...`

处理方式：

```bash
cd ScopeSentry-UI
pnpm install
```

当前脚本已经改成检查 `node_modules/.pnpm`，能避开大部分“目录存在但不是 pnpm 依赖树”的情况。

### 6. 扫描端启动时报 `main redeclared in this block`

这是因为 `ScopeSentry-Scan/cmd/ScopeSentry/` 目录里除了正式入口 `main.go`，还混有其他带 `main()` 的实验/测试文件。

处理方式：

- 不要对整个 `./cmd/ScopeSentry` 目录直接 `go build`
- 按发布配置固定构建 `./cmd/ScopeSentry/main.go`

### 7. 为什么第一次跑 `dev-smoke.sh` 可能比较慢

如果扫描端当前还没启动，脚本会后台拉起 `ScopeSentry-Scan`。而扫描端初始化时会顺带做插件安装/检查，其中 `ksubdomain` 在当前本机环境里会有超时现象，所以首次等待节点注册可能接近几分钟。

这不是脚本卡死，而是当前扫描端初始化成本较高。等节点已经在线后，再次跑 `dev-smoke.sh` 会快很多。

## 你下一步最适合做什么

如果你准备开始二开，建议先走这一套：

1. `./scripts/dev-db-up.sh`
2. `./scripts/dev-server.sh`
3. `./scripts/dev-ui.sh`

先把主服务和前端联通，再决定是否需要把扫描端也带起来。
