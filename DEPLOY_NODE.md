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
# 一键全量发布（推荐，串行推 base/server/scan + git push）
./devctl publish-all

# 或拆开手动控制
./devctl scan publish-base   # 一次性：base 镜像（含 ksubdomain/naabu/gogo 等工具）
./devctl scan publish        # 每次改了扫描端 Go 代码：完整 scan 镜像（FROM base + COPY 新 Go 二进制）
```

首次推完后，到 https://github.com/<owner>?tab=packages 把两个仓库 `scopesentry-scan-base` 和 `scopesentry-scan` 都设为 **public**（私有的话每个节点要配 PAT 才能 pull）。

`publish-all` 会按 `ScopeSentry-Scan/dockerfile.base` 的 sha256 指纹决定是否重推 scan-base：变了就推，没变就跳过。状态文件在 `.local-dev/state/scan-base-fingerprint`。需要强推用 `--force-base`，明确不重推用 `--skip-base`。

### 3. 配置服务端 config.yaml

> **如果服务端是 `install-server.sh` 装的，这一节已经自动完成**：首装 / `--upgrade` 时会自动写 `/opt/scopesentry/config.yaml` 的 `node_bootstrap` 段，公网 IP 自动探测（env 传 `PUBLIC_IP=...` 可覆盖），后续改 IP 走管理菜单 `[5]` 或 `--reconfigure`。下面的步骤仅在自部署 ScopeSentry 服务端时需要。

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

## 节点本地管理（升级 / 卸载 / 重启 / 状态）

装完后，节点机的日常运维走 `manage-node.sh`：

```bash
# 弹管理菜单
bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/manage-node.sh)
```

菜单项：

| 选项 | 行为 |
|------|------|
| `[1] 升级` | 把脚本自身刷新到 `/etc/scopesentry-node/manage-node.sh`，然后 `docker compose pull` + `up -d --force-recreate` |
| `[2] 卸载` | 二级菜单：`[1] 保留配置`（仅停删容器和镜像）/ `[2] 彻底卸载`（连 `/etc/scopesentry-node/` 和 `/opt/scopesentry-scan/` 一起删） |
| `[3] 重启` | `docker compose restart` |
| `[4] 查看状态` | 节点名 / 镜像 tag / 容器状态 / 最近一行日志 / `docker ps` / 最近 20 行容器日志 |
| `[0] 退出` | 直接退 |

彻底卸载需输入 `DELETE EVERYTHING` 二次确认；保留配置走 `yes/no`。

### 脚本化调用（flag mode）

```bash
curl -fsSL https://.../manage-node.sh | bash -s -- --upgrade
... | bash -s -- --restart
... | bash -s -- --status
... | bash -s -- --uninstall   # 仍保留二次确认
```

`manage-node.sh` 只处理**已装节点的管理**。如果节点机还没装过，会提示去服务端 UI 添加节点（拿一次性 token 的 curl 命令）。

## 日常代码迭代

```bash
# === dev 机：改了扫描端代码后 ===
./devctl publish-all                        # 推所有变化的镜像 + git push（推荐）
# 或
./devctl scan publish                       # 只推 scan 镜像到 GHCR

# === 在每个节点上 ===
# 推荐：弹菜单选 [1] 升级
bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/manage-node.sh)

# 脚本化：flag mode（与 manage-node.sh --upgrade 等价）
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-node.sh | bash
# 或
ssh node-hk-01 'curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-node.sh | bash'
```

升级会先把 `manage-node.sh` 刷新到 `/etc/scopesentry-node/manage-node.sh`（便于离线 ssh 复跑），再 `docker compose pull` + `up -d --force-recreate`。

也可以手工：
```bash
cd /etc/scopesentry-node && docker compose pull && docker compose up -d
```

## 工具或依赖升级（base 镜像变化）

```bash
# dev 机一键
./devctl publish-all --force-base

# 或拆开
./devctl scan publish-base    # 推新 base
./devctl scan publish         # 重新 build scan 镜像（FROM 新 base）

# 节点端
bash <(curl -fsSL https://.../scripts/manage-node.sh)   # 选 [1] 升级
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
- 节点版本回滚 —— 改 `/etc/scopesentry-node/node.env` 里 `SCAN_IMAGE` 的 tag，再跑 `manage-node.sh --upgrade`（或弹菜单选 `[1] 升级`）
