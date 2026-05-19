# 服务端远端部署

把 ScopeSentry 服务端从 GHCR 拉到一台干净 Linux 服务器，一行 curl 起来。Mongo / Redis 强密码自动生成。

完成后，扫描节点的加机器流程见 [DEPLOY_NODE.md](./DEPLOY_NODE.md)。

## 总体思路

| 角色 | 做什么 | 频率 |
|------|--------|------|
| dev 机 | `./devctl server publish` 把镜像推到 GHCR | 每次发新版 |
| 你 fork 的 GitHub 仓库 | 持有 `scripts/install-server.sh`（顶部硬编码 GHCR_OWNER）| 一次 |
| 目标 Linux 服务器 | `curl ... install-server.sh \| bash` | 每加一台 |

跟扫描节点的差别：扫描节点 Go 二进制走 SSH rsync 每次都跑；服务端是整个镜像一起换，迭代频率不像扫描端那么高。

## 一次性准备

### 1. 配置 GHCR 凭据（同 DEPLOY_NODE.md 第 1 步）

`.local-dev/env/ghcr.env`：
```
GHCR_OWNER=<your-github-username>
GHCR_TOKEN=<github-classic-PAT-with-write:packages>
```

### 2. Fork 仓库 + 改 install-server.sh

```bash
# 把仓库 fork 到你自己的 GitHub
# 修改 scripts/install-server.sh 顶部：
#   GHCR_OWNER="${GHCR_OWNER:-<your-github-username>}"  ← 把占位符改成你的实际用户名
# commit + push 到 main 分支
git add scripts/install-server.sh
git commit -m "configure GHCR_OWNER"
git push origin main
```

之后这条 raw URL 就是稳定可用的入口：
```
https://raw.githubusercontent.com/<your-github-username>/<repo-name>/main/scripts/install-server.sh
```

### 3. 推 server 镜像

在 dev 机上：

```bash
./devctl server publish
# 默认推 ghcr.io/<owner>/scopesentry-server:vYYYY.MM.DD-HHMMSS 和 :latest
```

首次推完后到 https://github.com/`<owner>`?tab=packages 把 `scopesentry-server` 设为 **public**。

## 部署到一台新 Linux 服务器（每次 5 分钟）

### 单行命令

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/install-server.sh | bash
```

脚本会做的 8 步（每一步打印进度）：

1. 检查 docker / docker compose v2 / curl
2. 准备 `/opt/scopesentry/{,data/{mongodb,redis,files,images,uploads}}`
3. 生成或复用 Mongo / Redis 32 字节随机密码（已存在 `.env` 时复用避免破坏数据）
4. 写 `/opt/scopesentry/.env`（mode 600）
5. 写 `/opt/scopesentry/docker-compose.yml`
6. `docker pull` server 镜像
7. `docker compose up -d`
8. 等 server 首次初始化、捞 PASSWORD 文件出来

输出示例：
```
✓ 部署完成
访问地址：http://1.2.3.4:8082
登录用户：ScopeSentry
登录密码：xxxxxxxx
凭据已持久化到：/opt/scopesentry/PASSWORD, .env, PLUGINKEY
```

### 可覆盖的环境变量

| 变量 | 默认 | 用途 |
|------|------|------|
| `GHCR_OWNER` | 占位符 | 覆盖 fork 里硬编码的 owner |
| `SCOPESENTRY_IMAGE_TAG` | `latest` | 指定特定版本，便于固化或回滚 |
| `SCOPESENTRY_INSTALL_DIR` | `/opt/scopesentry` | 装到别处（比如非 root 用户的 home 下） |
| `MONGO_PORT_EXT` | `37017` | 主机侧 Mongo 端口（容器内永远是 27017） |
| `REDIS_PORT_EXT` | `16379` | 主机侧 Redis 端口 |
| `API_PORT` | `8082` | 主机侧 API 端口 |
| `TIMEZONE` | `Asia/Shanghai` | 容器内时区 |

例：固定版本 + 自定义端口
```bash
SCOPESENTRY_IMAGE_TAG=v2026.05.18-101530 API_PORT=8443 \
  curl -fsSL https://.../install-server.sh | bash
```

## 给服务端 config 补 node_bootstrap section

部署完后立刻做这一步，否则 UI 上"添加节点"会因 `node_bootstrap` 未配置而报错。

### 1. 在服务器上一行命令生成 yaml 片段

直接复制下面这段到 ssh 终端，输出可粘进 config.yaml：

```bash
set -a; source /opt/scopesentry/.env; set +a
PUBLIC_IP="${PUBLIC_IP:-$(curl -fsS --max-time 5 ifconfig.me)}"
GHCR_OWNER=$(echo "$SERVER_IMAGE" | sed -E 's|^ghcr\.io/([^/]+)/.*|\1|')
cat <<EOF
node_bootstrap:
  scan_image: "ghcr.io/${GHCR_OWNER}/scopesentry-scan:latest"
  public_server_url: "http://${PUBLIC_IP}:${API_PORT}"
  timezone: "${TIMEZONE}"
  mongodb:
    host: "${PUBLIC_IP}"
    port: ${MONGO_PORT_EXT}
    database: "ScopeSentry"
    username: "${MONGO_INITDB_ROOT_USERNAME}"
    password: "${MONGO_INITDB_ROOT_PASSWORD}"
  redis:
    host: "${PUBLIC_IP}"
    port: ${REDIS_PORT_EXT}
    password: "${REDIS_PASSWORD}"
EOF
```

字段含义：

| 字段 | 来源 |
|------|------|
| `scan_image` | 节点 docker pull 的目标——**完整 scan 镜像**（不是 scan-base）。owner 自动从 `.env` 的 `SERVER_IMAGE` 提取 |
| `public_server_url` | 节点反连服务端 API 的 URL。`PUBLIC_IP` 自动从 ifconfig.me 取，需自定义改成 `PUBLIC_IP=1.2.3.4` 前置环境变量 |
| `timezone` | 容器内时区，install 时写到 `.env` |
| `mongodb.host` / `redis.host` | 节点跨网回连，必须公网 IP，不能是 127.0.0.1 |
| `mongodb.port` / `redis.port` | install-server.sh 默认 `37017 / 16379`，避开公网爬虫常扫的默认端口 |
| `mongodb.username` / `password` | install 时随机生成 32 字节，从 `.env` 读取 |
| `redis.password` | 同上 |

### 2. 持久化到 config.yaml（强烈推荐，用 bind-mount）

config.yaml 默认在镜像内部，直接 `docker exec` 改会被下次 `docker pull` 抹掉。用 bind-mount 让它跟数据库密码一样持久化：

```bash
# a) 第一次启动后从容器里把现成的 config.yaml 拷出来作模板
docker cp scope-sentry:/opt/ScopeSentry/config.yaml /opt/scopesentry/config.yaml

# b) 编辑 /opt/scopesentry/config.yaml，把第 1 步生成的 node_bootstrap 段贴到根 level
sudo vi /opt/scopesentry/config.yaml

# c) 改 docker-compose.yml 给 scope-sentry 加 volume
#    在 scope-sentry 服务的 volumes 下加一行：
#      - ./config.yaml:/opt/ScopeSentry/config.yaml:ro
sudo vi /opt/scopesentry/docker-compose.yml

# d) 重建容器使 bind-mount 生效
cd /opt/scopesentry && docker compose up -d --force-recreate scope-sentry
```

升级（`update-server.sh`）只换 image，挂卷里的 config.yaml 不会丢。

### 3. 仅当不想 bind-mount：临时 docker exec 改

```bash
docker exec -it scope-sentry sh
vi /opt/ScopeSentry/config.yaml   # 贴 node_bootstrap 段
exit
docker restart scope-sentry
```

下次 `update-server.sh` 拉新镜像会把这次的改动覆盖掉。

## 防火墙

只对扫描节点放行 Mongo / Redis，公网撒手就开是数据泄露常见来源。

云防火墙（推荐）：在云控制台安全组里只放节点 IP。

iptables：
```bash
sudo iptables -A INPUT -p tcp --dport 37017 -s <node-ip-1> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 37017 -s <node-ip-2> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 37017 -j DROP
sudo iptables -A INPUT -p tcp --dport 16379 -s <node-ip-1> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 16379 -s <node-ip-2> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 16379 -j DROP
# API 8082 一般你希望对自己开放即可，按需收紧
```

## 升级到新版本

在 dev 机：
```bash
./devctl server publish --tag v2026.06.01
```

在服务器（用 update-server.sh，比重新跑 install-server.sh 更快、更安全）：
```bash
# 拉 :latest
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-server.sh | bash

# 或指定版本
SCOPESENTRY_IMAGE_TAG=v2026.06.01 \
  curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-server.sh | bash
```

update-server.sh 做的事：
1. 可选：把 `.env` 里的 SERVER_IMAGE tag 换成你指定的版本
2. `docker compose pull` 拉新镜像
3. `docker compose up -d --force-recreate` 重启容器
4. 打印容器状态

数据库密码不变，admin 账户不变，挂载卷里的 files/images/uploads 都保留。

## 回滚

```bash
# 假设之前的稳定版本是 v2026.05.18
SCOPESENTRY_IMAGE_TAG=v2026.05.18 \
  curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-server.sh | bash
```

如果数据库 schema 改了（罕见），回滚需要先备份。

## 排错

### 一直停在 "等待服务端首次初始化"

通常是 Mongo 还没 healthy。

```bash
docker logs scope-sentry --tail 50
docker logs scopesentry-mongodb --tail 50
```

如果 Mongo 一直在 `starting`，可能数据目录权限有问题：
```bash
sudo chown -R 999:999 /opt/scopesentry/data/mongodb  # mongo 容器内 uid
```

### 90 秒后脚本说"没读到 PASSWORD 文件"

99% 是这台机器之前装过 ScopeSentry，admin 已经存在。在 dev 机：
```bash
./devctl deploy reset-password <new-password>
```

或者直接进数据库改：
```bash
docker exec -it scopesentry-mongodb mongosh \
  -u scopesentry -p <pw-from-.env> --authenticationDatabase admin \
  --eval 'db.getSiblingDB("ScopeSentry").user.updateOne({username:"ScopeSentry"}, {$set:{password:"<sha256-of-new-pw>"}})'
```

### docker pull 报 `denied: requested access to the resource is denied`

`scopesentry-server` 在 GHCR 上还是 private。
- 到 https://github.com/`<owner>`?tab=packages → 选镜像 → settings → change visibility → public

### 服务端 UI "添加节点" 报 `node_bootstrap config not set`

config.yaml 的 `node_bootstrap` section 没填或没生效。参照本文 "给服务端 config 补 node_bootstrap section" 一节。

## 不在本流程范围

- 单机本地开发（用 `./devctl up` 那一套，详见 LOCAL_DEV_SETUP.md）
- dev 机推到一台已知服务器的"开发流"部署（`./devctl deploy init/push/reload`，仍可用）
- 多服务器集群 / k8s（1-3 台用本流程，更大规模再考虑迁移）
- 扫描节点的部署流程（[DEPLOY_NODE.md](./DEPLOY_NODE.md)）
