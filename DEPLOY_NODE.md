# 扫描节点远端部署

把一台干净的 Linux 服务器变成扫描节点，全流程从 5 分钟一行 curl 到日常代码迭代 30 秒推送。

## 总体思路

| 角色 | 做什么 | 频率 |
|------|--------|------|
| **完整 scan 镜像（含工具 + Go 二进制）** | dev 机推到 GHCR，节点每次更新都拉 | 每次扫描端代码改动 |
| **base 镜像（只含工具/依赖）** | dev 机推到 GHCR，scan 镜像构建时 FROM 它 | 罕见，加工具/改 dockerfile 时 |
| **节点 enrollment** | 服务端发一次性 token，节点 curl 一行 | 每加一台新机器一次 |

## 一次性准备（在你 dev 机上）

### 1. 配置 GHCR 凭据

GitHub PAT 选 **classic**，不是 fine-grained：

1. 打开 https://github.com/settings/tokens
2. 右上 `Generate new token` 的下拉箭头 → `Generate new token (classic)`
3. `Select scopes` 区往下翻到 `write:packages`（勾上后 `read:packages` 自动带上）
4. 生成、复制 `ghp_...` 串

写到项目内的 `.local-dev/env/ghcr.env`：

```bash
cat > .local-dev/env/ghcr.env <<'EOF'
GHCR_OWNER=<your-github-username>
GHCR_TOKEN=<ghp_xxxxxx>
EOF
chmod 600 .local-dev/env/ghcr.env
```

文件位置可以通过环境变量 `GHCR_CONFIG_FILE=...` 覆盖。

### 2. 推 base 镜像 + scan 镜像

```bash
# 一次性：先推 base 镜像（含 ksubdomain/naabu/gogo 等工具）
./devctl scan publish-base

# 每次改了扫描端 Go 代码：推完整 scan 镜像（FROM base + COPY 新 Go 二进制）
./devctl scan publish
```

首次推完后，到 https://github.com/<owner>?tab=packages 把两个仓库 `scopesentry-scan-base` 和 `scopesentry-scan` 都设为 **public**（私有的话每个节点要配 PAT 才能 pull）。

### 3. 配置服务端 config.yaml

在 ScopeSentry 服务端的 `config.yaml` 里加：

```yaml
node_bootstrap:
  scan_image: "ghcr.io/<owner>/scopesentry-scan:latest"
  public_server_url: "http://<server-public-ip>:8082"
  timezone: "Asia/Shanghai"
  mongodb:
    host: "<server-public-ip>"
    port: 37017             # 改默认端口！27017 公网会被扫到
    database: "ScopeSentry"
    username: "<mongo-user>"
    password: "<mongo-strong-password-32-chars>"
  redis:
    host: "<server-public-ip>"
    port: 16379             # 同理改默认端口
    password: "<redis-strong-password-32-chars>"
```

改完重启服务端 `./devctl restart`（或远端的 `docker compose restart scope-sentry`）。

### 4. 给 server 的 Mongo / Redis 加 IP 白名单

只放节点公网 IP，不要让 Mongo/Redis 端口对所有人开放。

云服务器：在云控制台的安全组里，27017→37017、6379→16379 只对节点 IP 放行。

裸机：用 iptables：

```bash
sudo iptables -A INPUT -p tcp --dport 37017 -s <node-1-public-ip> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 37017 -j DROP
sudo iptables -A INPUT -p tcp --dport 16379 -s <node-1-public-ip> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 16379 -j DROP
```

## 添加新节点（每加一台 5 分钟）

### A. 在 UI 上点

1. 登录 ScopeSentry → 节点管理 → 「添加节点」
2. 填节点名（比如 `node-hk-01`）
3. 复制弹出的那行 curl 命令

### B. 或在 dev 机用 curl 直接生成

```bash
curl -fsS -X POST -H 'Content-Type: application/json' \
  -H "Authorization: Bearer <your-jwt-token>" \
  --data '{"node_name":"node-hk-01"}' \
  http://<server-public-ip>:8082/api/node/install-token
```

### C. 在目标 Linux 节点上跑

```bash
curl -fsSL "http://<server>:8082/api/node/install-script?token=XXXX" | bash
```

脚本背后做了 6 步（每步都会打印进度）：
1. 检查 docker / curl / python3
2. 调 `/api/node/bootstrap` 拉 enrollment（NodeName、Mongo 地址、Redis 地址、PluginKey 等）
3. 准备 `/opt/scopesentry-scan/{logs,cache}` 和 `/etc/scopesentry-node/`
4. 写 `node.env` 和 `docker-compose.yml`
5. `docker pull` scan 镜像（含 Go 二进制和全部工具）
6. `docker compose up -d` 起容器 —— **直接开始扫描，无需任何后续推送**

```bash
docker logs -f scopesentry-scan
# 应该看到节点已注册、向 server 心跳的日志
```

回到 UI 节点页 → 你的新节点应该出现在列表里。

## 日常代码迭代

```bash
# === dev 机：改了扫描端代码后 ===
./devctl scan publish                       # 推新版 scan 镜像到 GHCR

# === 在每个节点上 ===
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-node.sh | bash
# 或直接
ssh node-hk-01 'curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-node.sh | bash'
```

update-node.sh 做的事：
1. `docker compose pull` 拉新镜像
2. `docker compose up -d --force-recreate` 重启容器
3. 打印新容器状态

也可以手工：
```bash
cd /etc/scopesentry-node && docker compose pull && docker compose up -d
```

## 工具或依赖升级（base 镜像变化）

```bash
# dev 机
./devctl scan publish-base    # 推新 base
./devctl scan publish         # 重新 build scan 镜像（FROM 新 base）

# 节点端
curl -fsSL https://.../scripts/update-node.sh | bash
```

## 排错

### 节点 curl install-node.sh 报 `bootstrap 响应缺关键字段`

服务端 `node_bootstrap` section 没填全。看服务端日志或调试：
```bash
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"token":"XXX"}' http://<server>:8082/api/node/bootstrap
# 看 message 字段，会列出 missing 的字段名
```

### 节点容器一直 restart / 起不来

看 `docker logs -f scopesentry-scan`。常见原因：
- Mongo 连不上 → 看下面 "Mongo 连不上"
- PLUGINKEY 没注入 → 服务端 config.yaml 的 plugin_key 没设
- 镜像被拉错版本 → `docker images | grep scopesentry-scan` 看 tag

### `docker restart scopesentry-scan` ssh 报权限错

节点上的用户不在 `docker` 组里。解决：
```bash
ssh <host> 'sudo usermod -aG docker $USER && sudo systemctl restart docker'
# 然后断开重连 ssh
```

或在 install-node.sh 里临时用 `sudo docker`。

### Mongo 连不上 `connection refused`

99% 是 Mongo `bindIp` 还是 127.0.0.1。在服务端 mongo 容器的 `mongod.conf` 里改成 `0.0.0.0`（搭配 IP 白名单别犯懒）。或者用 docker-compose 的 `ports: [37017:27017]` + `bind_ip_all=true`。

### 节点 docker pull 镜像超时

国内服务器拉 GHCR 偶尔慢。
- 改用 base 镜像的 `:vX.Y` tag（具体版本，layer 复用更稳）
- 或者改成走 ghcr.io 的代理（如 `ghcr.nju.edu.cn`）

## 不在本流程范围

- 服务端自身的部署（看 DEPLOY_SERVER.md，也是 GHCR + 一行 curl）
- 节点上 masscan 需要 `network_mode: host` —— 已经在生成的 compose 里默认开了
- 节点重启后自动恢复 —— compose 用了 `restart: unless-stopped`，会自动起来
- 节点版本回滚 —— 在节点上跑 `SCAN_IMAGE_TAG=v2026.05.01 bash update-node.sh` 即可指定旧版本（脚本支持 SCAN_IMAGE_TAG 环境变量 fallback；或者手工 `docker pull <full-tag>` + `docker compose up -d`）
