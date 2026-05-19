# Multi-Node Deployment Design (Server + N × Scan over Tailscale)

## Goal

把现在的单机 `single-host-deployment.yml` 拆成「服务端 + 多扫描端」两个独立可分发的部署单元，让运维可以：

- 在一台 Linux 服务器上跑服务端（MongoDB + Redis + ScopeSentry server + 私有 registry）。
- 在 N 台扫描端服务器上各自跑一个 `ScopeSentry-Scan` 容器，连回服务端。
- 通过 Tailscale 内网互通，所有数据库/Redis/registry 端口都绑定到 Tailscale IP，不暴露到公网。
- 通过一个 `deploy-scan.sh` 脚本批量初始化、更新、新增扫描节点。

## Scope

本设计覆盖：

- 新增 `deploy/` 目录，提供 server / scan / build 三套独立产物。
- 服务端 docker compose（包含 registry）。
- 扫描端 docker compose（单服务，host 网络）。
- 一台 build 机（与 server 机合并，同一台 Linux x86_64 主机）的镜像构建脚本。
- 批量部署/更新扫描节点的 SSH 脚本。
- `.env.template` 示例 + README。

不做以下事情：

- 不改任何 ScopeSentry / ScopeSentry-Scan 的源码或二进制行为。
- 不替换 `devctl`、不改本地开发流程；本设计只产出生产部署脚本。
- 不引入 Ansible / K8s / Helm；只用 docker compose + bash + ssh。
- 不为 registry 配 TLS（HTTP 仅在 Tailscale 内网走）；后续如果要 HTTPS 用 `tailscale cert` 可单独迭代。
- 不写跨 arch（arm64）镜像构建逻辑；本设计假设所有机器都是 Linux x86_64。
- 不实现节点健康监控、告警、日志聚合；这些是独立工作。

## Architecture

```
                      Tailscale Network (100.x.x.x)

┌──────────────────────────────┐        ┌────────────────────┐
│ Server / Build (100.x.x.10)  │        │ Scan-01 (100.x.x.20)│
│                              │◄───────│  scopesentry-scan   │
│  docker compose:             │        │  NodeName=scan-01   │
│   - mongodb:27017            │        └────────────────────┘
│   - redis:6379               │        ┌────────────────────┐
│   - scope-sentry:8082        │◄───────│ Scan-02 (100.x.x.21)│
│   - registry:5000            │        │  NodeName=scan-02   │
│                              │        └────────────────────┘
│  全部端口绑定到 100.x.x.10   │        ┌────────────────────┐
│                              │◄───────│ Scan-N              │
│  + 兼任镜像构建机             │        └────────────────────┘
└──────────────────────────────┘

通信关系：
- Scan 节点 → MongoDB (100.x.x.10:27017)：取任务、写结果
- Scan 节点 → Redis    (100.x.x.10:6379)：心跳、任务队列
- Scan 节点 → Registry (100.x.x.10:5000)：拉镜像
- Server 节点 → MongoDB / Redis：本地 docker network
- 用户浏览器 → ScopeSentry (100.x.x.10:8082)：管理 UI
```

关键架构事实（从现有 `single-host-deployment.yml` 推断）：

- 服务端和扫描端不通过 HTTP API 通信，而是**共享 MongoDB + Redis**。
- 因此扫描端只需要能访问服务端的 MongoDB 和 Redis 端口即可工作，不需要任何反向连接。
- 扫描端必须用 `network_mode: host`（沿用现有方案），扫描的子工具会调用本机网络栈。

## Repo 新增结构

```
deploy/
├── server/
│   ├── docker-compose.yml          # mongodb + redis + scope-sentry + registry
│   ├── .env.template               # 各类密码、SERVER_TS_IP、镜像 tag
│   └── README.md                   # 服务端部署步骤
├── scan/
│   ├── docker-compose.yml          # 单 scopesentry-scan 服务
│   ├── .env.template               # SERVER_TS_IP、NodeName、Mongo/Redis 凭据、镜像 tag
│   └── README.md                   # 单台扫描端部署步骤
├── build/
│   ├── build-and-push.sh           # 编译二进制 → docker build → push 到私有 registry
│   └── README.md                   # 构建机使用说明
├── scan-nodes.txt                  # 扫描节点清单（git-ignored；提供 .example）
├── scan-nodes.txt.example          # 清单格式示例
├── deploy-scan.sh                  # 批量 SSH 部署/更新脚本
└── README.md                       # 整体部署总览
```

`deploy/` 与现有 `scripts/`（dev 脚本）、`devctl`（开发控制器）、`ScopeSentry/single-host-deployment.yml`（旧单机部署）并存，互不影响。`single-host-deployment.yml` 暂时保留作为参考，不删除。

## Chosen Behavior

### Server compose

`deploy/server/docker-compose.yml` 包含 4 个服务：

- `mongodb`（mongo:7.0.28）：端口绑定 `${SERVER_TS_IP}:27017:27017`，数据卷 `./data/mongodb`。
- `redis`（redis:7.0.11）：端口绑定 `${SERVER_TS_IP}:6379:6379`，数据卷 `./data/redis/data`。
- `scope-sentry`：使用 `${REGISTRY}/scopesentry:${IMAGE_TAG}`，端口 `${SERVER_TS_IP}:8082:8082`（UI/API），环境变量包含 `TIMEZONE=Asia/Shanghai`、`MONGODB_IP=scopesentry-mongodb`（容器内 DNS）、`MONGODB_PORT=27017`、`MONGODB_DATABASE=ScopeSentry`、`MONGODB_USER/PASSWORD`、`REDIS_IP=scopesentry-redis`、`REDIS_PORT=6379`、`REDIS_PASSWORD`，照搬现有 `single-host-deployment.yml` 的写法。`depends_on` 同样保留对 mongodb / redis 的 `service_healthy` 依赖。
- `registry`（registry:2）：端口绑定 `${SERVER_TS_IP}:5000:5000`，数据卷 `./data/registry`。

健康检查、网络、依赖关系沿用现有 `single-host-deployment.yml` 的写法。

### Scan compose

`deploy/scan/docker-compose.yml` 只有 1 个服务：

- `scopesentry-scan`：使用 `${REGISTRY}/scopesentry-scan:${IMAGE_TAG}`，`network_mode: host`，环境变量 `MONGODB_IP=${SERVER_TS_IP}`、`REDIS_IP=${SERVER_TS_IP}`、`NodeName=${NODE_NAME}`，凭据从 `.env` 注入。

### `.env.template` 字段

**`deploy/server/.env.template`**

```
# Tailscale IP of this server machine (must already be up before docker compose up)
SERVER_TS_IP=100.x.x.10

# 私有 registry 地址（同机部署时就是 ${SERVER_TS_IP}:5000）
REGISTRY=100.x.x.10:5000

# 业务镜像 tag（默认 latest，部署具体版本时填 git short sha）
IMAGE_TAG=latest

# Mongo
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=<change-me>

# Redis
REDIS_PASSWORD=<change-me>
```

**`deploy/scan/.env.template`**

```
# Server 机的 Tailscale IP（Mongo / Redis / Registry 全在这台）
SERVER_TS_IP=100.x.x.10

# 私有 registry 地址（默认与 server 同机）
REGISTRY=100.x.x.10:5000

# 镜像 tag
IMAGE_TAG=latest

# 本扫描节点的唯一标识，每台机器必须不同
NODE_NAME=scan-01

# Mongo / Redis 凭据，必须与 server/.env 一致
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=<must-match-server>
REDIS_PASSWORD=<must-match-server>
```

### `build-and-push.sh`

在构建机（= 服务端机器）上执行，单条命令完成全部产物构建和推送。流程：

1. 解析参数：`./build-and-push.sh [<git-sha>]`，未传则用 `git rev-parse --short HEAD`。
2. 构建 ScopeSentry server 二进制（PyInstaller，沿用现有产出路径 `ScopeSentry/dist/ScopeSentry_linux_amd64_v1/ScopeSentry`）。
3. 构建 ScopeSentry-Scan 二进制（`cd ScopeSentry-Scan && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/ScopeSentry-Scan_linux_amd64_v1/ScopeSentry-Scan ./cmd/ScopeSentry/main.go`）。
4. 检查 `scopesentry-scan-base:local-prod` 是否存在；不存在则用 `dockerfile.base` 构建一次（罕见路径，写明 5–10 分钟耗时）。
5. `docker build -t ${REGISTRY}/scopesentry:${TAG} -t ${REGISTRY}/scopesentry:latest -f ScopeSentry/dockerfile ScopeSentry/`。
6. `docker build --build-arg SCAN_BASE_IMAGE=scopesentry-scan-base:local-prod -t ${REGISTRY}/scopesentry-scan:${TAG} -t ${REGISTRY}/scopesentry-scan:latest -f ScopeSentry-Scan/dockerfile.release ScopeSentry-Scan/`。
7. `docker push` 两个镜像的两个 tag 到 registry。
8. 输出：本次构建的 `IMAGE_TAG=<sha>`，提示用户 `cd deploy/server && IMAGE_TAG=<sha> docker compose pull && docker compose up -d` 升级服务端，然后 `./deploy-scan.sh update` 滚动升级扫描端。

脚本读 `deploy/server/.env` 拿 `REGISTRY` 值，避免重复配置。

### `scan-nodes.txt` 格式

```
# NodeName       Tailscale-Host-or-IP        SSH-User (可选, 默认 root)
scan-01          100.64.0.20
scan-02          scan02.tail-xxx.ts.net      ubuntu
scan-03          100.64.0.22
```

- 第一列 `NodeName` 同时充当扫描节点的 `NodeName` 和 SSH 目标的标识。
- 第二列可以是 Tailscale IP 或 MagicDNS 主机名。
- 第三列可选，省略时默认 `root`。
- 注释行（`#` 开头）和空行被忽略。

### `deploy-scan.sh` 子命令

幂等设计：所有子命令重复执行无副作用。

| 子命令 | 行为 |
|---|---|
| `init` | 对 `scan-nodes.txt` 中所有节点：检查 docker / jq 是否安装（缺失就 fail fast，退出码 1 + 中文错误信息）、写入/合并 `/etc/docker/daemon.json` 的 `insecure-registries`、必要时 `systemctl restart docker`、scp `deploy/scan/` 到节点 `~/scopesentry-scan/`、**生成节点专属 `.env`**（自动从 `deploy/server/.env` 取 Mongo/Redis 凭据 + `SERVER_TS_IP` + `REGISTRY` + `IMAGE_TAG`，填入对应 `NODE_NAME`）、`docker compose pull && up -d`。 |
| `update` | 对所有节点：scp 最新 `docker-compose.yml`、**重写 `.env` 中的 `IMAGE_TAG` 一行**（从 `deploy/server/.env` 读取，保持 server / scan 镜像 tag 一致，其他字段保留不动）、`docker compose pull && up -d`。如要批量轮换密码请用 `init`。 |
| `add <node-name>` | 仅对 `scan-nodes.txt` 里指定一行执行 `init` 流程，用于新增节点。 |
| `restart <node-name>\|all` | `docker compose restart`。 |
| `logs <node-name>` | `docker compose logs -f --tail=200`。 |
| `status` | 并发对所有节点执行 `docker compose ps` 并汇总输出。 |

参数解析用最简 `case` 即可，不引入 getopts。

### insecure-registries 写入策略

`deploy-scan.sh init` 在每个节点上：

1. 读取 `/etc/docker/daemon.json`（不存在则视为 `{}`）。
2. 若 `insecure-registries` 数组中已包含 `${REGISTRY}`，跳过。
3. 否则用 `jq` 合并新条目并写回（要求节点机器装有 `jq`，缺失时 fail fast 提示用户 `apt install jq`）。
4. 仅在写入发生时 `systemctl restart docker`。

## Implementation Notes

### 工作流总结

**首次搭建：**

```bash
# Server 机
cd deploy/server && cp .env.template .env && vim .env    # 改密码、SERVER_TS_IP
docker compose up -d                                     # mongodb + redis + registry 起来

# 在 Server 机做 build
cd ../build && ./build-and-push.sh                       # 自动取 git sha 当 tag

# Server 拉刚 push 的镜像并启动 scope-sentry
cd ../server && docker compose pull scope-sentry && docker compose up -d

# 准备扫描节点清单
cd .. && cp scan-nodes.txt.example scan-nodes.txt && vim scan-nodes.txt

# 批量部署所有扫描节点
./deploy-scan.sh init
```

**代码更新：**

```bash
cd deploy/build && ./build-and-push.sh
cd ../server && docker compose pull && docker compose up -d   # 升级 server
cd .. && ./deploy-scan.sh update                              # 滚动升级所有 scan
```

**新增节点：**

```bash
echo "scan-04 100.64.0.24" >> deploy/scan-nodes.txt
cd deploy && ./deploy-scan.sh add scan-04
```

### 启动顺序与 Tailscale 依赖

服务端机器：要求 `tailscaled` 在 docker daemon 启动前就绪，否则 `${SERVER_TS_IP}:port` 端口绑定失败。处理方式：

- 在 `deploy/server/README.md` 写明前置：先 `tailscale up`，再 `docker compose up -d`。
- 提供可选的 systemd drop-in 片段（README 里贴文本，由用户手动放到 `/etc/systemd/system/docker.service.d/wait-tailscale.conf`），让 `docker.service` 加 `After=tailscaled.service` 与 `Wants=tailscaled.service`。不强制写入。

### 镜像 Tag 策略

- 每次 build 同时打 `<git-short-sha>` 和 `latest` 两个 tag。
- `.env` 默认 `IMAGE_TAG=latest`，部署具体版本时改成 `<git-short-sha>`。
- 升级使用 `IMAGE_TAG=<sha> docker compose pull && up -d`，便于回滚（改回旧 sha 即可）。

### 凭据同步

`deploy-scan.sh init` 从 `deploy/server/.env` 读 `MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD / REDIS_PASSWORD`，写入扫描节点的 `.env`，避免人工同步出错。前提：构建/部署机器（即 server 机）上有 `deploy/server/.env`。

### 安全约束

- 所有暴露端口都绑定 `${SERVER_TS_IP}`，不绑 `0.0.0.0`。Server 机即使有公网 IP，外部也访问不到 Mongo/Redis/registry。
- Registry 用 HTTP（无 TLS），仅在 Tailscale 内网使用，扫描端配 insecure-registries 信任。
- `.env` 文件加进 `.gitignore`，仅 `.env.template` / `.example` 入库。
- `scan-nodes.txt` 也加进 `.gitignore`（含内网 IP），仅 `.example` 入库。

### `network_mode: host` 的影响

扫描端容器与宿主共享网络栈。这意味着：

- 扫描端容器内 `127.0.0.1` 是宿主，不是 server。`MONGODB_IP` 必须显式写 `${SERVER_TS_IP}`（即 server 机的 Tailscale IP），不能写 `127.0.0.1`。
- 不能在同一台扫描端机器跑两个扫描容器（会端口/资源冲突）。当前需求是 1 节点 = 1 容器，符合预期。

## Output Expectations

`./build-and-push.sh` 典型输出：

```
[build] 当前 git sha: a1b2c3d
[build] 编译 ScopeSentry server 二进制 ...
[build] 编译 ScopeSentry-Scan 二进制 ...
[build] 检查 base 镜像 scopesentry-scan-base:local-prod ... OK
[build] docker build scopesentry:a1b2c3d ...
[build] docker build scopesentry-scan:a1b2c3d ...
[build] docker push 100.x.x.10:5000/scopesentry:a1b2c3d
[build] docker push 100.x.x.10:5000/scopesentry-scan:a1b2c3d
[build] done. 升级命令:
        IMAGE_TAG=a1b2c3d ./deploy-scan.sh update
```

`./deploy-scan.sh init` 典型输出：

```
[deploy-scan] 节点列表: scan-01 scan-02 scan-03
[deploy-scan][scan-01] checking docker ... OK
[deploy-scan][scan-01] daemon.json: insecure-registry 100.x.x.10:5000 已存在，跳过
[deploy-scan][scan-01] scp deploy/scan -> ~/scopesentry-scan
[deploy-scan][scan-01] writing .env (NODE_NAME=scan-01)
[deploy-scan][scan-01] docker compose pull ...
[deploy-scan][scan-01] docker compose up -d ...
[deploy-scan][scan-02] ... 同上 ...
[deploy-scan] 完成。已部署 3 个扫描节点。
```

## Risks

- **Registry 单点**：registry 跑在 server 机上，server 挂了则扫描节点拉不到新镜像。可接受——本设计目标是简单内网部署，不追求 HA。已有镜像缓存在扫描端，server 短暂不可用不影响已部署的扫描端继续工作。
- **Tailscale 掉线**：扫描端无法连 Mongo/Redis。docker compose 服务设 `restart: always`，Tailscale 重连后容器自愈。
- **节点凭据漂移**：用户手动改了某节点 `.env` 后，`deploy-scan.sh update` 只会覆盖 `IMAGE_TAG` 一行，不会覆盖密码等。要批量轮换 Mongo/Redis 密码必须改 server `.env` + 跑 `deploy-scan.sh init`（会重写整个 .env）。
- **构建机磁盘占用**：每次 build 留两个新 tag 的镜像，长期累积会撑满磁盘。脚本里加可选的 `--prune` 提示（不自动执行，避免误删）。

## Testing

不强制写自动化测试，靠手动验证：

- 在一台干净 Linux VM 上跑 `deploy/server`，确认 4 个容器都健康、能从浏览器访问 8082。
- 在第二台 VM 上手动跑 `docker compose -f deploy/scan/docker-compose.yml --env-file .env up -d`，确认能在管理 UI 里看到这个 NodeName 并且能跑扫描任务。
- 在 server 机上跑 `deploy-scan.sh init`，确认远程节点的 daemon.json、.env、容器都被正确创建。
- 跑 `deploy-scan.sh update` 验证幂等。
- 用 `nmap`/`ss` 从公网（或非 Tailscale 的网络）确认 27017/6379/5000 端口在 server 机上不可达。
