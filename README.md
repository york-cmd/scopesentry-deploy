# scopesentry-deploy

把 [ScopeSentry](https://github.com/Autumn-27/ScopeSentry) 部署成"一行 curl 装新服务器、一行 curl 加新节点"的形式。镜像走 GHCR，Mongo / Redis 凭据本地随机生成。

## 它管什么

| 文件 | 干嘛 |
|------|-----|
| `scripts/install-server.sh` | 一脚本搞定服务端**全生命周期**：未装则首装，已装则弹管理菜单（升级 / 卸载 / 重启 / 状态） |
| `scripts/manage-node.sh` | 扫描节点**装完之后**的管理菜单（升级 / 卸载 / 重启 / 状态）。初装仍走服务端 UI 发的 curl 命令 |
| `scripts/update-server.sh` | 向后兼容 wrapper，等价于 `install-server.sh --upgrade` |
| `scripts/update-node.sh` | 向后兼容 wrapper，等价于 `manage-node.sh --upgrade` |
| `devctl` | dev 机发布工具（`publish-all` / `server publish` / `scan publish-base` / `scan publish` 推到 GHCR） |

不在仓库里：上游源码 `ScopeSentry/` / `ScopeSentry-Scan/` / `ScopeSentry-UI/`（各自上游 git 仓库，本仓库不持有）。本地开发的中间产物 / 数据库数据 / 凭据 也都在 `.gitignore` 排除。

## 完整流程在哪

| 任务 | 看 |
|------|-----|
| 装新服务器 | [DEPLOY_SERVER.md](./DEPLOY_SERVER.md) |
| 加新扫描节点 | [DEPLOY_NODE.md](./DEPLOY_NODE.md) |
| dev 机本地启动调试 | [LOCAL_DEV_SETUP.md](./LOCAL_DEV_SETUP.md) |

## 部署到一台新 VPS（5 分钟）

```bash
curl -fsSL https://raw.githubusercontent.com/york-cmd/scopesentry-deploy/main/scripts/install-server.sh | bash
```

完成后命令行会输出 `访问地址 / 登录用户 / 登录密码`，凭据持久化在 `/opt/scopesentry/PASSWORD` 和 `/opt/scopesentry/.env`。

然后**必须**做这两步，否则 UI"添加节点"会报错或被全网爬：
1. 按 [DEPLOY_SERVER.md 的 "给服务端 config 补 node_bootstrap section"](./DEPLOY_SERVER.md#给服务端-config-补-node_bootstrap-section) 把节点拉起参数补到 `config.yaml`
2. 按 [DEPLOY_SERVER.md 的 "防火墙"](./DEPLOY_SERVER.md#防火墙) 把 Mongo（37017）/ Redis（16379）端口收紧到节点 IP

## 加扫描节点（每加一台 5 分钟）

服务端补完 `node_bootstrap` 之后：

1. UI → 节点管理 → 添加节点 → 复制 curl 命令
2. ssh 到节点机，粘贴跑

详见 [DEPLOY_NODE.md](./DEPLOY_NODE.md)。

## 日常运维（升级 / 卸载 / 重启 / 状态）

### 服务端

裸 curl 一行进**管理菜单**（已装时自动检测，弹 5 项菜单）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/york-cmd/scopesentry-deploy/main/scripts/install-server.sh)
```

或者用脚本化 flag 跳菜单：

```bash
# 升级
curl -fsSL https://raw.githubusercontent.com/york-cmd/scopesentry-deploy/main/scripts/install-server.sh | bash -s -- --upgrade
# 重启 / 卸载（卸载仍走二次确认）/ 状态
... | bash -s -- --restart
... | bash -s -- --uninstall
... | bash -s -- --status
```

老 `update-server.sh` 仍可工作，等价于 `--upgrade`：

```bash
curl -fsSL https://raw.githubusercontent.com/york-cmd/scopesentry-deploy/main/scripts/update-server.sh | bash
```

### 节点

```bash
# 管理菜单
bash <(curl -fsSL https://raw.githubusercontent.com/york-cmd/scopesentry-deploy/main/scripts/manage-node.sh)

# 或 flag mode
curl -fsSL https://raw.githubusercontent.com/york-cmd/scopesentry-deploy/main/scripts/manage-node.sh | bash -s -- --upgrade
```

老 `update-node.sh` 仍可工作，等价于 `--upgrade`。

## dev 机发布新版本镜像

一键全量发布（推荐）：

```bash
./devctl publish-all              # 串行推 base/server/scan + git push
./devctl publish-all --tag v2026.05.20    # 自定义 tag
./devctl publish-all --skip-base  # 明确不重推 base
./devctl publish-all --force-base # 强制重推 base
./devctl publish-all --skip-git   # 只推镜像，不动 git
```

逐项发布（精细控制）：

```bash
./devctl scan publish-base    # 工具基础镜像（罕见，加工具或改 dockerfile.base 时）
./devctl scan publish         # 扫描节点镜像（每次改扫描端 Go 代码）
./devctl server publish       # 服务端镜像（每次改服务端代码或前端）
```

镜像推到 `ghcr.io/york-cmd/scopesentry-{server,scan,scan-base}`。首次推完要在浏览器把每个包改成 public（`https://github.com/users/york-cmd/packages/container/<image>/settings`），否则远端节点 `docker pull` 会报 `denied`。
